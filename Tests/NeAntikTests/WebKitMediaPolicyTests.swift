import Foundation
import Testing
import WebKit
@testable import NeAntik

@Suite(.serialized) @MainActor struct WebKitMediaPolicyTests {
    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    @Test func decisionsNeverGrantAndRejectInvalidAuthority() {
        let id = UUID()
        func decide(_ policy: WebKitMediaPolicy = .ask, owned: Bool = true,
                    persistent: Bool = true, store: UUID? = nil, secure: Bool = true,
                    known: Bool = true) -> WKPermissionDecision {
            policy.decision(owned: owned, persistent: persistent, storeID: store ?? id,
                profileID: id, secureOrigin: secure, knownCaptureType: known)
        }
        #expect(decide() == .prompt)
        #expect(decide(.deny) == .deny)
        #expect(decide(owned: false) == .deny)
        #expect(decide(persistent: false) == .deny)
        #expect(decide(store: UUID()) == .deny)
        #expect(decide(secure: false) == .deny)
        #expect(decide(known: false) == .deny)
        #expect(WebKitMediaPolicy.ask.decision(owned: true, persistent: true, storeID: nil,
            profileID: id, secureOrigin: true, knownCaptureType: true) == .deny)
        for scheme in ["https", "http", "file", "data"] {
            for host in ["localhost", "127.0.0.1", "::1", "[::1]", "localhost.example.com", "example.com"] {
                #expect(WebKitMediaPolicy.permitsOrigin(scheme: scheme, host: host) ==
                    (scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))))
            }
        }
    }
    @Test func legacyAndUnknownPolicyAndChromiumMisuse() throws {
        var object = try #require(JSONSerialization.jsonObject(with: encoder().encode(BrowserProfile(name: "Own legacy"))) as? [String: Any])
        object.removeValue(forKey: "webKitMediaPolicy")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: object)).webKitMediaPolicy == .ask)
        object["webKitMediaPolicy"] = "grant"
        #expect(throws: Error.self) { try decoder.decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: object)) }
        #expect(BrowserProfile(name: "Chromium misuse", webKitMediaPolicy: .deny).normalizedForPersistence() == nil)
    }
    @Test func denySurvivesCloneExportImportAndCannotUseOldSchema() throws {
        let p = BrowserProfile(name: "Own deny", startURL: "about:blank", engine: .webkit, webKitMediaPolicy: .deny)
        let bytes = try ProfileStore.encodeProfiles([p], encoder: encoder())
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 3)
        #expect(try ProfileStore.decodeProfiles(bytes).first?.webKitMediaPolicy == .deny)
        #expect(p.duplicated().webKitMediaPolicy == .deny && p.duplicated().id != p.id)
        for v in [1, 2] {
            object["schemaVersion"] = v
            #expect(throws: Error.self) { try ProfileStore.decodeProfiles(JSONSerialization.data(withJSONObject: object)) }
        }
        let document = try ProfileConfigurationTransferDocument(profiles: [p])
        #expect(document.schemaVersion == 3)
        #expect(try document.makeProfiles().first?.webKitMediaPolicy == .deny)
        #expect(try document.makeProfiles().first?.id != p.id)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var exported = try #require(JSONSerialization.jsonObject(with: encoder().encode(document)) as? [String: Any])
        for v in [1, 2] {
            exported["schemaVersion"] = v
            #expect(throws: Error.self) { try decoder.decode(ProfileConfigurationTransferDocument.self, from: JSONSerialization.data(withJSONObject: exported)) }
        }
        let template = try UserProfileTemplate(name: "Own template", profile: p, folderID: nil)
        #expect(template.makeProfile().webKitMediaPolicy == .deny)
        var library = ManagerLibraryDocument(); library.templates = [template]
        #expect(throws: Error.self) { try library.validate() }
        library.schemaVersion = 2
        #expect(throws: Error.self) { try library.validate() }
        library.schemaVersion = 3
        try library.validate()
    }
    @Test func changedPolicyCannotPassLaunchSnapshotWithUnchangedRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-media-authority-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let p = try store.upsert(BrowserProfile(name: "Own authority", startURL: "about:blank", engine: .webkit))
        try store.validateLaunchSnapshot(p)
        var forged = p; forged.webKitMediaPolicy = .deny
        #expect(throws: Error.self) { try store.validateLaunchSnapshot(forged) }
        let updated = try store.upsert(forged)
        #expect(updated.revision > p.revision)
        #expect(throws: Error.self) { try store.validateLaunchSnapshot(p) }
        try store.validateLaunchSnapshot(updated)
    }
}
