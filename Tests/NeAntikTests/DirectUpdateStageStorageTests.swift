import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

private final class OwnUpdateStageFixture: @unchecked Sendable {
    let root: URL, source: URL, destination: URL
    let bytes: Data
    let key = Curve25519.Signing.PrivateKey()
    let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return time }
    func advanceToExpiry() { lock.lock(); time = time.addingTimeInterval(90_000); lock.unlock() }
    var configuration: UpdateChannelConfiguration {
        .init(isEnabled: true, manifestURL: URL(string: "https://browser.free/update.json"),
              publicKeyID: "own-stage-fixture", publicKey: key.publicKey.rawRepresentation)
    }
    init(bytes: Data = Data(repeating: 0x5a, count: 150_000)) throws {
        root = URL(fileURLWithPath: "/private/tmp/neantik-update-stage-test-" + UUID().uuidString)
        source = root.appendingPathComponent("source.zip")
        destination = root.appendingPathComponent("target-parent", isDirectory: true)
        self.bytes = bytes
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: source); _ = chmod(source.path, 0o600)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func manifest(minimumOS: String = "14.0", version: String = "0.7.30", build: Int = 93, digest: String? = nil) throws -> Data {
        let value = UpdateManifestPayload(schemaVersion: 1, product: "NeAntik", edition: "Direct", version: version, build: build,
            issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(86_400),
            archiveName: "NeAntik-\(version)-arm64-notarized.zip", downloadURL: "https://browser.free/downloads/NeAntik-\(version)-arm64-notarized.zip",
            sha256: digest ?? BackupFS.hex(SHA256.hash(data: bytes)), minimumOS: minimumOS, architecture: "arm64",
            artifactKind: "public-notarized", publicReleaseState: "public-ready", chromiumVersion: "156.0.8078.12")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(value)
        return try JSONEncoder().encode(SignedUpdateEnvelope(schemaVersion: 1, algorithm: "Ed25519", keyID: "own-stage-fixture",
            payload: payload.base64EncodedString(), signature: try key.signature(for: payload).base64EncodedString()))
    }
    func prepare(manifest: Data? = nil, source: URL? = nil, destination: URL? = nil,
                 configuration: UpdateChannelConfiguration? = nil, limit: Int64 = DirectUpdateArchiveIntegrityService.maximumArchiveBytes,
                 installedVersion: String = "0.7.29", installedBuild: Int = 92,
                 fault: (@Sendable (DirectUpdateStagePoint) throws -> Void)? = nil) throws -> PreparedUpdateArchive {
        try DirectUpdateStageStorage.prepareSynchronously(archiveURL: source ?? self.source, signedManifest: manifest ?? self.manifest(),
            configuration: configuration ?? self.configuration, installedVersion: installedVersion, installedBuild: installedBuild,
            destinationParent: destination ?? self.destination, hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            clock: { self.now }, byteLimit: limit, fault: fault)
    }
    var stageNames: [String] { (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [] }
}

private final class UpdateStageTestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    func set(_ url: URL) { lock.lock(); value = url; lock.unlock() }
    var url: URL? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class UpdateStageFinalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let time: Date
    init(time: Date) { self.time = time }
    func read() -> Date {
        lock.lock(); reads += 1; let final = reads == 4; lock.unlock()
        if final { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return time
    }
    func waitForBoundary() -> Bool { entered.wait(timeout: .now() + 5) == .success }
}

struct DirectUpdateStageStorageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PUBLIC_ARCHIVE"] != nil))
    func exactPublishedArchiveBytesPassOwnedStageWithSyntheticPinnedManifest() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PUBLIC_ARCHIVE"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        try #require(bytes.count == 188_206_286)
        try #require(BackupFS.hex(SHA256.hash(data: bytes)) == "2085796970bdef926beb7a3ff46090f5b1f7eb3dcf29f8b95bda1091a63b3bef")
        let f = try OwnUpdateStageFixture(bytes: bytes)
        let prepared = try f.prepare(manifest: f.manifest(version: "0.7.29", build: 92), installedVersion: "0.7.28", installedBuild: 91)
        try prepared.withValidatedArchive { _, result in
            #expect(result.archiveBytes == 188_206_286 && result.version == "0.7.29" && result.build == 92)
            #expect(!result.archiveSafetyVerified && !result.developerIDVerified && !result.notarizationVerified && !result.installed)
        }
        try prepared.discard(); #expect(f.stageNames.isEmpty)
    }

    @Test func ownedReadOnlyStageMatchesManifestAndDoesNotClaimInstallation() throws {
        let f = try OwnUpdateStageFixture(), prepared = try f.prepare()
        #expect(f.stageNames.count == 1)
        try prepared.withValidatedArchive { url, result in
            let actual = try Data(contentsOf: url)
            #expect(actual == f.bytes)
            var info = stat(); #expect(lstat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o400)
            #expect(result.manifestSignatureVerified && result.archiveBytesMatchManifest)
            #expect(!result.installed && !result.archiveSafetyVerified && !result.developerIDVerified && !result.notarizationVerified)
            #expect(result.archiveBytes == Int64(f.bytes.count))
        }
        #expect(try Data(contentsOf: f.source) == f.bytes)
        try prepared.discard(); #expect(f.stageNames.isEmpty)
        #expect(throws: DirectUpdateStageError.discarded) { try prepared.withValidatedArchive { _, _ in } }
    }

    @Test func disabledSignatureVersionAndOSAdmissionPrecedeAnyFileEffects() throws {
        let f = try OwnUpdateStageFixture(), absent = f.root.appendingPathComponent("absent")
        #expect(throws: UpdateManifestError.channelDisabled) {
            try f.prepare(source: absent, destination: absent, configuration: .init(isEnabled: false, manifestURL: nil, publicKeyID: nil, publicKey: nil))
        }
        #expect(throws: DirectUpdateArchiveIntegrityError.notNewer) { try f.prepare(manifest: f.manifest(build: 92), source: absent, destination: absent) }
        #expect(throws: DirectUpdateArchiveIntegrityError.incompatibleOS) { try f.prepare(manifest: f.manifest(minimumOS: "28.0"), source: absent, destination: absent) }
        let original = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: f.manifest())
        let broken = SignedUpdateEnvelope(schemaVersion: original.schemaVersion, algorithm: original.algorithm, keyID: original.keyID,
            payload: original.payload, signature: Data(repeating: 0, count: 64).base64EncodedString())
        #expect(throws: UpdateManifestError.invalidSignature) { try f.prepare(manifest: JSONEncoder().encode(broken), source: absent, destination: absent) }
        #expect(f.stageNames.isEmpty)
    }

    @Test func unsafeSourceDestinationAndSizeLeaveNoStage() throws {
        let f = try OwnUpdateStageFixture()
        let link = f.root.appendingPathComponent("source-link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        #expect(throws: (any Error).self) { try f.prepare(source: link) }
        let hardlink = f.root.appendingPathComponent("hardlink.zip")
        #expect(Darwin.link(f.source.path, hardlink.path) == 0)
        #expect(throws: (any Error).self) { try f.prepare() }
        try FileManager.default.removeItem(at: hardlink)
        #expect(throws: DirectUpdateArchiveIntegrityError.limitExceeded) { try f.prepare(limit: 1) }
        _ = chmod(f.destination.path, 0o755)
        #expect(throws: DirectUpdateStageError.unsafeDestination) { try f.prepare() }
        _ = chmod(f.destination.path, 0o700)
        let directoryLink = f.root.appendingPathComponent("target-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: f.destination)
        #expect(throws: (any Error).self) { try f.prepare(destination: directoryLink) }
        #expect(f.stageNames.isEmpty)
    }

    @Test(arguments: ["disk-full", "permission", "file-sync", "directory-sync", "parent-sync", "before-return"])
    func storageFaultsCleanOnlyOwnedStage(point: String) throws {
        let f = try OwnUpdateStageFixture()
        #expect(throws: (any Error).self) {
            try f.prepare { event in
                switch (point, event) {
                case ("disk-full", .beforeChunkWrite): throw POSIXError(.ENOSPC)
                case ("permission", .beforeChunkWrite): throw POSIXError(.EACCES)
                case ("file-sync", .beforeFileSync), ("directory-sync", .beforeDirectorySync),
                     ("parent-sync", .beforeParentSync), ("before-return", .beforeReturn): throw POSIXError(.EIO)
                default: break
                }
            }
        }
        #expect(f.stageNames.isEmpty)
        #expect(try Data(contentsOf: f.source) == f.bytes)
    }

    @Test func sourceChangesDuringCopyAndExpiredFinalBoundaryRefuse() throws {
        let f = try OwnUpdateStageFixture()
        #expect(throws: (any Error).self) {
            try f.prepare { event in
                if case .beforeChunkWrite(0) = event { try Data([1,2,3]).write(to: f.source) }
            }
        }
        #expect(f.stageNames.isEmpty)
        try f.bytes.write(to: f.source)
        let manifest = try f.manifest()
        #expect(throws: UpdateManifestError.expired) {
            try f.prepare(manifest: manifest) { event in if case .beforeReturn = event { f.advanceToExpiry() } }
        }
        #expect(f.stageNames.isEmpty)
    }

    @Test func hashCoversActualWrittenStageAndTamperedPreparedObjectRefuses() throws {
        let f = try OwnUpdateStageFixture(), capture = UpdateStageTestCapture()
        #expect(throws: DirectUpdateArchiveIntegrityError.digestMismatch) {
            try f.prepare { event in
                if case .created(let root) = event { capture.set(root) }
                if case .beforeFileSync = event {
                    let url = try #require(capture.url).appendingPathComponent("archive.zip")
                    _ = chmod(url.path, 0o600)
                    try Data(repeating: 1, count: f.bytes.count).write(to: url)
                    _ = chmod(url.path, 0o400)
                }
            }
        }
        #expect(f.stageNames.isEmpty)
        let prepared = try f.prepare()
        let archive = try prepared.withValidatedArchive { url, _ in url }
        _ = chmod(archive.path, 0o600); try Data([0]).write(to: archive)
        #expect(throws: (any Error).self) { try prepared.withValidatedArchive { _, _ in } }
        #expect(throws: (any Error).self) { try prepared.discard() }
        #expect(f.stageNames.count == 1)
    }

    @Test func replacedOrUnknownStageEntriesArePreservedOnFailure() throws {
        let f = try OwnUpdateStageFixture(), capture = UpdateStageTestCapture()
        #expect(throws: (any Error).self) {
            try f.prepare { event in
                if case .created(let root) = event {
                    capture.set(root)
                    let archive = root.appendingPathComponent("archive.zip")
                    try FileManager.default.moveItem(at: archive, to: root.appendingPathComponent("retained-owned.zip"))
                    try Data("unknown replacement".utf8).write(to: archive)
                }
            }
        }
        let root = try #require(capture.url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["archive.zip", "retained-owned.zip"])
        #expect(try Data(contentsOf: root.appendingPathComponent("archive.zip")) == Data("unknown replacement".utf8))
        #expect(try Data(contentsOf: f.source) == f.bytes)
    }

    @Test func actualTaskCancellationCleansOwnedCopy() async throws {
        let f = try OwnUpdateStageFixture(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let manifest = try f.manifest()
        let task = Task {
            try await DirectUpdateStageStorage.prepareLocalArchive(archiveURL: f.source, signedManifest: manifest,
                configuration: f.configuration, installedVersion: "0.7.29", installedBuild: 92, destinationParent: f.destination,
                hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: { f.now }) { point in
                    if case .beforeChunkWrite(0) = point { entered.signal(); _ = release.wait(timeout: .now() + 5) }
                }
        }
        let observed = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
        #expect(observed); task.cancel(); release.signal()
        do { _ = try await task.value; Issue.record("Cancelled stage returned custody") }
        catch { #expect(error is CancellationError) }
        #expect(f.stageNames.isEmpty)
        #expect(try Data(contentsOf: f.source) == f.bytes)
    }

    @Test(arguments: ["parent", "stage", "after-parent", "after-stage"])
    func privacyPermissionsCannotChangeDuringOrAfterPreparation(target: String) throws {
        let f = try OwnUpdateStageFixture(), capture = UpdateStageTestCapture()
        if target.hasPrefix("after-") {
            let prepared = try f.prepare { event in if case .created(let root) = event { capture.set(root) } }
            let root = try #require(capture.url)
            _ = chmod((target == "after-parent" ? f.destination : root).path, 0o777)
            #expect(throws: (any Error).self) { try prepared.withValidatedArchive { _, _ in } }
            #expect(throws: (any Error).self) { try prepared.discard() }
        } else {
            #expect(throws: (any Error).self) {
                try f.prepare { event in
                    if case .created(let root) = event {
                        _ = chmod((target == "parent" ? f.destination : root).path, 0o777)
                    }
                }
            }
        }
    }

    @Test func cancellationAtFinalManifestAdmissionCannotReturnCustody() async throws {
        let f = try OwnUpdateStageFixture(), clock = UpdateStageFinalClock(time: f.now)
        let manifest = try f.manifest()
        let task = Task {
            try await DirectUpdateStageStorage.prepareLocalArchive(archiveURL: f.source, signedManifest: manifest,
                configuration: f.configuration, installedVersion: "0.7.29", installedBuild: 92, destinationParent: f.destination,
                hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: { clock.read() })
        }
        let entered = await Task.detached { clock.waitForBoundary() }.value
        #expect(entered); task.cancel(); clock.release.signal()
        do { _ = try await task.value; Issue.record("Final admission returned cancelled custody") }
        catch { #expect(error is CancellationError) }
        #expect(f.stageNames.isEmpty)
        #expect(try Data(contentsOf: f.source) == f.bytes)
    }

    @Test(arguments: ["directory-discard", "archive-discard", "directory-failure", "archive-failure"])
    func replacementAtRetirementPreservesUnknownObject(boundary: String) throws {
        let f = try OwnUpdateStageFixture(), capture = UpdateStageTestCapture()
        let sentinel = Data("unknown object must survive".utf8)
        let fault: @Sendable (DirectUpdateStagePoint) throws -> Void = { event in
            switch event {
            case .beforeReturn where boundary.hasSuffix("failure"): throw POSIXError(.EIO)
            case .beforeRetireDirectory(let root) where boundary.hasPrefix("directory"):
                let retained = f.root.appendingPathComponent("retained-owned-stage")
                try FileManager.default.moveItem(at: root, to: retained)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                capture.set(root)
            case .beforeRetireArchive(let archive) where boundary.hasPrefix("archive"):
                let retained = archive.deletingLastPathComponent().appendingPathComponent("retained-owned.zip")
                try FileManager.default.moveItem(at: archive, to: retained)
                try sentinel.write(to: archive)
                capture.set(archive.deletingLastPathComponent())
            default: break
            }
        }
        if boundary.hasSuffix("discard") {
            let prepared = try f.prepare()
            #expect(throws: (any Error).self) { try prepared.discard(fault: fault) }
        } else {
            #expect(throws: (any Error).self) { try f.prepare(fault: fault) }
        }
        let preserved = try #require(capture.url)
        if boundary.hasPrefix("directory") {
            #expect(FileManager.default.fileExists(atPath: preserved.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: preserved.path).isEmpty)
            #expect(try Data(contentsOf: f.root.appendingPathComponent("retained-owned-stage/archive.zip")) == f.bytes)
        } else {
            let names = try FileManager.default.contentsOfDirectory(atPath: preserved.path)
            let retired = try #require(names.first(where: { $0.hasPrefix(".retiring-archive-") }))
            #expect(try Data(contentsOf: preserved.appendingPathComponent(retired)) == sentinel)
            #expect(try Data(contentsOf: preserved.appendingPathComponent("retained-owned.zip")) == f.bytes)
        }
        #expect(try Data(contentsOf: f.source) == f.bytes)
    }
}
