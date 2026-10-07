import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct MCPProfileManagementTests {
    final class Backend: KeychainBackend, @unchecked Sendable {
        var values: [UUID: Data] = [:]
        var fail = false
        struct Failure: Error {}
        func data(service: String, profileID: UUID) throws -> Data? { values[profileID] }
        func upsert(_ data: Data, service: String, profileID: UUID) throws { if fail { throw Failure() }; values[profileID] = data }
        func delete(service: String, profileID: UUID) throws { if fail { throw Failure() }; values[profileID] = nil }
    }
    func fixture() throws -> (URL, MCPProfileManagement, Backend) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-management-\(UUID())")
        let paths = AppPaths(rootDirectory: root)
        let backend = Backend()
        let engine = MCPProfileManagement(root: root, allowsManagement: true,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil),
            processes: BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent }, allowsExternalProcessSignaling: false))
        return (root, engine, backend)
    }
    func create(_ engine: MCPProfileManagement) async throws -> [String: Any] { try await engine.call("profile_create", ["name": "Synthetic", "changes": ["startURL": "https://example.com", "tags": ["qa"]]]) }
    func request(_ dto: [String: Any]) -> [String: Any] { ["profileID": dto["id"]!, "expectedRevision": dto["revision"]!] }

    @Test func profilePatchNormalizationAndNoopPreserveUnrelatedFields() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine)
        var args = request(profile); args["changes"] = ["name": " Updated ", "tags": ["qa", "QA", "ready"], "isPinned": true]
        let updated = try await engine.call("profile_update", args)
        #expect(updated["name"] as? String == "Updated")
        #expect(updated["tags"] as? [String] == ["qa", "ready"])
        #expect(updated["startURL"] as? String == "https://example.com")
        args = request(updated); args["changes"] = ["isPinned": true]
        #expect(try await engine.call("profile_update", args)["revision"] as? String == updated["revision"] as? String)
        #expect(try ProfileStore.decodeProfiles(Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)).count == 1)
    }
    @Test func staleProfileRevisionDoesNotOverwriteAndUnknownFieldsFail() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine)
        var args = request(profile); args["changes"] = ["name": "First"]
        _ = try await engine.call("profile_update", args)
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_update", args) }
        args = request(try await engine.call("profile_get", ["profileID": profile["id"]!])); args["changes"] = ["launchFlags": "--unsafe"]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_update", args) }
    }
    @Test func folderRevisionMoveAndRemovalRetainProfileData() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine)
        let initial = try await engine.call("folder_list", [:])
        let folders = try await engine.call("folder_create", ["name": "Project", "expectedOrganizationRevision": initial["organizationRevision"]!])
        let folder = try #require((folders["folders"] as? [[String: Any]])?.first)
        await #expect(throws: ProfileMetadataUndoConflict.self) { try await engine.call("folder_create", ["name": "Stale", "expectedOrganizationRevision": initial["organizationRevision"]!]) }
        var move = request(profile); move["folderID"] = folder["id"]!; move["expectedOrganizationRevision"] = folders["organizationRevision"]!
        let moved = try await engine.call("profile_move", move)
        #expect(moved["folderID"] as? String == folder["id"] as? String)
        let removed = try await engine.call("folder_remove", ["folderID": folder["id"]!, "expectedOrganizationRevision": moved["organizationRevision"]!])
        #expect((removed["folders"] as? [[String: Any]])?.isEmpty == true)
        #expect(try await engine.call("profile_get", ["profileID": profile["id"]!])["folderID"] is NSNull)
        #expect(engine.store.profiles.count == 1)
    }
    @Test func proxyFormatsCredentialsAndRollback() async throws {
        let (root, engine, backend) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = try await create(engine)
        for line in ["synthetic:secret@127.0.0.1:8080", "127.0.0.1:8080:synthetic:secret", "synthetic:secret:127.0.0.1:8080"] {
            var args = request(profile); args["proxyLine"] = line; args["kind"] = "http"
            profile = try await engine.call("profile_set_proxy", args)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: profile), as: UTF8.self)
            #expect(!json.contains("secret")); #expect(!json.contains("127.0.0.1")); #expect(!json.contains("synthetic:"))
        }
        let before = try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)
        backend.fail = true
        var args = request(profile); args["proxy"] = ["kind": "http", "host": "127.0.0.2", "port": 8081, "username": "synthetic", "password": "new-secret"]
        await #expect(throws: (any Error).self) { try await engine.call("profile_set_proxy", args) }
        #expect(try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile) == before)
        backend.fail = false
        args = request(profile); args["proxy"] = NSNull()
        profile = try await engine.call("profile_set_proxy", args)
        #expect(profile["proxyKind"] is NSNull); #expect(backend.values.isEmpty)
    }
    @Test func socksAuthenticationAndInvalidURLNeverPersist() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine); let before = try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)
        var args = request(profile); args["proxy"] = ["kind": "socks5", "host": "127.0.0.1", "port": 1080, "username": "synthetic", "password": "secret"]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_set_proxy", args) }
        args = request(profile); args["changes"] = ["startURL": "file:///etc/passwd"]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_update", args) }
        #expect(try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile) == before)
    }
    @Test func duplicateHasFreshIdentityAndNoWebsiteData() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let dto = try await create(engine); let original = try #require(engine.store.profiles.first)
        var args = request(dto); args["name"] = "Copy"
        let copied = try await engine.call("profile_duplicate", args)
        let copy = try #require(engine.store.profile(withID: UUID(uuidString: copied["id"] as! String)))
        #expect(copy.id != original.id); #expect(copy.identity != original.identity); #expect(copy.note.isEmpty)
    }
    @Test func refreshPreservesDraftAndLastGoodStateOnCorruption() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let dto = try await create(engine)
        let ui = ProfileStore(paths: AppPaths(rootDirectory: root)); let draft = try #require(ui.profiles.first)
        var args = request(dto); args["changes"] = ["name": "External"]
        _ = try await engine.call("profile_update", args)
        try await ui.refreshExternalMetadata(force: true)
        #expect(ui.profiles.first?.name == "External"); #expect(draft.name == "Synthetic")
        #expect(throws: BrowserProfileRevisionConflictError.self) { try ui.upsert(draft) }
        try Data("broken".utf8).write(to: AppPaths(rootDirectory: root).profilesFile)
        await #expect(throws: (any Error).self) { try await ui.refreshExternalMetadata(force: true) }
        #expect(ui.profiles.first?.name == "External"); #expect(!ui.hasTrustedMetadata)
    }
    @Test func missingMetadataNeverReplacesLastGoodProfileOrFolders() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await create(engine)
        _ = try await engine.call("folder_create", ["name": "Retained", "expectedOrganizationRevision": NSNull()])
        let paths = AppPaths(rootDirectory: root)
        try FileManager.default.removeItem(at: paths.profileOrganizationFile)
        await #expect(throws: (any Error).self) { try await engine.store.refreshExternalMetadata(force: true) }
        #expect(engine.store.organization.folders.count == 1)
        #expect(engine.store.profiles.count == 1)
    }
    @Test func readOnlyInitializationNeverRepairsCorruptPrimaryFromBackup() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await create(engine)
        let paths = AppPaths(rootDirectory: root)
        let corrupt = Data("broken synthetic metadata".utf8)
        try corrupt.write(to: paths.profilesFile)
        let reader = MCPProfileManagement(root: root, allowsManagement: false)
        #expect(!reader.store.hasTrustedMetadata)
        #expect(try Data(contentsOf: paths.profilesFile) == corrupt)
        await #expect(throws: MCPProfileManagement.Failure.self) { try await reader.call("folder_list", [:]) }
        try FileManager.default.removeItem(at: paths.profilesFile)
        let missingReader = MCPProfileManagement(root: root, allowsManagement: false)
        await #expect(throws: MCPProfileManagement.Failure.self) { try await missingReader.call("folder_list", [:]) }
        #expect(!FileManager.default.fileExists(atPath: paths.profilesFile.path))
    }

    @Test func managementConfigurationIncludesOnlySelectedServerPermissions() throws {
        var config = MCPConnectionConfiguration(executable: URL(fileURLWithPath: "/private/tmp/QA.app/Contents/MacOS/NeAntik"), dataRoot: URL(fileURLWithPath: "/private/tmp/synthetic-mcp", isDirectory: true))
        #expect(!config.arguments.contains(NeAntikLaunchIntent.mcpManagementArgument))
        #expect(!config.codexTOML.contains("profile_create"))
        config.allowsManagement = true
        #expect(NeAntikLaunchIntent.parse(arguments: [config.executable.path] + config.arguments).mode == .mcpManagement(dataRoot: config.dataRoot))
        for tool in MCPProfileManagement.allTools { #expect(config.codexTOML.contains(tool)) }
        #expect(MCPProfileManagement.allTools.count == 17)
        #expect(NeAntikLaunchIntent.parse(arguments: [config.executable.path] + config.arguments + ["--untrusted"]).mode == .invalidControlArguments)
    }

    @Test func readModeAndProtocolRequireExplicitManagementInitialization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MCPManagementSession(root: root, allowsManagement: false)
        func call(_ method: String, _ params: [String: Any] = [:], id: Any? = 1) async throws -> [String: Any]? {
            var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]; if let id { request["id"] = id }
            guard let result = await session.handle(try JSONSerialization.data(withJSONObject: request)) else { return nil }
            return try JSONSerialization.jsonObject(with: result) as? [String: Any]
        }
        #expect(try await call("tools/list")?["error"] != nil)
        _ = try await call("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        #expect(try await call("tools/list")?["error"] != nil)
        _ = try await call("notifications/initialized", id: nil)
        let denied = try await call("tools/call", ["name": "profile_create", "arguments": ["name": "Denied"]])
        #expect((denied?["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
