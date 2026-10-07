import Foundation
import Testing
@testable import NeAntik

struct HelpContentTests {
    @Test func searchFindsTasksInsideArticles() {
        #expect(HelpTopic.matching("429").contains(.proxy))
        #expect(HelpTopic.matching("СНИМОК").contains(.storage))
        #expect(HelpTopic.matching("nextCursor").contains(.mcp))
        #expect(HelpTopic.matching("  ") == HelpTopic.allCases)
        #expect(HelpTopic.matching("nonexistent-synthetic-term").isEmpty)
    }

    @Test func copiedConfigurationUsesExactResolvedWorkspaceAndEscapesClientFormats() throws {
        let executable = URL(fileURLWithPath: "/private/tmp/NeAntik \"QA\".app/Contents/MacOS/NeAntik")
        let root = URL(fileURLWithPath: "/private/tmp/neantik-legacy \"root\"", isDirectory: true)
        let configuration = MCPConnectionConfiguration(executable: executable, dataRoot: root)
        let json = try #require(JSONSerialization.jsonObject(with: Data(configuration.claudeJSON.utf8)) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: Any])
        let server = try #require(servers["neantik"] as? [String: Any])
        let command = try #require(server["command"] as? String)
        let args = try #require(server["args"] as? [String])
        #expect(command == executable.path)
        #expect(NeAntikLaunchIntent.parse(arguments: [command] + args).mode == .mcpStdio(dataRoot: root))
        #expect(configuration.codexTOML.contains("\\\"QA\\\""))
        #expect(configuration.codexTOML.contains("\\\"root\\\""))
        #expect(!configuration.codexTOML.contains("password"))
    }
}
