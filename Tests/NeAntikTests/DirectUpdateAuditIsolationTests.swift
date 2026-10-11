import CryptoKit
import Darwin
import DirectInstallFilesystem
import Foundation
import Testing
@testable import DirectUpdateCore
@testable import NeAntik

@Suite(.serialized) struct DirectUpdateAuditIsolationTests {
    private let manifest = Data("synthetic-audit-manifest-not-release-authority".utf8)
    private func fixture() throws -> (URL, URL) {
        let parent = URL(fileURLWithPath: "/private/tmp/neantik-update-audit-" + UUID().uuidString.lowercased())
        let root = parent.appendingPathComponent("manager-data")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (parent, root)
    }
    private func addACL(to url: URL) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "user:" + NSUserName() + " allow read", url.path]
        command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
        try command.run(); command.waitUntilExit()
        try #require(command.terminationReason == .exit && command.terminationStatus == 0)
        let acl = try #require(acl_get_file(url.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        try #require(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0 && entry != nil)
    }
    private func request() throws -> DirectUpdateBootstrapRequest {
        let fields: [String: Any] = ["transactionID": UUID().uuidString, "journalSHA256": String(repeating: "a", count: 64),
            "candidateReceiptSHA256": String(repeating: "b", count: 64), "candidateDevice": 42, "candidateInode": 43]
        let receipt = try JSONDecoder().decode(InstallFilesystemReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
        return try .init(receipt: receipt, cdHash: Data(repeating: 7, count: 20), build: 97,
                         runtimeSHA256: String(repeating: "c", count: 64), nonce: Data(repeating: 8, count: 32))
    }
    @Test func retainedRootAndBoundedFrameRoundTrip() throws {
        let (parent, root) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let captured = try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: manifest)
        let adopted = try DirectUpdateAuditIsolation.adoptAuthenticatedFrame(captured.bytes)
        #expect(adopted.root.path == root.path && adopted.bytes == captured.bytes)
        try captured.validate(); try adopted.validate()
        #expect(String(reflecting: captured).contains(root.path) == false)
        // Content may change; metadata/file writes do not replace root custody.
        try Data("synthetic-profile".utf8).write(to: root.appendingPathComponent("profile.fixture"))
        try captured.validate()
    }
    @Test func auditInitIsBoundToOfferAndUnauditedInitRemainsIdentical() throws {
        let (parent, root) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let captured = try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: manifest)
        let archive = parent.appendingPathComponent("update.zip"), nonce = Data(repeating: 9, count: 32)
        let plain = try DirectUpdateOwnerInit(archive: archive, manifest: manifest, nonce: nonce)
        let audit = try DirectUpdateOwnerInit(archive: archive, manifest: manifest, nonce: nonce, auditFrame: captured.bytes)
        #expect(plain.bytes.prefix(4) == Data("NUI1".utf8) && plain.auditFrame == nil)
        #expect(audit.archive == plain.archive && audit.auditFrame == captured.bytes)
        #expect(audit.digest != plain.digest)
        #expect(try DirectUpdateOwnerInit.parse(audit.bytes) == audit)
        let offer = try DirectUpdateOwnerOffer(request: audit, version: "0.7.34", build: 97,
            archiveSHA256: Data(repeating: 1, count: 32), runtimeSHA256: Data(repeating: 2, count: 32), candidateCDHash: Data(repeating: 3, count: 20))
        #expect(throws: DirectUpdateOwnerProtocolError.reply) { try DirectUpdateOwnerOffer.parse(offer.bytes, request: plain) }
        var changed = captured.bytes; changed[4] ^= 1
        let other = try DirectUpdateOwnerInit(archive: archive, manifest: manifest, nonce: nonce, auditFrame: changed)
        #expect(throws: DirectUpdateOwnerProtocolError.reply) { try DirectUpdateOwnerOffer.parse(offer.bytes, request: other) }
        #expect(throws: DirectUpdateOwnerProtocolError.request) { try DirectUpdateOwnerInit.parse(audit.bytes + Data([0])) }
        #expect(throws: DirectUpdateOwnerProtocolError.request) { try DirectUpdateOwnerInit.parse(Data(audit.bytes.dropLast())) }
    }
    @Test func recordBindsRequestAndReplyRejectsLegacyOrChangedContext() throws {
        let (parent, root) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let isolation = try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: manifest), request = try request()
        let records = parent.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(try DirectUpdateAuditRecord.load(directory: records, request: request) == nil)
        let digest = try DirectUpdateAuditRecord.publish(isolation, request: request, directory: records)
        let observed = try DirectUpdateAuditRecord.load(directory: records, request: request)
        let loaded = try #require(observed)
        #expect(loaded.1 == digest && loaded.0.root.path == root.path)
        let plain = try request.reply(cdHash: request.candidateCDHash, build: request.build, runtimeSHA256: String(repeating: "c", count: 64))
        let audit = try request.reply(cdHash: request.candidateCDHash, build: request.build, runtimeSHA256: String(repeating: "c", count: 64), auditRecordDigest: digest)
        #expect(audit.count == 128 && plain != audit)
        try request.validateReply(plain); try request.validateReply(audit, auditRecordDigest: digest)
        #expect(throws: DirectUpdateInstallSessionError.reply) { try request.validateReply(plain, auditRecordDigest: digest) }
        #expect(throws: DirectUpdateInstallSessionError.reply) { try request.validateReply(audit) }
        #expect(throws: DirectUpdateInstallSessionError.reply) { try request.validateReply(audit, auditRecordDigest: Data(repeating: 0, count: 32)) }
        #expect(throws: DirectUpdateInstallSessionError.reply) { try request.validateReply(audit, auditRecordDigest: Data([1])) }
        #expect(throws: (any Error).self) { try DirectUpdateAuditRecord.publish(isolation, request: request, directory: records) }
        var other = request.bytes; other[4] ^= 1
        #expect(throws: (any Error).self) { try DirectUpdateAuditRecord.load(directory: records, request: .parse(other)) }
    }
    @Test(arguments: ["root", "parent", "mode", "symlink", "flags", "acl"])
    func custodyChangesCannotSelectNewDataRoot(kind: String) throws {
        let (parent, root) = try fixture()
        let moved = parent.appendingPathExtension("moved")
        defer { _ = chflags(root.path, 0); _ = chmod(root.path, 0o700); try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: moved) }
        let retained = try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: manifest)
        switch kind {
        case "parent":
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        case "root", "symlink":
            let old = parent.appendingPathComponent("old")
            try FileManager.default.moveItem(at: root, to: old)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: root, withDestinationURL: old) }
            else { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        case "flags": #expect(chflags(root.path, UInt32(UF_HIDDEN)) == 0)
        case "acl":
            try addACL(to: root)
        default: #expect(chmod(root.path, 0o755) == 0)
        }
        #expect(throws: (any Error).self) { try retained.validate() }
        #expect(throws: (any Error).self) { try DirectUpdateAuditIsolation.adoptAuthenticatedFrame(retained.bytes) }
    }
    @Test(arguments: ["mode", "hardlink", "symlink", "flags", "acl", "truncated", "request", "payload"])
    func unsafeOrChangedRecordsRefuse(kind: String) throws {
        let (parent, root) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let isolation = try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: manifest), request = try request()
        let records = parent.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try DirectUpdateAuditRecord.publish(isolation, request: request, directory: records)
        let file = records.appendingPathComponent(DirectUpdateAuditRecord.name)
        defer { _ = chflags(file.path, 0) }
        switch kind {
        case "mode": #expect(chmod(file.path, 0o644) == 0)
        case "hardlink": #expect(link(file.path, records.appendingPathComponent("extra-link").path) == 0)
        case "symlink":
            let old = records.appendingPathComponent("old")
            try FileManager.default.moveItem(at: file, to: old); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: old)
        case "flags": #expect(chflags(file.path, UInt32(UF_HIDDEN)) == 0)
        case "acl":
            try addACL(to: file)
        default:
            var bytes = try Data(contentsOf: file)
            if kind == "truncated" { bytes.removeLast() }
            else if kind == "request" { bytes[4] ^= 1 }
            else { bytes[36] ^= 1 }
            try bytes.write(to: file)
        }
        #expect(throws: (any Error).self) { try DirectUpdateAuditRecord.load(directory: records, request: request) }
    }
    @Test func syntheticNamespaceAndRawFrameLimitsAreRequired() throws {
        #expect(throws: (any Error).self) { try DirectUpdateAuditIsolation.capture(root: URL(fileURLWithPath: "/private/tmp/manager-data"), validatedManifest: manifest) }
        let (parent, root) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let isolation = try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: manifest)
        for bytes in [Data(), Data(isolation.bytes.dropLast()), isolation.bytes + Data([0]), Data(repeating: 0, count: 9_000)] {
            #expect(throws: (any Error).self) { try DirectUpdateAuditIsolation.adoptAuthenticatedFrame(bytes) }
        }
        var wrongInode = isolation.bytes; wrongInode[51] ^= 1
        #expect(throws: (any Error).self) { try DirectUpdateAuditIsolation.adoptAuthenticatedFrame(wrongInode) }
        #expect(throws: (any Error).self) { try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: Data()) }
    }
    @Test func preparedManifestLimitDiffersFromUpdaterEnvelopeLimit() throws {
        #expect(DirectUpdateAuditIsolation.maximumPreparedManifestBytes == FingerprintEvidenceEnvelopeCodec.maximumManifestBytes)
        let (parent, root) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        for size in [128 * 1_024 + 1, 249_326, DirectUpdateAuditIsolation.maximumPreparedManifestBytes] {
            let manifest = Data(repeating: 0x71, count: size)
            let isolation = try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: manifest)
            #expect(isolation.bytes.subdata(in: 4..<36) == Data(SHA256.hash(data: manifest)))
            try isolation.validate()
        }
        #expect(throws: (any Error).self) {
            try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: Data(repeating: 0, count: DirectUpdateAuditIsolation.maximumPreparedManifestBytes + 1))
        }
    }
    @Test func auditCredentialsAreMemoryOnlyAndDoNotMigrateLegacyValues() throws {
        let backend = ReleaseAuditKeychainBackend(), profile = UUID()
        let store = KeychainStore(backend: backend, service: "synthetic.audit", legacyService: nil)
        try store.saveProxyPassword("synthetic-test-value", profileID: profile)
        #expect(try store.proxyPassword(profileID: profile) == "synthetic-test-value")
        #expect(try KeychainStore(backend: ReleaseAuditKeychainBackend(), service: "synthetic.audit", legacyService: nil).proxyPassword(profileID: profile) == nil)
        try store.deleteProxyPassword(profileID: profile)
        #expect(try store.proxyPassword(profileID: profile) == nil)
    }
}
