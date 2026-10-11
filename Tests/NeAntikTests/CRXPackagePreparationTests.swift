import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

struct CRXPackagePreparationTests {
    private func captured(key: Any? = nil, version: Int = 3, extra: [(String, Data)] = []) throws -> CRXPackageInspection.Captured {
        var manifest: [String: Any] = ["manifest_version": version, "name": "NeAntik CRX QA", "version": "1.0", "permissions": ["storage"],
                                      "action": ["default_popup": "popup.html"]]
        if let key { manifest["key"] = key }
        let files = [("manifest.json", try JSONSerialization.data(withJSONObject: manifest)),
            ("popup.html", Data("<html><body><h1>NeAntik CRX QA</h1><output id='state'></output><script src='popup.js'></script></body></html>".utf8)),
            ("popup.js", Data("chrome.storage.local.get({visits:0},v=>{let n=v.visits+1;chrome.storage.local.set({visits:n},()=>document.getElementById('state').textContent='QA visits: '+n)})".utf8))] + extra
        return try CRXPackageInspection.capture(CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip(files)))
    }
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/neantik-crx-prepare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func parent(_ root: URL, _ package: CRXPackageInspection.Captured) -> URL {
        root.appendingPathComponent("NeAntikPreparedExtensions").appendingPathComponent(package.inspection.extensionID)
    }
    @Test func preparedPayloadPreservesIdentityOriginalAndReceiptWithoutInstalling() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try captured()
        let prepared = try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {})
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: prepared.payload.appendingPathComponent("manifest.json"))) as! [String: Any]
        #expect(Data(base64Encoded: object["key"] as! String) == package.proof.developerSPKI)
        #expect(prepared.extensionID == package.proof.extensionID && prepared.manifestKeyAdded)
        let directory = prepared.payload.deletingLastPathComponent()
        #expect(try Data(contentsOf: directory.appendingPathComponent("original.crx")) == package.bytes)
        let receipt = try JSONDecoder().decode(CRXPackagePreparation.Receipt.self, from: Data(contentsOf: directory.appendingPathComponent("receipt.json")))
        #expect(receipt.status == "prepared-not-installed" && receipt.manifestKeyAdded && receipt.files.count == 3)
        #expect(receipt.preparedManifestSHA256 != receipt.originalManifestSHA256)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Default/Preferences").path))
        #expect(throws: CRXPreparationError.alreadyPrepared) {
            try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {})
        }
    }
    @Test(arguments: [CRXPackagePreparation.Point.created, .writing, .decoded, .extracted, .sealed, .beforePublish])
    func injectedFailureBeforePublicationRollsBackOnlyOwnedStage(_ point: CRXPackagePreparation.Point) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try captured()
        #expect(throws: POSIXError.self) {
            try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}, fault: { reached, _ in
                if reached == point { throw POSIXError(.ENOSPC) }
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent(root, package).path).isEmpty)
    }
    @Test func failureAfterVisibleRenameRetainsExactPublishedFolder() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try captured()
        #expect(throws: CRXPreparationError.retained) {
            try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}, fault: { reached, _ in
                if case .published = reached { throw POSIXError(.EIO) }
            })
        }
        let final = parent(root, package).appendingPathComponent(package.inspection.packageSHA256)
        #expect(try Data(contentsOf: final.appendingPathComponent("original.crx")) == package.bytes)
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("payload/popup.js").path))
    }
    @Test func cancelledDecodedWriterCleansCapturedOwnBytes() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try captured()
        #expect(throws: CancellationError.self) {
            try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}, fault: { reached, _ in
                if case .decoded = reached { throw CancellationError() }
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent(root, package).path).isEmpty)
    }
    @Test func replacementAncestorIsRejectedBeforeWritingIntoIt() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try captured()
        #expect(throws: CRXPreparationError.retained) {
            try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}, fault: { reached, stage in
                if case .writing = reached {
                    let payload = stage.appendingPathComponent("payload")
                    try FileManager.default.moveItem(at: payload, to: stage.appendingPathComponent("displaced"))
                    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
            })
        }
        let stages = try FileManager.default.contentsOfDirectory(atPath: parent(root, package).path)
        #expect(stages.count == 1 && stages[0].hasPrefix(".stage-"))
        let replacement = parent(root, package).appendingPathComponent(stages[0]).appendingPathComponent("payload")
        #expect(try FileManager.default.contentsOfDirectory(atPath: replacement.path).isEmpty)
    }
    @Test func unexpectedEntryCannotBePublishedOrDeletedAsOwned() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try captured()
        #expect(throws: CRXPreparationError.retained) {
            try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}, fault: {
                if case .beforePublish = $0 { try Data("external".utf8).write(to: $1.appendingPathComponent("unexpected")) }
            })
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: parent(root, package).path)
        #expect(names.count == 1 && names[0].hasPrefix(".stage-"))
        #expect(try Data(contentsOf: parent(root, package).appendingPathComponent(names[0]).appendingPathComponent("unexpected")) == Data("external".utf8))
    }
    @Test func replacementAndHardlinkAreNotDeletedOrPublished() throws {
        for hardlink in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let package = try captured()
            #expect(throws: CRXPreparationError.retained) {
                try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}, fault: {
                    if case .beforePublish = $0 {
                        let url = $1.appendingPathComponent("payload/popup.js")
                        if hardlink { try FileManager.default.linkItem(at: url, to: $1.appendingPathComponent("unknown-link")) }
                        else { try Data("replacement".utf8).write(to: url, options: .atomic) }
                    }
                })
            }
            #expect(!FileManager.default.fileExists(atPath: parent(root, package).appendingPathComponent(package.inspection.packageSHA256).path))
        }
    }
    @Test func symlinkNamespaceNeverWritesOutsideProfile() throws {
        let outside = try root(), root = try root(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("NeAntikPreparedExtensions"), withDestinationURL: outside)
        let package = try captured()
        #expect(throws: CRXPreparationError.changed) { try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @Test func authenticatedManifestKeyMismatchAndMV2FailBeforeWrites() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for key in ["wrong", Data(repeating: 1, count: 90).base64EncodedString()] {
            let package = try captured(key: key)
            #expect(throws: CRXPreparationError.keyMismatch) { try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}) }
        }
        let package = try captured(version: 2)
        #expect(throws: CRXPreparationError.incompatible) { try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func matchingAuthenticatedManifestKeyIsPreservedWithoutRewriting() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = P256.Signing.PrivateKey()
        let publicKey = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                             0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0]) + key.publicKey.x963Representation
        let manifest = try JSONSerialization.data(withJSONObject: ["name": "QA", "version": "1", "manifest_version": 3,
                                                                    "key": publicKey.base64EncodedString()])
        let package = try CRXPackageInspection.capture(CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip([("manifest.json", manifest)]), key: key))
        let result = try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {})
        #expect(!result.manifestKeyAdded)
        #expect(try Data(contentsOf: result.payload.appendingPathComponent("manifest.json")) == manifest)
    }
    @Test func changedPackageAndBackupIncompatibleDepthRefuseBeforeWrites() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try captured(), other = try captured()
        #expect(throws: CRXPreparationError.changed) { try CRXPackagePreparation.prepare(one, expected: other.inspection, browserData: root, validate: {}) }
        let path = Array(repeating: "level", count: 26).joined(separator: "/") + "/leaf"
        let deep = try captured(extra: [(path, Data())])
        #expect(throws: CRXPreparationError.incompatible) { try CRXPackagePreparation.prepare(deep, expected: deep.inspection, browserData: root, validate: {}) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func stoppedAuthorityFailurePreventsAllWrites() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try captured()
        #expect(throws: POSIXError.self) { try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: { throw POSIXError(.EBUSY) }) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func cancelledPreparationBeforeStartNeverWrites() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try captured()
        let worker = Task { while !Task.isCancelled { await Task.yield() }; return try CRXPackagePreparation.prepare(package, expected: package.inspection, browserData: root, validate: {}) }
        worker.cancel(); await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// Explicit opt-in artifact for native GUI QA. Never runs in normal tests;
    /// contains only our inert popup and software-generated ephemeral key.
    @Test func writeOwnNativeGUIFixtureWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["NEANTIK_CRX_QA_FIXTURE"], path.hasPrefix("/private/tmp/neantik-crx-ui-fixture-") else { return }
        let package = try captured()
        try package.bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }
}
