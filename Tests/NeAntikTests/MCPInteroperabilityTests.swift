import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct MCPInteroperabilityTests {
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
    @Test func modernDiscoveryIsStatelessAndLegacyStillRequiresHandshake() async throws {
        let (root, session) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let discover = try await request(session, "server/discover", modern: true)["result"] as! [String: Any]
        #expect(discover["resultType"] as? String == "complete")
        #expect((discover["supportedVersions"] as? [String])?.contains("2026-07-28") == true)
        let list = try await request(session, "tools/list", modern: true)["result"] as! [String: Any]
        #expect((list["tools"] as? [[String: Any]])?.count == 6)
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
        config.allowsManagement = true
        for client in [MCPClient.claudeDesktop, .cursor, .vscode, .geminiCLI] {
            let root = try #require(JSONSerialization.jsonObject(with: Data(config.configuration(for: client).utf8)) as? [String: [String: [String: Any]]])
            let server = try #require(root[client == .vscode ? "servers" : "mcpServers"]?["neantik"])
            #expect(server["command"] as? String == config.executable.path)
            #expect(server["args"] as? [String] == config.arguments)
            if client == .vscode { #expect(server["type"] as? String == "stdio") }
            if client == .geminiCLI { #expect(server["trust"] as? Bool == false) }
        }
        #expect(config.configuration(for: .claudeCode).contains("'\\''quoted'\\''"))
        #expect(config.configuration(for: .chatGPTCodex).contains("workspace_query_profiles"))
    }
}
