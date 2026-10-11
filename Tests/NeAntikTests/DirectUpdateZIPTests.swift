import CryptoKit
import Darwin
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
    func prepare(publicArchive: Bool = false) throws -> PreparedUpdateArchive {
        let version = publicArchive ? "0.7.29" : "0.7.30", build = publicArchive ? 92 : 93
        let payload = UpdateManifestPayload(schemaVersion: 1, product: "NeAntik", edition: "Direct", version: version, build: build,
            issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(86_400),
            archiveName: "NeAntik-\(version)-arm64-notarized.zip", downloadURL: "https://browser.free/downloads/NeAntik-\(version)-arm64-notarized.zip",
            sha256: BackupFS.hex(SHA256.hash(data: bytes)), minimumOS: "14.0", architecture: "arm64",
            artifactKind: "public-notarized", publicReleaseState: "public-ready", chromiumVersion: "156.0.8078.12")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(payload)
        let manifest = try JSONEncoder().encode(SignedUpdateEnvelope(schemaVersion: 1, algorithm: "Ed25519", keyID: "own-zip-fixture",
            payload: body.base64EncodedString(), signature: try key.signature(for: body).base64EncodedString()))
        return try DirectUpdateStageStorage.prepareSynchronously(archiveURL: source, signedManifest: manifest,
            configuration: .init(isEnabled: true, manifestURL: URL(string: "https://browser.free/update.json"),
                publicKeyID: "own-zip-fixture", publicKey: key.publicKey.rawRepresentation),
            installedVersion: "0.7.28", installedBuild: 91, destinationParent: stages,
            hostOS: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), clock: { self.now })
    }
    func inventory() throws -> DirectUpdateZIPInventory {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(fd) }; return try DirectUpdateZIPInventory.read(fd)
    }
    var retainedApps: [String] { (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? [] }
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
        let observed = try DirectUpdateCodeSignature.inspectStage(app)
        #expect(observed.count == 3 && observed.allSatisfy(\.developerIDVerified))
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
        let observed = try DirectUpdateCodeSignature.inspectStage(app)
        #expect(observed.count == 3 && observed[0].version == "0.7.30" && observed[0].build == "93")
        #expect(observed.allSatisfy { $0.developerIDVerified })
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
}
