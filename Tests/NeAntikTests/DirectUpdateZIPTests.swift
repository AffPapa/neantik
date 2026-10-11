import CryptoKit
import Darwin
import DirectInstallFilesystem
import DirectZipCodec
import Foundation
import Testing
@testable import NeAntik

private struct ZIPFixtureEntry {
    var path: String, bytes: Data = Data(), mode: UInt32 = 0o100644, method: UInt16 = 0
    var descriptor = false, compressed: Data?, crc: UInt32?, expanded: UInt32?
    static func directory(_ path: String) -> Self { .init(path: path + "/", mode: 0o40755) }
    static func link(_ path: String, _ target: String) -> Self { .init(path: path, bytes: Data(target.utf8), mode: 0o120700) }
}
private struct ZIPFixture {
    let bytes: Data, central: Int, locals: [Int]
    init(_ entries: [ZIPFixtureEntry]) {
        var output = Data(), directory = Data(), offsets: [Int] = []
        for entry in entries {
            let name = Data(entry.path.utf8), offset = output.count
            let content = entry.compressed ?? (entry.method == 8 ? Self.rawDeflate(entry.bytes) : entry.bytes)
            let crc = entry.crc ?? entry.bytes.withUnsafeBytes { neantik_zip_crc32($0.baseAddress, $0.count) }
            let expanded = entry.expanded ?? UInt32(entry.bytes.count)
            let flags: UInt16 = entry.descriptor ? 8 : 0, needed: UInt16 = entry.method == 8 ? 20 : 10
            offsets.append(offset)
            output.le32(0x04034b50); output.le16(needed); output.le16(flags); output.le16(entry.method)
            output.le32(0); output.le32(entry.descriptor ? 0 : crc)
            output.le32(entry.descriptor ? 0 : UInt32(content.count)); output.le32(entry.descriptor ? 0 : expanded)
            output.le16(UInt16(name.count)); output.le16(0); output.append(name); output.append(content)
            if entry.descriptor { output.le32(0x08074b50); output.le32(crc); output.le32(UInt32(content.count)); output.le32(expanded) }
            directory.le32(0x02014b50); directory.le16(3 << 8 | 20); directory.le16(needed); directory.le16(flags)
            directory.le16(entry.method); directory.le32(0); directory.le32(crc)
            directory.le32(UInt32(content.count)); directory.le32(expanded); directory.le16(UInt16(name.count))
            directory.le16(0); directory.le16(0); directory.le16(0); directory.le16(0)
            directory.le32(entry.mode << 16); directory.le32(UInt32(offset)); directory.append(name)
        }
        central = output.count; output.append(directory)
        output.le32(0x06054b50); output.le16(0); output.le16(0)
        output.le16(UInt16(entries.count)); output.le16(UInt16(entries.count))
        output.le32(UInt32(directory.count)); output.le32(UInt32(central)); output.le16(0)
        bytes = output; locals = offsets
    }
    static func rawDeflate(_ bytes: Data) -> Data {
        var result = Data(), offset = 0
        repeat {
            let count = min(65_535, bytes.count - offset), last = offset + count == bytes.count
            result.append(last ? 1 : 0); result.le16(UInt16(count)); result.le16(~UInt16(count))
            result.append(bytes[offset..<(offset + count)]); offset += count
        } while offset < bytes.count
        return result
    }
}
private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func replace16(_ offset: Int, _ value: UInt16) { var d = Data(); d.le16(value); replaceSubrange(offset..<(offset + 2), with: d) }
    mutating func replace32(_ offset: Int, _ value: UInt32) { var d = Data(); d.le32(value); replaceSubrange(offset..<(offset + 4), with: d) }
}
private final class OwnZIPFixture: @unchecked Sendable {
    let root: URL, source: URL, stages: URL, apps: URL, bytes: Data
    let key = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    init(_ bytes: Data) throws {
        self.bytes = bytes
        root = URL(fileURLWithPath: "/private/tmp/neantik-own-update-zip-" + UUID().uuidString)
        source = root.appendingPathComponent("source.zip"); stages = root.appendingPathComponent("archives"); apps = root.appendingPathComponent("apps")
        for url in [root, stages, apps] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try bytes.write(to: source)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var configuration: UpdateChannelConfiguration {
        .init(isEnabled: true, manifestURL: URL(string: "https://browser.free/update.json"),
              publicKeyID: "own-zip-fixture", publicKey: key.publicKey.rawRepresentation)
    }
    func manifest(publicArchive: Bool = false, chromiumVersion: String = "156.0.8078.12", digest: String? = nil) throws -> Data {
        let version = publicArchive ? "0.7.29" : "0.7.30", build = publicArchive ? 92 : 93
        let payload = UpdateManifestPayload(schemaVersion: 1, product: "NeAntik", edition: "Direct", version: version, build: build,
            issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(86_400),
            archiveName: "NeAntik-\(version)-arm64-notarized.zip", downloadURL: "https://browser.free/downloads/NeAntik-\(version)-arm64-notarized.zip",
            sha256: digest ?? BackupFS.hex(SHA256.hash(data: bytes)), minimumOS: "14.0", architecture: "arm64",
            artifactKind: "public-notarized", publicReleaseState: "public-ready", chromiumVersion: chromiumVersion)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(payload)
        return try JSONEncoder().encode(SignedUpdateEnvelope(schemaVersion: 1, algorithm: "Ed25519", keyID: "own-zip-fixture",
            payload: body.base64EncodedString(), signature: try key.signature(for: body).base64EncodedString()))
    }
    func prepare(publicArchive: Bool = false, chromiumVersion: String = "156.0.8078.12") throws -> PreparedUpdateArchive {
        return try DirectUpdateStageStorage.prepareSynchronously(archiveURL: source, signedManifest: manifest(publicArchive: publicArchive, chromiumVersion: chromiumVersion),
            configuration: configuration,
            installedVersion: "0.7.28", installedBuild: 91, destinationParent: stages,
            hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: { self.now })
    }
    func inventory() throws -> DirectUpdateZIPInventory {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(fd) }; return try DirectUpdateZIPInventory.read(fd)
    }
    var retainedApps: [String] { (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? [] }
}

private final class AdmissionBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func block() throws { entered.signal(); guard release.wait(timeout: .now() + 10) == .success else { throw POSIXError(.ETIMEDOUT) } }
    func wait() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    func resume() { release.signal() }
}

/// These controls use real signed manifests, copied bytes and extraction. No
/// substituted verifier/helper can manufacture a passing trust observation.
@Suite(.serialized) struct DirectUpdateAdmissionTests {
    private func coordinator(_ f: OwnZIPFixture, enabled: Bool = true) -> DirectUpdateAdmissionCoordinator {
        let configuration = enabled ? f.configuration : UpdateChannelConfiguration(isEnabled: false, manifestURL: nil, publicKeyID: nil, publicKey: nil)
        return .init(configuration: configuration, installedVersion: "0.7.29", installedBuild: 92,
            hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: { f.now },
            assessmentHelper: { throw DirectAssessmentParentError.helper })
    }
    private func inspect(_ c: DirectUpdateAdmissionCoordinator, _ f: OwnZIPFixture, manifest: Data? = nil) async throws -> DirectUpdateAdmissionObservation {
        try await c.inspectLocalArchive(f.source, signedManifest: manifest ?? f.manifest(), archiveParent: f.stages, extractionParent: f.apps)
    }
    private func names(_ directory: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path) }

    @Test func disabledChannelRefusesBeforeFileAccess() async throws {
        let f = try OwnZIPFixture(Data([1])), c = coordinator(f, enabled: false)
        try FileManager.default.removeItem(at: f.source)
        await #expect(throws: UpdateManifestError.channelDisabled) { try await inspect(c, f) }
        #expect(await c.snapshot() == .failed(.manifest))
        #expect(try names(f.stages).isEmpty && names(f.apps).isEmpty)
    }
    @Test func unrelatedKeyRefusesBeforeAnyStage() async throws {
        let f = try OwnZIPFixture(Data([1])), other = try OwnZIPFixture(Data([1])), c = coordinator(f)
        await #expect(throws: UpdateManifestError.invalidSignature) { try await inspect(c, f, manifest: other.manifest()) }
        #expect(await c.snapshot() == .failed(.manifest))
        #expect(try names(f.stages).isEmpty && names(f.apps).isEmpty)
    }
    @Test func mismatchedBytesDoNotReachExtractionOrSignature() async throws {
        let f = try OwnZIPFixture(Data([1])), c = coordinator(f)
        await #expect(throws: DirectUpdateArchiveIntegrityError.digestMismatch) {
            try await inspect(c, f, manifest: f.manifest(digest: String(repeating: "0", count: 64)))
        }
        #expect(await c.snapshot() == .failed(.archive))
        #expect(try names(f.apps).isEmpty)
    }
    @Test func validManifestCannotPromoteNonZIPOrUnsignedApp() async throws {
        let bad = try OwnZIPFixture(Data([1, 2])), badCoordinator = coordinator(bad)
        do { _ = try await inspect(badCoordinator, bad); Issue.record("non-ZIP admitted") } catch { }
        #expect(await badCoordinator.snapshot() == .failed(.extraction))
        let goodZIP = ZIPFixture([.directory("NeAntik.app"), .init(path: "NeAntik.app/file", bytes: Data([9]))])
        let f = try OwnZIPFixture(goodZIP.bytes), c = coordinator(f)
        await #expect(throws: DirectUpdateCodeSignatureError.metadata) { try await inspect(c, f) }
        #expect(await c.snapshot() == .failed(.signature))
        // A complete untrusted stage is retained, but never returned as a
        // signature/runtime observation or an installation capability.
        #expect(try names(f.stages).count == 1 && names(f.apps).count == 1)
        #expect(try Data(contentsOf: f.source) == goodZIP.bytes)
        await #expect(throws: DirectUpdateAdmissionError.alreadyAttempted) { try await inspect(c, f) }
        #expect(await c.snapshot() == .failed(.signature))
    }
    @Test func actualReentrantCallCannotOverwriteCandidate() async throws {
        let f = try OwnZIPFixture(Data([1])), c = coordinator(f), barrier = AdmissionBarrier()
        let manifest = try f.manifest()
        let task = Task { try await c.inspectLocalArchive(f.source, signedManifest: manifest, archiveParent: f.stages, extractionParent: f.apps,
            beforePhase: { if $0 == .archive { try barrier.block() } }) }
        #expect(await Task.detached { barrier.wait() }.value)
        #expect(await c.snapshot() == .checking(.archive))
        await #expect(throws: DirectUpdateAdmissionError.alreadyAttempted) { try await inspect(c, f) }
        #expect(await c.snapshot() == .checking(.archive))
        barrier.resume()
        do { _ = try await task.value; Issue.record("non-ZIP admitted") } catch { }
        #expect(await c.snapshot() == .failed(.extraction))
        #expect(try names(f.stages).count == 1)
    }
    @Test func actualCancellationDrainsWorkerAndPublishesNoResult() async throws {
        let f = try OwnZIPFixture(Data([1])), c = coordinator(f), barrier = AdmissionBarrier()
        let manifest = try f.manifest()
        let task = Task { try await c.inspectLocalArchive(f.source, signedManifest: manifest, archiveParent: f.stages, extractionParent: f.apps,
            beforePhase: { if $0 == .archive { try barrier.block() } }) }
        #expect(await Task.detached { barrier.wait() }.value)
        task.cancel(); barrier.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await c.snapshot() == .cancelled(.archive))
        #expect(try names(f.stages).isEmpty && names(f.apps).isEmpty)
        await #expect(throws: DirectUpdateAdmissionError.alreadyAttempted) { try await inspect(c, f) }
        #expect(await c.snapshot() == .cancelled(.archive))
    }
    @Test func cancelledBeforeEntryDoesNotAccessFiles() async throws {
        let f = try OwnZIPFixture(Data([1])), c = coordinator(f)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await inspect(c, f) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await c.snapshot() == .cancelled(.manifest))
        #expect(try names(f.stages).isEmpty && names(f.apps).isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_ADMISSION_PUBLIC_ARCHIVE"] != nil))
    func actualPublishedCandidateComposesAllGatesWithoutGrantingInstallAuthority() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_ADMISSION_PUBLIC_ARCHIVE"])
        let helperRoot = try #require(ProcessInfo.processInfo.environment["NEANTIK_ASSESSMENT_PARENT_QA_ROOT"])
        let helperHash = try #require(ProcessInfo.processInfo.environment["NEANTIK_ASSESSMENT_PARENT_QA_HASH"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        try #require(BackupFS.hex(SHA256.hash(data: bytes)) == "1a445b68a22634ab249573cf4712d9f47552daa9e3d403df0cf0adc360cbc7df")
        let f = try OwnZIPFixture(bytes)
        let c = DirectUpdateAdmissionCoordinator(configuration: f.configuration, installedVersion: "0.7.29", installedBuild: 92,
            clock: { f.now }, assessmentHelper: { try DirectAssessmentHelper.qualification(in: URL(fileURLWithPath: helperRoot), payloadSHA256: helperHash) })
        let manifest = try f.manifest()
        let result = try await c.inspectLocalArchive(f.source, signedManifest: manifest, archiveParent: f.stages, extractionParent: f.apps)
        #expect(result.manifestSHA256 == BackupFS.hex(SHA256.hash(data: manifest)))
        #expect(result.version == "0.7.30" && result.build == 93 && result.archiveSHA256 == BackupFS.hex(SHA256.hash(data: bytes)))
        #expect(result.signatures.map(\.identifier) == DirectUpdateCodeRole.allCases.map(\.identifier))
        #expect(result.system.managerCDHash == result.signatures[0].cdHash)
        #expect(result.runtime.runtimeSHA256 == DirectUpdateRuntimePins.runtimeDigest)
        #expect(!result.installAuthorized && !result.system.installAuthorized && !result.system.reply.installAuthorized)
        switch result.system.reply {
        case .observed: #expect(await c.snapshot() == .observed)
        case .refused(let status, _, _, _, _, _):
            #expect(await c.snapshot() == .refused(status))
            print("Admission qualification: system refusal status=\(status); installation not authorized")
        }
        await #expect(throws: DirectUpdateAdmissionError.alreadyAttempted) { try await inspect(c, f) }
        // Reuse has no trusted array/Boolean bypass. Another genuine but
        // unsigned stage and a modified original must both be rejected.
        let archive = try f.prepare(), extracted = try await DirectUpdateZIPExtraction.extract(archive, destinationParent: f.apps)
        let signature = try await DirectUpdateCodeSignature.inspectBoundStage(extracted)
        // Actual authenticated production profile is not allowed to become a
        // perpetual observation just because its bytes did not change.
        #expect(throws: DirectUpdateCodeSignatureError.policy) {
            try signature.requireBinding(to: extracted, now: Date.distantFuture)
        }
        try signature.requireBinding(to: extracted)
        let other = try OwnZIPFixture(ZIPFixture([.directory("NeAntik.app"), .init(path: "NeAntik.app/file", bytes: Data([8]))]).bytes)
        let otherStage = try await DirectUpdateZIPExtraction.extract(other.prepare(), destinationParent: other.apps)
        await #expect(throws: DirectUpdateCodeSignatureError.changed) {
            try await DirectUpdateRuntimeProvenance.inspectStageAsynchronously(otherStage, signature: signature)
        }
        #expect(throws: DirectUpdateZIPError.changed) {
            try extracted.withValidatedApp { url in try Data([1]).write(to: url.appendingPathComponent("unexpected")) }
        }
        await #expect(throws: DirectUpdateZIPError.changed) {
            try await DirectUpdateRuntimeProvenance.inspectStageAsynchronously(extracted, signature: signature)
        }
    }
}
private final class ZIPRootCapture: @unchecked Sendable {
    private let lock = NSLock(); private var stored: URL?
    func set(_ url: URL) { lock.lock(); stored = url; lock.unlock() }
    var value: URL? { lock.lock(); defer { lock.unlock() }; return stored }
}
private final class ZIPCancellationBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private var reads = 0
    func block() { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    func wait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func resume() { release.signal() }
    // Invoked by exactly one codec worker; the test only uses semaphores.
    func codecBoundary() -> Int32 {
        reads += 1
        if reads == 2 { block() }
        return Task.isCancelled ? 1 : 0
    }
}

struct DirectUpdateZIPTests {
    private var appDirectory: ZIPFixtureEntry { .directory("NeAntik.app") }

    @Test func actualStoredDeflatedDescriptorAndFrameworkLinksExtract() throws {
        let expected = Data(repeating: 0x5a, count: 160_000)
        let archive = ZIPFixture([appDirectory, .directory("NeAntik.app/Versions"), .directory("NeAntik.app/Versions/v1"),
            .init(path: "NeAntik.app/Versions/v1/bin", bytes: expected, mode: 0o100755, method: 8, descriptor: true),
            .link("NeAntik.app/Versions/Current", "v1"), .link("NeAntik.app/bin", "Versions/Current/bin"),
            .init(path: "NeAntik.app/plain", bytes: Data("plain".utf8))])
        let f = try OwnZIPFixture(archive.bytes), prepared = try f.prepare()
        let app = try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps)
        try app.withValidatedApp { url in
            let actual = try Data(contentsOf: url.appendingPathComponent("bin"))
            #expect(actual == expected)
            var info = stat(); #expect(lstat(url.appendingPathComponent("Versions/v1/bin").path, &info) == 0 && info.st_mode & 0o777 == 0o755)
            #expect(app.inventory.entries.count == 7 && app.inventory.expandedBytes > 160_000)
            #expect(!app.archiveIntegrity.installed && !app.archiveIntegrity.developerIDVerified)
        }
        try app.discard(); try prepared.discard(); #expect(f.retainedApps.isEmpty)
    }

    @Test(arguments: ["traversal", "absolute", "backslash", "duplicate", "case", "parent-case", "device", "suid", "missing-parent", "link-ancestor", "link-cycle", "link-absolute", "link-file-parent"])
    func unsafePathsTypesAndGraphRefuseBeforeExtraction(control: String) throws {
        var entries = [appDirectory]
        switch control {
        case "traversal": entries.append(.init(path: "NeAntik.app/../outside", bytes: Data([1])))
        case "absolute": entries.append(.init(path: "/NeAntik.app/outside"))
        case "backslash": entries.append(.init(path: "NeAntik.app/back\\slash"))
        case "duplicate": entries += [.init(path: "NeAntik.app/same"), .init(path: "NeAntik.app/same")]
        case "case": entries += [.init(path: "NeAntik.app/Name"), .init(path: "NeAntik.app/name")]
        case "parent-case": entries += [.directory("NeAntik.app/Dir"), .init(path: "NeAntik.app/dir/file")]
        case "device": entries.append(.init(path: "NeAntik.app/device", mode: 0o20644))
        case "suid": entries.append(.init(path: "NeAntik.app/suid", mode: 0o104755))
        case "missing-parent": entries.append(.init(path: "NeAntik.app/absent/file"))
        case "link-ancestor": entries += [.directory("NeAntik.app/real"), .link("NeAntik.app/alias", "real"), .init(path: "NeAntik.app/alias/file")]
        case "link-cycle": entries += [.link("NeAntik.app/a", "b"), .link("NeAntik.app/b", "a")]
        case "link-absolute": entries += [.link("NeAntik.app/a", "/private/tmp")]
        case "link-file-parent": entries += [.init(path: "NeAntik.app/file"), .init(path: "NeAntik.app/target"), .link("NeAntik.app/link", "file/../target")]
        default: Issue.record("Unknown control")
        }
        let f = try OwnZIPFixture(ZIPFixture(entries).bytes), prepared = try f.prepare()
        #expect(throws: (any Error).self) { try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps) }
        #expect(f.retainedApps.isEmpty); try prepared.discard()
    }

    @Test func nativeSymlinkResolutionEscapesAndParserRejectsIt() throws {
        let fixture = ZIPFixture([appDirectory, .directory("NeAntik.app/dir"), .init(path: "NeAntik.app/dir/outside"),
            .link("NeAntik.app/dir/back", ".."), .link("NeAntik.app/dir/escape", "back/../outside")])
        let f = try OwnZIPFixture(fixture.bytes)
        let native = f.root.appendingPathComponent("native/NeAntik.app/dir")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let marker = Data("outside app root".utf8)
        try marker.write(to: f.root.appendingPathComponent("native/outside"))
        try FileManager.default.createSymbolicLink(atPath: native.appendingPathComponent("back").path, withDestinationPath: "..")
        try FileManager.default.createSymbolicLink(atPath: native.appendingPathComponent("escape").path, withDestinationPath: "back/../outside")
        #expect(try Data(contentsOf: native.appendingPathComponent("escape")) == marker)
        #expect(throws: (any Error).self) { try f.inventory() }
    }

    @Test(arguments: ["local-name", "local-method", "local-crc", "local-size", "descriptor", "central-offset", "central-count", "trailing", "encrypted", "zip64", "expanded-limit"])
    func malformedArchiveRecordsRefuse(control: String) throws {
        let zip = ZIPFixture([appDirectory, .init(path: "NeAntik.app/file", bytes: Data([1,2,3]), method: 8, descriptor: control == "descriptor")])
        var data = zip.bytes
        let local = zip.locals[1], centralFile = zip.central + 46 + "NeAntik.app/".utf8.count
        switch control {
        case "local-name": data[local + 30] = 88
        case "local-method": data.replace16(local + 8, 0)
        case "local-crc": data.replace32(local + 14, 99)
        case "local-size": data.replace32(local + 22, 1)
        case "descriptor": data.replace32(zip.central - 12, 99)
        case "central-offset": data.replace32(data.count - 6, 0)
        case "central-count": data.replace16(data.count - 12, 3)
        case "trailing": data.append(0)
        case "encrypted": data.replace16(centralFile + 8, 1)
        case "zip64": data.replace32(centralFile + 20, UInt32.max)
        case "expanded-limit": data.replace32(centralFile + 24, UInt32.max)
        default: break
        }
        let f = try OwnZIPFixture(data)
        #expect(throws: (any Error).self) { try f.inventory() }
    }

    @Test(arguments: ["crc", "truncated", "trailing-deflate", "too-much-output", "too-little-output"])
    func codecErrorsRefuseAndCleanOwnedPartialFiles(control: String) throws {
        let body = Data(repeating: 7, count: 100_000)
        var entry = ZIPFixtureEntry(path: "NeAntik.app/file", bytes: body, method: 8)
        if control == "crc" { entry.crc = 1 }
        if control == "truncated" { entry.compressed = ZIPFixture.rawDeflate(body).dropLast() }
        if control == "trailing-deflate" { entry.compressed = ZIPFixture.rawDeflate(body) + Data([1,2,3]) }
        if control == "too-much-output" { entry.expanded = 1 }
        if control == "too-little-output" { entry.expanded = UInt32(body.count + 1) }
        let f = try OwnZIPFixture(ZIPFixture([appDirectory, entry]).bytes), prepared = try f.prepare()
        #expect(throws: (any Error).self) { try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps) }
        #expect(f.retainedApps.isEmpty); try prepared.discard()
    }

    @Test(arguments: ["before-entry", "after-entry", "before-seal", "before-return"])
    func extractionFaultsCleanOnlyCapturedTree(boundary: String) throws {
        let f = try OwnZIPFixture(ZIPFixture([appDirectory, .init(path: "NeAntik.app/file", bytes: Data([1,2,3]))]).bytes)
        let prepared = try f.prepare()
        #expect(throws: (any Error).self) {
            try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps) { point in
                switch (boundary, point) {
                case ("before-entry", .beforeEntry), ("after-entry", .afterEntry),
                     ("before-seal", .beforeSeal), ("before-return", .beforeReturn): throw POSIXError(.ENOSPC)
                default: break
                }
            }
        }
        #expect(f.retainedApps.isEmpty); try prepared.discard()
    }

    @Test(arguments: ["after-entry", "before-seal", "chmod", "unknown", "parent-replaced"])
    func modifiedFinishedTreeRefusesAndPreservesIt(control: String) throws {
        let f = try OwnZIPFixture(ZIPFixture([appDirectory, .directory("NeAntik.app/Contents"),
            .init(path: "NeAntik.app/Contents/file", bytes: Data([1,2,3]))]).bytes)
        let prepared = try f.prepare(), capture = ZIPRootCapture()
        #expect(throws: (any Error).self) {
            try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps) { point in
                if case .created(let root) = point { capture.set(root) }
                if control == "after-entry", case .afterEntry("NeAntik.app/Contents/file") = point {
                    let file = try #require(capture.value).appendingPathComponent("NeAntik.app/Contents/file")
                    try Data([3,2,1]).write(to: file)
                }
                if case .beforeSeal = point, control != "after-entry" {
                    let root = try #require(capture.value), file = root.appendingPathComponent("NeAntik.app/Contents/file")
                    switch control {
                    case "before-seal": try Data([3,2,1]).write(to: file)
                    case "chmod": _ = chmod(file.path, 0o777)
                    case "unknown": try Data("unknown".utf8).write(to: root.appendingPathComponent("unknown"))
                    case "parent-replaced":
                        let directory = root.appendingPathComponent("NeAntik.app/Contents")
                        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("retained"))
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    default: break
                    }
                }
            }
        }
        #expect(f.retainedApps.count == 1); try prepared.discard()
    }

    @Test func actualTaskCancellationAtSealCleansOwnedTree() async throws {
        let f = try OwnZIPFixture(ZIPFixture([appDirectory, .init(path: "NeAntik.app/file", bytes: Data([1]))]).bytes)
        let prepared = try f.prepare(), barrier = ZIPCancellationBarrier()
        let task = Task { try await DirectUpdateZIPExtraction.extract(prepared, destinationParent: f.apps) { point in if case .beforeSeal = point { barrier.block() } } }
        let entered = await Task.detached { barrier.wait() }.value
        #expect(entered); task.cancel(); barrier.resume()
        do { _ = try await task.value; Issue.record("Cancelled extraction returned app") }
        catch { #expect(error is CancellationError) }
        #expect(f.retainedApps.isEmpty); try prepared.discard()
    }

    @Test func actualTaskCancellationInsideNativeDeflateStopsBeforeWrite() async throws {
        let body = Data(repeating: 1, count: 2_000_000), barrier = ZIPCancellationBarrier()
        let f = try OwnZIPFixture(ZIPFixture.rawDeflate(body)), outputURL = f.root.appendingPathComponent("output")
        let input = open(f.source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let output = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard input >= 0, output >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(input); Darwin.close(output) }
        let context = Unmanaged.passRetained(barrier).toOpaque()
        defer { Unmanaged<ZIPCancellationBarrier>.fromOpaque(context).release() }
        let crc = body.withUnsafeBytes { neantik_zip_crc32($0.baseAddress, $0.count) }
        let task = Task.detached {
            neantik_zip_decode_fd(input, 0, UInt64(f.bytes.count), output, UInt64(body.count), 8, crc, { context in
                guard let context else { return 1 }
                return Unmanaged<ZIPCancellationBarrier>.fromOpaque(context).takeUnretainedValue().codecBoundary()
            }, context)
        }
        let entered = await Task.detached { barrier.wait() }.value
        #expect(entered); task.cancel(); barrier.resume()
        #expect(await task.value == NEANTIK_ZIP_CANCELLED)
        #expect(try BackupFS.identity(output).size == 0)
    }

    @Test func fiveHundredEntriesExtractAndDiscardWithExactInventory() throws {
        let entries = [appDirectory] + (0..<500).map { ZIPFixtureEntry(path: "NeAntik.app/file-\($0)", bytes: Data([1,2,3])) }
        let f = try OwnZIPFixture(ZIPFixture(entries).bytes), prepared = try f.prepare()
        let app = try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps)
        try app.withValidatedApp { url in
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            #expect(names.count == 500 && app.inventory.entries.count == 501)
        }
        try app.discard(); try prepared.discard(); #expect(f.retainedApps.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PUBLIC_ARCHIVE"] != nil))
    func exactPublishedZIPExtractsWithNativeCodecAndKeepsSignatureBytes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PUBLIC_ARCHIVE"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        try #require(BackupFS.hex(SHA256.hash(data: bytes)) == "2085796970bdef926beb7a3ff46090f5b1f7eb3dcf29f8b95bda1091a63b3bef")
        let f = try OwnZIPFixture(bytes), prepared = try f.prepare(publicArchive: true)
        let app = try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps)
        #expect(app.inventory.entries.count == 1_085 && app.inventory.expandedBytes == 488_206_443)
        try app.withValidatedApp { url in
            let executable = url.appendingPathComponent("Contents/MacOS/NeAntik")
            let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw BackupFS.posix() }
            defer { Darwin.close(fd) }
            let hash = try BackupFS.hash(fd, size: BackupFS.identity(fd).size)
            #expect(hash == "54f0ce643d5031a756e0e023ae4883b95974c2b3a53f2833fce1fe10c762a276")
            // Host signature validation only; not a native updater trust token.
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            task.arguments = ["--verify", "--deep", "--strict", url.path]
            let diagnostic = Pipe(); task.standardOutput = FileHandle.nullDevice; task.standardError = diagnostic
            try task.run()
            let output = diagnostic.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            if task.terminationStatus != 0 {
                let message = String(decoding: output.prefix(16_384), as: UTF8.self).replacingOccurrences(of: f.root.path, with: "<owned-fixture>")
                print("Owned extracted app signature diagnostic: \(message)")
            }
            #expect(task.terminationStatus == 0)
        }
        let observed = try DirectUpdateRuntimeProvenance.inspectStage(app)
        #expect(observed.chromiumVersion == "156.0.8078.12" && observed.machoCount == 16)
        try app.discard(); try prepared.discard(); #expect(f.retainedApps.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PUBLIC_ARCHIVE"] != nil))
    func actualSignedStageRefusesManifestVersionMismatch() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PUBLIC_ARCHIVE"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        try #require(BackupFS.hex(SHA256.hash(data: bytes)) == "2085796970bdef926beb7a3ff46090f5b1f7eb3dcf29f8b95bda1091a63b3bef")
        let f = try OwnZIPFixture(bytes), prepared = try f.prepare(publicArchive: false)
        let app = try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps)
        #expect(throws: DirectUpdateCodeSignatureError.metadata) { try DirectUpdateCodeSignature.inspectStage(app) }
        try app.discard(); try prepared.discard(); #expect(f.retainedApps.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PROVISIONED_ARCHIVE"] != nil))
    func actualProvisionedPublicZIPRequiresAuthenticatedProfileAndMatchingManifest() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PROVISIONED_ARCHIVE"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        try #require(BackupFS.hex(SHA256.hash(data: bytes)) == "1a445b68a22634ab249573cf4712d9f47552daa9e3d403df0cf0adc360cbc7df")
        let fixture = try OwnZIPFixture(bytes), prepared = try fixture.prepare()
        let app = try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: fixture.apps)
        #expect(app.inventory.entries.contains(where: { $0.path == "NeAntik.app/Contents/embedded.provisionprofile" && $0.kind == .file }))
        let observed = try DirectUpdateRuntimeProvenance.inspectStage(app)
        #expect(observed.chromiumVersion == "156.0.8078.12" && observed.machoCount == 16)
        try app.discard(); try prepared.discard(); #expect(fixture.retainedApps.isEmpty)
        // An otherwise intact, signed/provisioned app cannot satisfy a different
        // fixture manifest. This synthetic signing key is not production trust.
        let mismatched = try fixture.prepare(publicArchive: true)
        let mismatchedApp = try DirectUpdateZIPExtraction.extractSynchronously(mismatched, destinationParent: fixture.apps)
        #expect(throws: DirectUpdateCodeSignatureError.metadata) { try DirectUpdateCodeSignature.inspectStage(mismatchedApp) }
        try mismatchedApp.discard(); try mismatched.discard(); #expect(fixture.retainedApps.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PROVISIONED_ARCHIVE"] != nil), arguments: ["tampered", "removed"])
    func actualProvisionedPublicAppRefusesDamagedOrMissingProfile(control: String) throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_STAGE_PROVISIONED_ARCHIVE"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        try #require(BackupFS.hex(SHA256.hash(data: bytes)) == "1a445b68a22634ab249573cf4712d9f47552daa9e3d403df0cf0adc360cbc7df")
        let fixture = try OwnZIPFixture(bytes), prepared = try fixture.prepare()
        let stage = try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: fixture.apps)
        let app = try stage.withValidatedApp { $0 }
        let profile = app.appendingPathComponent("Contents/embedded.provisionprofile")
        if control == "removed" { try FileManager.default.removeItem(at: profile) }
        else {
            var data = try Data(contentsOf: profile)
            let field = try #require(data.range(of: Data("<key>Platform</key>".utf8)))
            data[field.lowerBound+5] ^= 1
            try data.write(to: profile)
        }
        #expect(throws: (any Error).self) { try DirectUpdateCodeSignature.inspect(app, role: .manager) }
        #expect(throws: DirectUpdateZIPError.changed) { try stage.withValidatedApp { _ in } }
        #expect(throws: DirectUpdateZIPError.changed) { try stage.discard() }
        // Product retains changed trees; the test's known UUID root owns the
        // deliberately damaged disposable copy and removes it in fixture deinit.
        #expect(!fixture.retainedApps.isEmpty)
        try prepared.discard()
    }

    @Test func cancelledSignatureCallerCannotBeginAdmissionOrAlterStage() async throws {
        let f = try OwnZIPFixture(ZIPFixture([appDirectory]).bytes), prepared = try f.prepare()
        let app = try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: f.apps)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DirectUpdateCodeSignature.inspectStageAsync(app)
        }
        do { _ = try await task.value; Issue.record("Cancelled caller obtained signature observation") }
        catch { #expect(error is CancellationError) }
        try app.withValidatedApp { _ in }
        try app.discard(); try prepared.discard(); #expect(f.retainedApps.isEmpty)
    }

    @Test func unknownRuntimeCannotChooseItsOwnProvenancePolicy() throws {
        let fixture = try OwnZIPFixture(ZIPFixture([appDirectory]).bytes)
        let prepared = try fixture.prepare(chromiumVersion: "157.0.0.0")
        let stage = try DirectUpdateZIPExtraction.extractSynchronously(prepared, destinationParent: fixture.apps)
        #expect(throws: DirectUpdateRuntimeProvenanceError.unsupported) { try DirectUpdateRuntimeProvenance.inspectStage(stage) }
        try stage.withValidatedApp { _ in }
        try stage.discard(); try prepared.discard(); #expect(fixture.retainedApps.isEmpty)
    }
}

@Suite(.serialized)
struct DirectUpdateZIPTransferTests {
    private func stage(_ fixture: OwnZIPFixture) throws -> ExtractedUpdateApp {
        let archive = try fixture.prepare()
        return try DirectUpdateZIPExtraction.extractSynchronously(archive, destinationParent: fixture.apps)
    }
    @Test(arguments: [InstallPreparationPoint.beforeRename, .renamedBeforeSync, .sourceDirectorySynced, .destinationDirectorySynced, .beforeReturn])
    func extractionCustodyInvalidatedBeforeEveryPostRenameFailure(point: InstallPreparationPoint) throws {
        let f = try OwnZIPFixture(ZIPFixture([.directory("NeAntik.app"), .init(path: "NeAntik.app/file", bytes: Data([1,2,3]))]).bytes)
        let extracted = try stage(f), destination = f.root.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lease = try InstallFilesystemLease(parentURL: destination)
        let app = try extracted.withValidatedApp { $0 }, id = UUID()
        #expect(throws: POSIXError(.EIO)) {
            try extracted.prepareInstallSlot(lease: lease, candidateID: id, fault: { if $0 == point { throw POSIXError(.EIO) } })
        }
        if point == .beforeRename { #expect(try extracted.withValidatedApp { $0 } == app) }
        else {
            #expect(throws: DirectUpdateZIPError.changed) { try extracted.withValidatedApp { _ in () } }
            #expect(throws: DirectUpdateZIPError.changed) { try extracted.discard() }
            #expect(throws: DirectUpdateZIPError.changed) { try extracted.prepareInstallSlot(lease: lease) }
            let candidate = destination.appendingPathComponent(".neantik-next-" + id.uuidString.lowercased() + ".app/file")
            #expect(try Data(contentsOf: candidate) == Data([1,2,3])); #expect(!FileManager.default.fileExists(atPath: app.path))
        }
    }
    @Test func realStageTransferSuccessIsOneShotAndBorrowReentryRefuses() throws {
        let f = try OwnZIPFixture(ZIPFixture([.directory("NeAntik.app"), .init(path: "NeAntik.app/file", bytes: Data([7]))]).bytes)
        let extracted = try stage(f), destination = f.root.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lease = try InstallFilesystemLease(parentURL: destination)
        _ = try extracted.withValidatedApp { _ in
            #expect(throws: InstallFilesystemError.busy) { try extracted.prepareInstallSlot(lease: lease) }
        }
        let slot = try extracted.prepareInstallSlot(lease: lease)
        #expect(try slot.withValidatedCandidate { try Data(contentsOf: $0.appendingPathComponent("file")) } == Data([7]))
        try slot.withValidatedCandidate { _ in
            #expect(throws: InstallFilesystemError.busy) { try slot.withValidatedCandidate { _ in () } }
            #expect(throws: InstallFilesystemError.busy) { try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {}) }
        }
        #expect(throws: DirectUpdateZIPError.changed) { try extracted.discard() }
    }
    @Test(arguments: [InstallPreparationPoint.beforeRename, .renamedBeforeSync, .destinationDirectorySynced, .beforeReturn])
    func actualCancelledTaskPreservesOriginalOrTransferredStage(point: InstallPreparationPoint) async throws {
        let f = try OwnZIPFixture(ZIPFixture([.directory("NeAntik.app"), .init(path: "NeAntik.app/file", bytes: Data([4]))]).bytes)
        let extracted = try stage(f), destination = f.root.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lease = try InstallFilesystemLease(parentURL: destination), id = UUID()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try extracted.prepareInstallSlot(lease: lease, candidateID: id, fault: {
                if $0 == point { entered.signal(); guard release.wait(timeout: .now() + 10) == .success else { throw POSIXError(.ETIMEDOUT) } }
            })
        }
        func waitForEntry() -> Bool { entered.wait(timeout: .now() + 10) == .success }
        let observed = await Task.detached { waitForEntry() }.value
        #expect(observed); task.cancel(); release.signal()
        do { _ = try await task.value; Issue.record("cancelled preparation returned a token") } catch { #expect(error is CancellationError) }
        if point == .beforeRename { _ = try extracted.withValidatedApp { $0 } }
        else {
            #expect(throws: DirectUpdateZIPError.changed) { try extracted.discard() }
            #expect(try Data(contentsOf: destination.appendingPathComponent(".neantik-next-" + id.uuidString.lowercased() + ".app/file")) == Data([4]))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_TRANSFER_PUBLIC_ARCHIVE"] != nil))
    func exactSignedProvisionedAppSurvivesCustodyTransfer() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_TRANSFER_PUBLIC_ARCHIVE"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        try #require(BackupFS.hex(SHA256.hash(data: bytes)) == "1a445b68a22634ab249573cf4712d9f47552daa9e3d403df0cf0adc360cbc7df")
        let f = try OwnZIPFixture(bytes), extracted = try stage(f), destination = f.root.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        print("Transfer qualification: signature before transfer")
        let before = try DirectUpdateCodeSignature.inspectStage(extracted)
        try #require(before.count == 3)
        print("Transfer qualification: provenance before transfer")
        let provenance = try DirectUpdateRuntimeProvenance.inspectStage(extracted)
        #expect(provenance.chromiumVersion == "156.0.8078.12" && provenance.machoCount == 16)
        print("Transfer qualification: prepare slot")
        let lease = try InstallFilesystemLease(parentURL: destination), slot = try extracted.prepareInstallSlot(lease: lease)
        try slot.withValidatedCandidate { url in
            print("Transfer qualification: signatures after transfer")
            let manager = try DirectUpdateCodeSignature.inspect(url, role: .manager)
            let runtime = try DirectUpdateCodeSignature.inspect(url.appendingPathComponent("Contents/Resources/NeAntik Browser.app"), role: .runtime)
            let framework = try DirectUpdateCodeSignature.inspect(url.appendingPathComponent("Contents/Resources/NeAntik Browser.app/Contents/Frameworks/NeAntik Browser Framework.framework"), role: .framework)
            #expect(manager.version == before[0].version && manager.build == before[0].build && manager.cdHash == before[0].cdHash)
            #expect(runtime.cdHash == before[1].cdHash && framework.cdHash == before[2].cdHash)
            let executable = url.appendingPathComponent("Contents/MacOS/NeAntik")
            #expect(BackupFS.hex(SHA256.hash(data: try Data(contentsOf: executable))) == "8f0e29b3080b1fdb25d4362b9e76597fcf36d0056bd6b82627a17a653be0b099")
        }
        #expect(throws: DirectUpdateZIPError.changed) { try extracted.discard() }
        // OwnZIPFixture removes only its known isolated UUID root. Product stage
        // never deletes a transferred tree. No installed app/Keychain is touched.
    }

}
