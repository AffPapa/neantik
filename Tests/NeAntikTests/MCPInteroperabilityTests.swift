import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct MCPInteroperabilityTests {
    #if DEBUG
    @Test func stdioProxyToolsRejectCredentialInputBeforeProfileOrKeychainWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-proxy-credential-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let backend = MCPProfileManagementTests.Backend()
        let engine = MCPProfileManagement(root: root, allowsManagement: true,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp-boundary", legacyService: nil),
            processes: BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false },
                browserDataProcessInspector: { _ in .absent }, allowsExternalProcessSignaling: false))
        let session = MCPManagementSession(root: root, allowsManagement: true, testingEngine: engine)

        let listed = try await request(session, "tools/list", modern: true)
        let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let setProxy = try #require(tools.first { $0["name"] as? String == "profile_set_proxy" })
        let schema = try #require(setProxy["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["order"] == nil)
        let proxyInput = try #require(properties["proxy"] as? [String: Any])
        let choices = try #require(proxyInput["anyOf"] as? [[String: Any]])
        let objectChoice = try #require(choices.first(where: { $0["type"] as? String == "object" }))
        let proxyFields = try #require(objectChoice["properties"] as? [String: Any])
        #expect(Set(proxyFields.keys) == ["kind", "host", "port"])

        let createRejected = try await request(session, "tools/call", ["name": "profile_create", "arguments": [
            "name": "Rejected proxy", "proxy": ["kind": "http", "host": "127.0.0.1", "port": 8080,
                "username": "synthetic-user", "password": "synthetic-secret"]]], modern: true)
        let createError = try #require(createRejected["result"] as? [String: Any])
        #expect(createError["isError"] as? Bool == true)
        #expect((createError["_meta"] as? [String: Any])?["app.neantik/errorCode"] as? String == "invalid_fields")
        #expect(engine.store.profiles.isEmpty && backend.values.isEmpty)
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: createRejected), as: UTF8.self).contains("synthetic-secret"))

        let created = try await request(session, "tools/call", ["name": "profile_create", "arguments": [
            "name": "Endpoint only", "proxy": ["kind": "http", "host": "proxy.synthetic.example", "port": 8080]]], modern: true)
        let createdResult = try #require((created["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        let profileID = try #require(UUID(uuidString: createdResult["id"] as! String))
        let before = try Data(contentsOf: paths.profilesFile)
        let setRejected = try await request(session, "tools/call", ["name": "profile_set_proxy", "arguments": [
            "profileID": profileID.uuidString, "expectedRevision": createdResult["revision"]!,
            "proxy": ["kind": "http", "host": "127.0.0.2", "port": 8081,
                "username": "synthetic-user", "password": "synthetic-secret"]]], modern: true)
        let setError = try #require(setRejected["result"] as? [String: Any])
        #expect(setError["isError"] as? Bool == true)
        #expect((setError["_meta"] as? [String: Any])?["app.neantik/errorCode"] as? String == "invalid_fields")
        #expect(try Data(contentsOf: paths.profilesFile) == before && backend.values.isEmpty)
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: setRejected), as: UTF8.self).contains("synthetic-secret"))
    }

    @Test func readOnlyMCPProfileGetExposesDNSPolicyWithExplicitUnverifiedRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-network-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MCPProfileManagement(root: root, allowsManagement: true)
        let profile = try writer.store.upsert(BrowserProfile(
            name: "Synthetic proxy profile",
            proxy: ProxyConfiguration(kind: .http, host: "proxy.synthetic.example", port: 8080, username: "fixture-user")
        ))
        let reader = MCPProfileManagement(root: root, allowsManagement: false)
        let session = MCPManagementSession(root: root, allowsManagement: false, testingEngine: reader)

        let listed = try await request(session, "tools/list", modern: true)
        let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let profileGet = try #require(tools.first { $0["name"] as? String == "profile_get" })
        #expect((profileGet["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        let outputSchema = try #require(profileGet["outputSchema"] as? [String: Any])
        #expect(((outputSchema["properties"] as? [String: Any])?["networkPolicyIntent"] as? [String: Any]) != nil)

        let reply = try await request(session, "tools/call", ["name": "profile_get", "arguments": ["profileID": profile.id.uuidString]], modern: true)
        let result = try #require(reply["result"] as? [String: Any])
        let value = try #require(result["structuredContent"] as? [String: Any])
        let policy = try #require(value["networkPolicyIntent"] as? [String: Any])
        #expect(policy["proxyHostnameDNS"] as? String == "systemResolverMayResolveProxyHostname")
        #expect(policy["runtimeRoute"] as? String == "unverified")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        #expect(!encoded.contains("proxy.synthetic.example") && !encoded.contains("fixture-user"))

        let denied = try await request(session, "tools/call", ["name": "profile_set_proxy", "arguments": ["profileID": profile.id.uuidString]], modern: true)
        let deniedResult = try #require(denied["result"] as? [String: Any])
        #expect(deniedResult["isError"] as? Bool == true)
        #expect((deniedResult["_meta"] as? [String: Any])?["app.neantik/errorCode"] as? String == "management_disabled")
        #expect(reader.store.profile(withID: profile.id)?.revision == profile.revision)
    }

    @Test func failedCommitAndRollbackReportsUncertainStateWithoutSecrets() async throws {
        struct SyntheticError: LocalizedError {
            var errorDescription: String? { "secret-token /private/synthetic/profile" }
        }
        let failure = ProfileSaveRollbackError(operationError: SyntheticError(), rollbackError: SyntheticError())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-rollback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MCPManagementSession(root: root, testingToolFailure: failure)
        let response = try await request(session, "tools/call", ["name": "profile_create", "arguments": ["name": "Synthetic"]], modern: true, id: 42)
        let result = try #require(response["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(meta["app.neantik/errorCode"] as? String == "storage_state_uncertain")
        #expect(meta["app.neantik/automaticRetry"] as? Bool == false)
        let wire = try #require(String(data: JSONSerialization.data(withJSONObject: response), encoding: .utf8))
        #expect(wire.contains("rollback could not be confirmed"))
        #expect(!wire.contains("Existing data retained"))
        #expect(!wire.contains("secret-token") && !wire.contains("/private/synthetic/profile"))
        let fallback = MCPManagementSession(root: root, testingToolFailure: SyntheticError())
        let generic = try await request(fallback, "tools/call", ["name": "profile_create", "arguments": ["name": "Synthetic"]], modern: true)
        let genericWire = try #require(String(data: JSONSerialization.data(withJSONObject: generic), encoding: .utf8))
        #expect(genericWire.contains("operation_unavailable"))
        #expect(!genericWire.contains("Existing data retained") && !genericWire.contains("secret-token"))
    }
    #endif
    func request(_ session: MCPManagementSession, _ method: String, _ params: [String: Any] = [:], modern: Bool = false, id: Int = 1) async throws -> [String: Any] {
        var params = params
        if modern { params["_meta"] = ["io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": [:]] }
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let response = try #require(await session.handle(data))
        return try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }
    func fixture() -> (URL, MCPManagementSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-modern-\(UUID())")
        return (root, MCPManagementSession(root: root, allowsManagement: false))
    }

    @Test func stoppedAdmissionReasonsSurviveProtocolWithoutMetadataChanges() async throws {
        let controls: [(BrowserDataProcessInspection, String?)] = [
            (.unknown, "inspection_unavailable"),
            (.found, "browser_data_in_use"),
            (.absent, "lease_present"),
            (.absent, "unsafe_lease"),
            (.absent, nil)
        ]
        for modern in [false, true] {
            for (inspection, expectedReason) in controls {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-admission-\(UUID())")
                defer { try? FileManager.default.removeItem(at: root) }
                let paths = AppPaths(rootDirectory: root)
                let backend = MCPProfileManagementTests.Backend()
                let engine = MCPProfileManagement(root: root, allowsManagement: true,
                    keychain: KeychainStore(backend: backend, service: "synthetic-admission", legacyService: nil),
                    processes: BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false },
                        browserDataProcessInspector: { _ in inspection }, allowsExternalProcessSignaling: false))
                let session = MCPManagementSession(root: root, allowsManagement: true, testingEngine: engine)
                if !modern {
                    _ = try await request(session, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "owned-admission", "version": "1"]])
                    _ = await session.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
                }
                let created = try await request(session, "tools/call", ["name": "profile_create", "arguments": ["name": "Owned before", "changes": ["startURL": "about:blank"]]], modern: modern)
                let dto = try #require((created["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
                let id = try #require(UUID(uuidString: dto["id"] as! String))
                let before = try Data(contentsOf: paths.profilesFile)
                let organizationBefore = try? Data(contentsOf: paths.profileOrganizationFile)
                let sentinel = paths.browserDataDirectory(for: id).appendingPathComponent("owned-data-sentinel")
                try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let sentinelBytes = Data("owned-unchanged-data".utf8)
                try sentinelBytes.write(to: sentinel)
                if expectedReason == "lease_present" {
                    try paths.writePrivateFile(Data("owned-reservation".utf8), to: paths.lockFile(for: id))
                } else if expectedReason == "unsafe_lease" {
                    try FileManager.default.createSymbolicLink(at: paths.lockFile(for: id), withDestinationURL: sentinel)
                }
                let reply = try await request(session, "tools/call", ["name": "profile_update", "arguments": [
                    "profileID": id.uuidString, "expectedRevision": dto["revision"]!, "changes": ["name": "Owned after"]
                ]], modern: modern)
                let result = try #require(reply["result"] as? [String: Any])
                if let expectedReason {
                    #expect(result["isError"] as? Bool == true)
                    let meta = try #require(result["_meta"] as? [String: Any])
                    #expect(meta["app.neantik/errorCode"] as? String == "profile_not_stopped")
                    #expect(meta["app.neantik/blockReason"] as? String == expectedReason)
                    #expect(meta["app.neantik/automaticRetry"] as? Bool == false)
                    let message = try #require(meta["app.neantik/nextAction"] as? String)
                    if inspection == .unknown {
                        #expect(message.contains("Could not verify"))
                        #expect(!message.contains("Close its browser"))
                        #expect(!message.contains("Profile browser is open"))
                    }
                    #expect(!message.contains(root.path))
                    #expect(try Data(contentsOf: paths.profilesFile) == before)
                    #expect((try? Data(contentsOf: paths.profileOrganizationFile)) == organizationBefore)
                    #expect(engine.store.profile(withID: id)?.name == "Owned before")
                    #expect(String(engine.store.profile(withID: id)!.revision) == dto["revision"] as? String)

                } else {
                    #expect(result["isError"] as? Bool != true)
                    let changed = try #require(result["structuredContent"] as? [String: Any])
                    #expect(changed["name"] as? String == "Owned after")
                    #expect(changed["revision"] as? String != dto["revision"] as? String)
                    #expect(try Data(contentsOf: paths.profilesFile) != before)
                }
                #expect(try Data(contentsOf: sentinel) == sentinelBytes)
                #expect(backend.reads == 0)
                #expect(backend.values.isEmpty)
            }
        }
    }
    @Test func modernDiscoveryIsStatelessAndLegacyStillRequiresHandshake() async throws {
        let (root, session) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let discover = try await request(session, "server/discover", modern: true)["result"] as! [String: Any]
        #expect(discover["resultType"] as? String == "complete")
        #expect((discover["supportedVersions"] as? [String])?.contains("2026-07-28") == true)
        let list = try await request(session, "tools/list", modern: true)["result"] as! [String: Any]
        #expect((list["tools"] as? [[String: Any]])?.count == 7)
        #expect(list["cacheScope"] as? String == "private")
        #expect(try await request(session, "tools/list")["error"] != nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func unsupportedAndInvalidModernMetadataNeverCreatesWorkspace() async throws {
        let (root, session) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for value: Any in [NSNull(), [], 1] {
            let reply = try await request(session, "tools/list", ["_meta": value])
            #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
        let reply = try await request(session, "server/discover", ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01", "io.modelcontextprotocol/clientCapabilities": [:]]])
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32022)
        #expect(((reply["error"] as? [String: Any])?["data"] as? [String: Any])?["requested"] as? String == "1900-01-01")
        for meta: [String: Any] in [["io.modelcontextprotocol/protocolVersion": "2026-07-28"], ["io.modelcontextprotocol/clientCapabilities": [:]], ["io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": NSNull()]] {
            #expect((try await request(session, "tools/list", ["_meta": meta])["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func malformedInitializedDoesNotUnlockLegacy() async throws {
        let (_, session) = fixture()
        _ = try await request(session, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "fixture", "version": "1"]])
        for value: Any in [[], NSNull(), ["extra": true]] {
            _ = await session.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized", "params": value]))
            #expect(try await request(session, "tools/list")["error"] != nil)
        }
        _ = await session.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        #expect(try await request(session, "tools/list")["result"] != nil)
    }
    @Test func promptsAreStaticReadOnlyAndErrorsMachineReadable() async throws {
        let (root, session) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let list = try await request(session, "prompts/list", modern: true)["result"] as! [String: Any]
        #expect((list["prompts"] as? [[String: Any]])?.count == 3)
        let prompt = try await request(session, "prompts/get", ["name": "organize_project"], modern: true)
        let bytes = try JSONSerialization.data(withJSONObject: prompt)
        #expect(String(decoding: bytes, as: UTF8.self).contains("Read mode"))
        #expect(try await request(session, "prompts/get", ["name": "unknown"], modern: true)["error"] != nil)
        let denied = try await request(session, "tools/call", ["name": "profile_create", "arguments": ["name": "Denied"]], modern: true)["result"] as! [String: Any]
        #expect((denied["_meta"] as? [String: Any])?["app.neantik/errorCode"] as? String == "management_disabled")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func allClientJSONVariantsPreserveArgvAndPermissions() throws {
        var config = MCPConnectionConfiguration(executable: URL(fileURLWithPath: "/private/tmp/QA 'quoted'.app/Contents/MacOS/NeAntik"), dataRoot: URL(fileURLWithPath: "/private/tmp/synthetic root"))
        for manage in [true, false] {
            config.allowsManagement = manage
            for client in [MCPClient.claudeDesktop, .cursor, .vscode, .geminiCLI] {
                let root = try #require(JSONSerialization.jsonObject(with: Data(config.configuration(for: client).utf8)) as? [String: [String: [String: Any]]])
                let server = try #require(root[client == .vscode ? "servers" : "mcpServers"]?["neantik"])
                #expect(server["command"] as? String == config.executable.path)
                let arguments = try #require(server["args"] as? [String])
                #expect(arguments == config.arguments)
                #expect(arguments.contains(NeAntikLaunchIntent.mcpManagementArgument) == manage)
                if client == .vscode { #expect(server["type"] as? String == "stdio") }
                if client == .geminiCLI { #expect(server["trust"] as? Bool == false) }
            }
            for client in [MCPClient.claudeCode, .grokCLI] {
                let command = config.configuration(for: client)
                #expect(command.contains("'\\''quoted'\\''"))
                #expect(command.contains(NeAntikLaunchIntent.mcpManagementArgument) == manage)
            }
            let toml = config.configuration(for: .chatGPTCodex)
            #expect(toml.contains("workspace_query_profiles"))
            #expect(toml.contains("profile_create") == manage)
            #expect(toml.contains(NeAntikLaunchIntent.mcpManagementArgument) == manage)
        }
    }
}
