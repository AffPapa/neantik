import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct MCPProfileManagementTests {
    @Test func savedTemplateCreatesFreshProfileWithoutSecretOrBrowserDataCopies() async throws {
        let (root, engine, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await create(engine)
        let folder = try engine.store.createFolder(named: "QA")
        let original = BrowserProfile(name: "Private original", tags: ["qa"], note: "synthetic-private-note", startURL: "https://example.com/qa")
        let template = try UserProfileTemplate(name: "QA template", profile: original, folderID: folder.id)
        _ = try await ManagerLibraryRepository(paths: engine.store.paths).update { $0.templates.append(template) }
        let read = MCPProfileManagement(root: root, allowsManagement: false)
        let list = try await read.call("template_list", [:])
        let rows = try #require(list["templates"] as? [[String: Any]])
        #expect(rows.count == 1 && rows[0]["id"] as? String == template.id.uuidString)
        #expect(Set(rows[0].keys) == ["id", "name", "startURL", "tags", "folderID"])
        #expect(!(String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)).contains("synthetic-private-note"))
        let args: [String: Any] = ["name": "New QA", "templateID": template.id.uuidString,
            "expectedOrganizationRevision": list["organizationRevision"]!]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await read.call("profile_create", args) }
        let first = try await engine.call("profile_create", args)
        let refreshed = try await engine.call("template_list", [:])
        let second = try await engine.call("profile_create", args.merging(["name": "Second", "folderID": NSNull(), "expectedOrganizationRevision": refreshed["organizationRevision"]!, "changes": ["tags": ["other"]]]) { _, new in new })
        let a = try #require(engine.store.profile(withID: UUID(uuidString: first["id"] as! String)!))
        let b = try #require(engine.store.profile(withID: UUID(uuidString: second["id"] as! String)!))
        #expect(a.id != b.id && a.identity != b.identity && a.identity != original.identity)
        #expect(a.startURL == template.startURL && a.tags == template.tags)
        #expect(a.note.isEmpty && a.proxy == nil && a.lastLaunchedAt == nil)
        #expect(first["folderID"] as? String == folder.id.uuidString)
        #expect(second["folderID"] is NSNull && b.tags == ["other"])
        #expect(engine.processes.processState(for: a.id) == .stopped)
    }

    @Test func savedTemplateRejectsMissingCorruptAndStaleInputsWithoutPartialWrites() async throws {
        let (root, engine, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ManagerLibraryRepository(paths: engine.store.paths)
        let template = try UserProfileTemplate(name: "Fixture", profile: BrowserProfile(name: "Original"), folderID: UUID())
        _ = try await repository.update { $0.templates.append(template) }
        let list = try await engine.call("template_list", [:])
        #expect((list["templates"] as? [[String: Any]])?.first?["folderID"] is NSNull)
        let args: [String: Any] = ["name": "Fixture", "templateID": template.id.uuidString,
            "expectedOrganizationRevision": list["organizationRevision"]!]
        _ = try engine.store.createFolder(named: "Concurrent change")
        await #expect(throws: Error.self) { try await engine.call("profile_create", args) }
        #expect(engine.store.profiles.isEmpty)
        await #expect(throws: Error.self) { try await engine.call("profile_create", ["name": "Missing", "templateID": UUID().uuidString, "expectedOrganizationRevision": NSNull()]) }
        #expect(engine.store.profiles.isEmpty)
        try engine.store.paths.writePrivateFile(Data("bad-library".utf8), to: root.appendingPathComponent("manager-library.json"))
        await #expect(throws: Error.self) { try await engine.call("template_list", [:]) }
        await #expect(throws: Error.self) { try await engine.call("profile_create", args) }
        #expect(engine.store.profiles.isEmpty)
    }
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

    @Test func metadataEditKeepsAuthenticatedSOCKSProxyAndWriteOnlyPassword() async throws {
        let (root, engine, backend) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try await create(engine)
        var args = request(created)
        args["proxy"] = ["kind": "socks5", "host": "127.0.0.1", "port": 1080,
                         "username": "qualification-user", "password": "qualification-password"]
        let configured = try await engine.call("profile_set_proxy", args)
        let id = try #require(UUID(uuidString: configured["id"] as! String))
        let original = try #require(engine.store.profile(withID: id)), secrets = backend.values
        args = request(configured); args["changes"] = ["name": "Renamed", "tags": ["ready"], "startURL": "https://example.com/changed"]
        let edited = try await engine.call("profile_update", args)
        let actual = try #require(engine.store.profile(withID: id))
        #expect(actual.name == "Renamed" && actual.tags == ["ready"])
        #expect(actual.proxy == original.proxy && actual.identity == original.identity && backend.values == secrets)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: edited), as: UTF8.self)
        #expect(!encoded.contains("qualification-password") && !encoded.contains("qualification-user"))
        let persisted = try Data(contentsOf: engine.store.paths.profilesFile)
        args = request(edited); args["proxy"] = ["kind": "socks5", "host": "127.0.0.1", "port": 1080, "username": "qualification-user", "password": ""]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_set_proxy", args) }
        #expect(try Data(contentsOf: engine.store.paths.profilesFile) == persisted)
        #expect(engine.store.profile(withID: id)?.proxy == actual.proxy && backend.values == secrets)
    }

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
    @Test func statusObservationRequiresRevisionAndDoesNotClaimStoppedBrowserEvidence() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine), profileID = profile["id"]!
        let legacy = try await engine.call("profile_status", ["profileID": profileID])
        #expect(Set(legacy.keys) == ["profileID", "processState"])
        var args = request(profile); args["includeObservation"] = true
        let observed = try await engine.call("profile_status", args)
        let value = try #require(observed["observation"] as? [String: Any])
        #expect(value["state"] as? String == "unavailable")
        #expect(value["ownership"] as? String == "notOwned")
        #expect(value["chromiumRoute"] as? String == "notObserved")
        #expect(observed["revision"] as? String == profile["revision"] as? String)
        await #expect(throws: MCPProfileManagement.Failure.self) {
            try await engine.call("profile_status", ["profileID": profileID, "includeObservation": true])
        }
        args["includeObservation"] = 1
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_status", args) }
        args["includeObservation"] = true; args["expectedRevision"] = "18446744073709551615"
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_status", args) }
        args = request(profile); args["includeObservation"] = false
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_status", args) }
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
    @Test func socksAuthenticationPersistsWithoutExposingSecretAndInvalidURLNeverPersists() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine); let before = try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)
        var args = request(profile); args["proxy"] = ["kind": "socks5", "host": "127.0.0.1", "port": 1080, "username": "synthetic", "password": "secret"]
        let saved = try await engine.call("profile_set_proxy", args)
        #expect(saved["proxyKind"] as? String == "socks5")
        #expect(!String(describing: saved).contains("secret"))
        let after = try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)
        #expect(after != before)
        args = request(saved); args["changes"] = ["startURL": "file:///etc/passwd"]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_update", args) }
        #expect(try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile) == after)
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
        #expect(config.arguments.contains(NeAntikLaunchIntent.mcpManagementArgument))
        #expect(NeAntikLaunchIntent.parse(arguments: [config.executable.path] + config.arguments).mode == .mcpManagement(dataRoot: config.dataRoot))
        for tool in MCPProfileManagement.allTools { #expect(config.codexTOML.contains(tool)) }
        #expect(MCPProfileManagement.allTools.count == 18)
        #expect(NeAntikLaunchIntent.parse(arguments: [config.executable.path] + config.arguments + ["--untrusted"]).mode == .invalidControlArguments)
        config.allowsManagement = false
        #expect(!config.arguments.contains(NeAntikLaunchIntent.mcpManagementArgument))
        #expect(!config.codexTOML.contains("profile_create"))
        #expect(NeAntikLaunchIntent.parse(arguments: [config.executable.path] + config.arguments).mode == .mcpStdio(dataRoot: config.dataRoot))
    }

    @Test func folderCorruptionDoesNotPreventStatusOrGracefulStop() async throws {
        let (root, engine, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine)
        let paths = AppPaths(rootDirectory: root)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: paths.profileOrganizationFile)
        let status = try await engine.call("profile_status", ["profileID": profile["id"]!])
        #expect(status["processState"] as? String == "stopped")
        let stop = try await engine.call("profile_stop", ["profileID": profile["id"]!])
        #expect(stop["stopRequested"] as? Bool == false)
        await #expect(throws: (any Error).self) { try await engine.call("folder_list", [:]) }
        #expect(try Data(contentsOf: paths.profileOrganizationFile) == corrupt)
        try Data("{broken".utf8).write(to: paths.profilesFile)
        await #expect(throws: (any Error).self) { try await engine.call("profile_stop", ["profileID": profile["id"]!]) }
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
