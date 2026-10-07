import Foundation
import Testing
@testable import NeAntik

struct MCPStdioServerTests {
    private func call(_ method: String, id: Int = 1, params: [String: Any] = [:], root: URL) -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try! JSONSerialization.data(withJSONObject: request)
        let response = MCPStdioServer.handle(data, dataRoot: root)!
        return try! JSONSerialization.jsonObject(with: response) as! [String: Any]
    }

    @Test func largeWorkspacePagesRemainBoundedAndRevisionBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-mcp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profiles = (0..<5000).map { BrowserProfile(name: "Synthetic \($0)", note: String(repeating: "🙂", count: 1000)) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        #expect(data.count > 16 * 1024 * 1024)
        let file = root.appendingPathComponent("profiles.json")
        try data.write(to: file)
        func page(cursor: String? = nil) throws -> [String: Any] {
            var arguments: [String: Any] = ["limit": 100]
            if let cursor { arguments["cursor"] = cursor }
            let reply = call("tools/call", params: ["name": "workspace_list_profiles_page", "arguments": arguments], root: root)
            let result = try #require(reply["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            let text = try #require(content.first?["text"] as? String)
            #expect(text.utf8.count <= MCPStdioServer.maximumToolPayloadBytes)
            if result["isError"] as? Bool == true { return ["error": text] }
            return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let first = try page()
        #expect(first["count"] as? Int == 100)
        #expect(first["totalCount"] as? Int == 5000)
        let cursor = try #require(first["nextCursor"] as? String)
        let second = try page(cursor: cursor)
        #expect(second["count"] as? Int == 100)
        #expect(try page(cursor: "bad")["error"] != nil)
        try encoder.encode(Array(profiles.dropLast())).write(to: file)
        #expect(try page(cursor: cursor)["error"] != nil)
    }

    @Test func listsOnlyAllowlistedMetadataAndNeverClaimsRunningState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = BrowserProfile(name: "Test profile", tags: ["work"], note: "PRIVATE_NOTE")
        // The fixture includes private input fields, which must never appear on stdout.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: root.appendingPathComponent("profiles.json"))
        let response = call("tools/call", params: ["name": "workspace_list_profiles", "arguments": [:]], root: root)
        let output = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        #expect(output.contains("Test profile"))
        #expect(output.contains("unverified"))
        #expect(!output.contains("PRIVATE_NOTE"))
        #expect(!output.contains(root.path))
        #expect(!output.contains("proxyHost"))
    }

    @Test func refusesSymlinkAndOversizedMetadataWithoutLeakingPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("profiles.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        var response = call("tools/call", params: ["name": "workspace_list_profiles"], root: root)
        #expect(response["error"] == nil)
        #expect(response["result"] as? [String: Any] != nil)
        try FileManager.default.removeItem(at: file)
        try Data(count: MCPStdioServer.maximumProfilesFileBytes + 1).write(to: file)
        response = call("tools/call", params: ["name": "workspace_list_profiles"], root: root)
        let output = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        #expect(output.contains("requires recovery"))
        #expect(!output.contains(root.path))
    }

    @Test func protocolMethodsAreConstrained() {
        let root = URL(fileURLWithPath: "/private/tmp/missing-neantik-mcp-root")
        #expect(call("initialize", root: root)["result"] != nil)
        let tools = call("tools/list", root: root)
        #expect(String(describing: tools).contains("workspace_list_profiles"))
        #expect(call("profile_delete", root: root)["error"] != nil)
        #expect(call("tools/call", params: ["name": "profile_launch"], root: root)["error"] != nil)
    }

    @Test func malformedRequestsDoNotReceiveSuccessfulResponses() throws {
        let root = URL(fileURLWithPath: "/private/tmp/missing-neantik-mcp-root")
        func response(_ request: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: request)
            let reply = try #require(MCPStdioServer.handle(data, dataRoot: root))
            return try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        }
        func errorCode(_ reply: [String: Any]) -> Int? {
            (reply["error"] as? [String: Any])?["code"] as? Int
        }
        #expect(try errorCode(response([
            "jsonrpc": "2.0", "id": ["bad": true], "method": "ping"
        ])) == -32600)
        #expect(try errorCode(response([
            "jsonrpc": "2.0", "id": true, "method": "ping"
        ])) == -32600)
        #expect(try errorCode(response([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": []
        ])) == -32602)
        #expect(try errorCode(response([
            "jsonrpc": "2.0", "id": 1, "method": "ping", "params": "bad"
        ])) == -32602)
        let malformed = try #require(MCPStdioServer.handle(Data("{".utf8), dataRoot: root))
        let parsed = try #require(JSONSerialization.jsonObject(with: malformed) as? [String: Any])
        #expect(errorCode(parsed) == -32700)
    }

    @Test func missingMetadataDoesNotMasqueradeAsAnEmptyWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = call("tools/call", params: ["name": "workspace_list_profiles"], root: root)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(!String(describing: result).contains(root.path))
    }

    @Test func framingLimitsEachRequestWithoutRejectingABatch() {
        let validLine = Data(repeating: 0x20, count: MCPStdioServer.maximumRequestBytes - 2)
            + Data("{}\n".utf8)
        var pending = Data()
        let first = MCPStdioServer.framedLines(pending: &pending, incoming: validLine)
        #expect(first?.count == 1)
        #expect(pending.isEmpty)
        let pair = MCPStdioServer.framedLines(
            pending: &pending, incoming: validLine + validLine
        )
        #expect(pair?.count == 2)
        #expect(pending.isEmpty)

        let tooLarge = Data(repeating: 0x20, count: MCPStdioServer.maximumRequestBytes + 1)
        #expect(MCPStdioServer.framedLines(
            pending: &pending, incoming: tooLarge
        ) == nil)
    }
}
