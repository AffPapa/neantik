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
}
