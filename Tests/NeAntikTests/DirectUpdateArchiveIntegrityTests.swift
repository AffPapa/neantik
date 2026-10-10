import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

private final class OwnUpdateIntegrityFixture: @unchecked Sendable {
    let root: URL, archive: URL
    let key = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let bytes: Data
    var configuration: UpdateChannelConfiguration {
        .init(isEnabled: true, manifestURL: URL(string: "https://browser.free/update.json"),
              publicKeyID: "own-fixture", publicKey: key.publicKey.rawRepresentation)
    }
    init(bytes: Data = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18))) throws {
        root = URL(fileURLWithPath: "/private/tmp/neantik-update-integrity-" + UUID().uuidString)
        archive = root.appendingPathComponent("own.zip"); self.bytes = bytes
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: archive); _ = chmod(archive.path, 0o600)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func envelope(version: String = "1.0.0", build: Int = 88, minimumOS: String = "14.0",
                  digest: String? = nil, expiresAt: Date? = nil) throws -> Data {
        let payload = UpdateManifestPayload(schemaVersion: 1, product: "NeAntik", edition: "Direct", version: version, build: build,
            issuedAt: now.addingTimeInterval(-60), expiresAt: expiresAt ?? now.addingTimeInterval(86_400),
            archiveName: "NeAntik-\(version)-arm64-notarized.zip",
            downloadURL: "https://browser.free/downloads/NeAntik-\(version)-arm64-notarized.zip",
            sha256: digest ?? BackupFS.hex(SHA256.hash(data: bytes)), minimumOS: minimumOS, architecture: "arm64",
            artifactKind: "public-notarized", publicReleaseState: "public-ready", chromiumVersion: "156.0.8078.12")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(payload)
        return try JSONEncoder().encode(SignedUpdateEnvelope(schemaVersion: 1, algorithm: "Ed25519", keyID: "own-fixture",
            payload: encoded.base64EncodedString(), signature: try key.signature(for: encoded).base64EncodedString()))
    }
    func verify(envelope: Data? = nil, url: URL? = nil, byteLimit: Int64 = DirectUpdateArchiveIntegrityService.maximumArchiveBytes,
                clock: (@Sendable () -> Date)? = nil,
                fault: (@Sendable (DirectUpdateArchiveIntegrityPoint) throws -> Void)? = nil) throws -> UpdateArchiveIntegrityReceipt {
        try DirectUpdateArchiveIntegrityService.verifySynchronously(archiveURL: url ?? archive, signedManifest: envelope ?? self.envelope(),
            configuration: configuration, installedVersion: "0.7.24", installedBuild: 87,
            hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: clock ?? { self.now }, byteLimit: byteLimit, fault: fault)
    }
}

private final class IntegrityTestClock: @unchecked Sendable {
    let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}

private func integrityFixtureWait(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
}

struct DirectUpdateArchiveIntegrityTests {
    @Test func actualOwnZIPMatchesAuthenticManifestWithoutInstallationClaims() throws {
        let f = try OwnUpdateIntegrityFixture(), result = try f.verify()
        #expect(result.version == "1.0.0" && result.build == 88)
        #expect(result.archiveBytes == 22 && result.sha256 == BackupFS.hex(SHA256.hash(data: f.bytes)))
        #expect(result.manifestSignatureVerified && result.archiveBytesMatchManifest)
        #expect(!result.archiveSafetyVerified && !result.developerIDVerified && !result.notarizationVerified && !result.installed)
        #expect(try Data(contentsOf: f.archive) == f.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == ["own.zip"])
    }

    @Test func validHashAloneDoesNotAssertZIPOrNotarization() throws {
        let f = try OwnUpdateIntegrityFixture(bytes: Data("not a ZIP or an application".utf8))
        let receipt = try f.verify()
        #expect(receipt.archiveBytesMatchManifest)
        #expect(!receipt.archiveSafetyVerified && !receipt.notarizationVerified && !receipt.installed)
    }

    @Test(arguments: ["modified", "appended", "truncated"])
    func alteredArchiveFailsDigest(kind: String) throws {
        let f = try OwnUpdateIntegrityFixture(), signed = try f.envelope()
        var changed = f.bytes
        switch kind { case "modified": changed[5] ^= 1; case "appended": changed.append(0); default: changed.removeLast() }
        try changed.write(to: f.archive)
        #expect(throws: DirectUpdateArchiveIntegrityError.digestMismatch) { try f.verify(envelope: signed) }
    }

    @Test func authenticallySignedWrongHashRefuses() throws {
        let f = try OwnUpdateIntegrityFixture()
        #expect(throws: DirectUpdateArchiveIntegrityError.digestMismatch) { try f.verify(envelope: f.envelope(digest: String(repeating: "a", count: 64))) }
    }

    @Test func invalidSignatureRejectedBeforeSourceAccess() throws {
        let f = try OwnUpdateIntegrityFixture(), valid = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: f.envelope())
        let changed = SignedUpdateEnvelope(schemaVersion: valid.schemaVersion, algorithm: valid.algorithm, keyID: valid.keyID,
            payload: valid.payload, signature: Data(repeating: 0, count: 64).base64EncodedString())
        #expect(throws: UpdateManifestError.invalidSignature) { try f.verify(envelope: JSONEncoder().encode(changed), url: f.root.appendingPathComponent("absent.zip")) }
    }

    @Test func disabledChannelRejectedBeforeSourceAccess() throws {
        let f = try OwnUpdateIntegrityFixture()
        #expect(throws: UpdateManifestError.channelDisabled) {
            try DirectUpdateArchiveIntegrityService.verifySynchronously(archiveURL: f.root.appendingPathComponent("absent.zip"),
                signedManifest: f.envelope(), configuration: .init(isEnabled: false, manifestURL: nil, publicKeyID: nil, publicKey: nil),
                installedVersion: "0.7.24", installedBuild: 87, hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: { f.now })
        }
    }

    @Test(arguments: [("0.7.24", 87), ("0.7.23", 88), ("1.0.0", 87), ("1.0.0", 86)])
    func rollbackAdmissionRefusesBeforeFileAccess(candidate: (String, Int)) throws {
        let f = try OwnUpdateIntegrityFixture()
        #expect(throws: DirectUpdateArchiveIntegrityError.notNewer) {
            try f.verify(envelope: f.envelope(version: candidate.0, build: candidate.1), url: f.root.appendingPathComponent("absent.zip"))
        }
    }

    @Test func futureMinimumOSRejectedBeforeSourceAccess() throws {
        let f = try OwnUpdateIntegrityFixture()
        #expect(throws: DirectUpdateArchiveIntegrityError.incompatibleOS) {
            try f.verify(envelope: f.envelope(minimumOS: "27.0.1"), url: f.root.appendingPathComponent("absent.zip"))
        }
    }

    @Test func expiredAtStartAndDuringReadRefuse() throws {
        let f = try OwnUpdateIntegrityFixture()
        #expect(throws: UpdateManifestError.expired) { try f.verify(envelope: f.envelope(expiresAt: f.now.addingTimeInterval(-301)), url: f.root.appendingPathComponent("absent.zip")) }
        let clock = IntegrityTestClock(f.now), signed = try f.envelope(expiresAt: f.now.addingTimeInterval(60))
        #expect(throws: UpdateManifestError.expired) {
            try f.verify(envelope: signed, clock: { clock.read() }, fault: { point in
                if case .beforeFinalValidation = point { clock.set(f.now.addingTimeInterval(361)) }
            })
        }
    }

    @Test(arguments: ["symlink", "fifo", "directory", "hardlink", "ancestor-symlink"])
    func nonRegularAndUnownedPathsRefuse(kind: String) throws {
        let f = try OwnUpdateIntegrityFixture(), path = f.root.appendingPathComponent("unsafe.zip")
        var target = path
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: f.archive)
        case "fifo": #expect(mkfifo(path.path, 0o600) == 0)
        case "directory": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        case "hardlink": #expect(link(f.archive.path, path.path) == 0)
        default:
            let alias = f.root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
            target = alias.appendingPathComponent("own.zip")
        }
        #expect(throws: DirectUpdateArchiveIntegrityError.unsafeFile) { try f.verify(url: target) }
        #expect(try Data(contentsOf: f.archive) == f.bytes)
    }

    @Test(arguments: [Int64(0), 21, DirectUpdateArchiveIntegrityService.maximumArchiveBytes + 1])
    func boundedArchiveSizeRefuses(limit: Int64) throws {
        let f = try OwnUpdateIntegrityFixture()
        #expect(throws: DirectUpdateArchiveIntegrityError.limitExceeded) { try f.verify(byteLimit: limit) }
    }

    @Test(arguments: ["replace", "inplace", "grow", "truncate", "parent-replace"])
    func sourceChangesNeverProduceReceipt(kind: String) throws {
        let f = try OwnUpdateIntegrityFixture(bytes: Data(repeating: 0x41, count: 196_613))
        let signed = try f.envelope(), retained = f.root.appendingPathExtension("retained")
        defer { try? FileManager.default.removeItem(at: retained) }
        #expect(throws: DirectUpdateArchiveIntegrityError.archiveChanged) {
            try f.verify(envelope: signed, fault: { point in
                guard case .chunkHashed(let offset) = point, offset == 65_536 else { return }
                switch kind {
                case "replace":
                    try FileManager.default.moveItem(at: f.archive, to: f.root.appendingPathComponent("original.zip"))
                    try Data(repeating: 0x42, count: f.bytes.count).write(to: f.archive)
                case "parent-replace":
                    try FileManager.default.moveItem(at: f.root, to: retained)
                    try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
                    try Data("replacement preserved".utf8).write(to: f.archive)
                default:
                    var initial = stat(); #expect(lstat(f.archive.path, &initial) == 0)
                    let h = try FileHandle(forWritingTo: f.archive); defer { try? h.close() }
                    if kind == "truncate" { try h.truncate(atOffset: 10) }
                    else { try h.seek(toOffset: kind == "grow" ? UInt64(f.bytes.count) : 0); try h.write(contentsOf: Data([0x43])) }
                    // Change the ALREADY hashed prefix, then restore mtime
                    // at exact nanosecond precision. Without ctime checks a
                    // one-pass hash could issue a stale matching receipt.
                    var times = [initial.st_atimespec, initial.st_mtimespec]
                    #expect(futimens(h.fileDescriptor, &times) == 0)
                    if kind == "inplace" {
                        var after = stat(); #expect(fstat(h.fileDescriptor, &after) == 0)
                        #expect(after.st_ino == initial.st_ino && after.st_dev == initial.st_dev && after.st_size == initial.st_size)
                        #expect(after.st_mode == initial.st_mode && after.st_nlink == initial.st_nlink)
                        #expect(after.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec)
                        #expect(after.st_ctimespec.tv_sec != initial.st_ctimespec.tv_sec || after.st_ctimespec.tv_nsec != initial.st_ctimespec.tv_nsec)
                    }
                }
            })
        }
        #expect(FileManager.default.fileExists(atPath: f.archive.path))
        if kind == "parent-replace" { #expect(try Data(contentsOf: f.archive) == Data("replacement preserved".utf8)) }
    }

    @Test @MainActor func asyncHashRunsOffMainActorAndPreservesSource() async throws {
        let f = try OwnUpdateIntegrityFixture(bytes: Data(repeating: 0x44, count: 196_613))
        let receipt = try await DirectUpdateArchiveIntegrityService.verify(archiveURL: f.archive, signedManifest: f.envelope(),
            configuration: f.configuration, installedVersion: "0.7.24", installedBuild: 87,
            hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: { f.now },
            fault: { _ in #expect(!Thread.isMainThread) })
        #expect(receipt.archiveBytes == 196_613 && !receipt.installed)
        #expect(try Data(contentsOf: f.archive) == f.bytes)
    }

    @Test(arguments: ["hardlink", "mode", "final-clock-write"])
    func lastBoundaryMutationCannotIssueReceipt(kind: String) throws {
        let f = try OwnUpdateIntegrityFixture()
        let clock = IntegrityTestClock(f.now)
        #expect(throws: DirectUpdateArchiveIntegrityError.archiveChanged) {
            try f.verify(clock: {
                let current = clock.read()
                if kind == "final-clock-write", current != f.now {
                    let fd = Darwin.open(f.archive.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { Issue.record("Own final-clock fixture write unavailable"); return current }
                    defer { Darwin.close(fd) }
                    var byte: UInt8 = 0x43
                    #expect(Darwin.pwrite(fd, &byte, 1, 0) == 1)
                }
                return current
            }, fault: { point in
                guard case .beforeFinalValidation = point else { return }
                switch kind {
                case "hardlink": #expect(link(f.archive.path, f.root.appendingPathComponent("linked.zip").path) == 0)
                case "mode": #expect(chmod(f.archive.path, 0o644) == 0)
                default: clock.set(f.now.addingTimeInterval(1))
                }
            })
        }
        #expect(FileManager.default.fileExists(atPath: f.archive.path))
    }

    @Test func cancelledAsyncParentCancelsReadAndCannotReturnReceipt() async throws {
        let f = try OwnUpdateIntegrityFixture(bytes: Data(repeating: 0x45, count: 196_613))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let signed = try f.envelope()
        let work = Task {
            try await DirectUpdateArchiveIntegrityService.verify(archiveURL: f.archive, signedManifest: signed,
                configuration: f.configuration, installedVersion: "0.7.24", installedBuild: 87,
                hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: { f.now },
                fault: { point in
                    if case .chunkHashed(let offset) = point, offset == 65_536 {
                        entered.signal()
                        guard release.wait(timeout: .now() + 5) == .success else { throw DirectUpdateArchiveIntegrityError.readFailed }
                    }
                })
        }
        let admitted = await Task.detached { integrityFixtureWait(entered) }.value
        #expect(admitted); work.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try Data(contentsOf: f.archive) == f.bytes)
    }

    @Test func alreadyCancelledWorkerRefusesBeforeSignatureOrFile() async throws {
        let f = try OwnUpdateIntegrityFixture(), ready = DispatchSemaphore(value: 0)
        let work = Task.detached {
            guard integrityFixtureWait(ready) else { throw DirectUpdateArchiveIntegrityError.readFailed }
            return try f.verify(envelope: Data(), url: f.root.appendingPathComponent("absent.zip"))
        }
        work.cancel(); ready.signal()
        await #expect(throws: CancellationError.self) { try await work.value }
    }
}
