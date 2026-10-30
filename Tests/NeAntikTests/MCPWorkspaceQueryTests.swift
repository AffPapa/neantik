import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct MCPWorkspaceQueryTests {
    @Test func filtersUseOnlyPublicMetadataAndCursorBindsBothSnapshotAndFilter() throws {
        let folder = ProfileFolder(name: "Café Project")
        var a = BrowserProfile(name: "Same"); a.tags = ["QA", "ready"]; a.isPinned = true
        var b = BrowserProfile(name: "Same"); b.tags = ["qa"]; b.note = "private-marker";
        var c = BrowserProfile(name: "Archived"); c.isArchived = true
        let organization = ProfileOrganizationState(folders: [folder], assignmentsByProfileID: [a.id: folder.id], mutationRevision: UUID())
        let profiles = [a,b,c]
        let query = try MCPWorkspaceQuery(arguments: ["text": "cafe", "tags": ["qa", "READY"], "isPinned": true])
        let page = try query.page(profiles: profiles, organization: organization)
        #expect(page["totalCount"] as? Int == 1)
        let match = try #require((page["profiles"] as? [[String: Any]])?.first)
        #expect(match["id"] as? String == a.id.uuidString); #expect(match["revision"] is String)
        #expect(try MCPWorkspaceQuery(arguments: ["text": "private-marker"]).page(profiles: profiles, organization: organization)["count"] as? Int == 0)
        #expect(try MCPWorkspaceQuery(arguments: ["folderID": NSNull()]).page(profiles: profiles, organization: organization)["count"] as? Int == 1)
        #expect(try MCPWorkspaceQuery(arguments: ["isArchived": true]).page(profiles: profiles, organization: organization)["count"] as? Int == 1)
        let first = try MCPWorkspaceQuery(arguments: ["limit": 1]).page(profiles: profiles, organization: organization)
        let cursor = try #require(first["nextCursor"] as? String)
        let next = try MCPWorkspaceQuery(arguments: ["limit": 1, "cursor": cursor]).page(profiles: profiles, organization: organization)
        #expect((next["profiles"] as? [[String: Any]])?.first?["id"] as? String == b.id.uuidString)
        #expect(next["nextCursor"] is NSNull)
        #expect(throws: MCPProfileManagement.Failure.self) { try MCPWorkspaceQuery(arguments: ["limit": 1, "isPinned": true, "cursor": cursor]).page(profiles: profiles, organization: organization) }
        var changed = organization; changed.mutationRevision = UUID()
        #expect(throws: MCPProfileManagement.Failure.self) { try MCPWorkspaceQuery(arguments: ["limit": 1, "cursor": cursor]).page(profiles: profiles, organization: changed) }
        for args: [String: Any] in [["isPinned": 1], ["isArchived": "true"], ["limit": true], ["limit": 0], ["folderID": "bad"], ["tags": [1]], ["unknown": true]] {
            #expect(throws: MCPProfileManagement.Failure.self) { try MCPWorkspaceQuery(arguments: args) }
        }
    }
    @Test func largeFolderCatalogHasBoundedPagesAndCompactCommittedMutationReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-folders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MCPProfileManagement(root: root, allowsManagement: true)
        _ = try await engine.call("profile_create", ["name": "Fixture"])
        let folders = (0..<1500).map { ProfileFolder(name: String(format: "Folder %04d ", $0) + String(repeating: "x", count: 48)) }
        let document = ProfileOrganizationDocument(folders: folders, mutationRevision: UUID())
        let paths = AppPaths(rootDirectory: root)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: paths.profileOrganizationFile, options: .atomic)
        var args: [String: Any] = ["limit": 100]; var ids = Set<String>(); var last: [String: Any] = [:]
        repeat {
            last = try await engine.call("folder_list", args)
            #expect(try MCPStdioServer.toolResult(last).count <= MCPStdioServer.maximumToolPayloadBytes)
            for folder in last["folders"] as! [[String: Any]] { #expect(ids.insert(folder["id"] as! String).inserted) }
            if let cursor = last["nextCursor"] as? String { args["cursor"] = cursor } else { break }
        } while true
        #expect(ids.count == 1500)
        let receipt = try await engine.call("folder_create", ["name": "After large catalog", "expectedOrganizationRevision": last["organizationRevision"]!])
        #expect((receipt["folders"] as? [[String: Any]])?.count == 1)
        #expect(receipt["affectedFolderID"] is String)
        #expect(try MCPStdioServer.toolResult(receipt).count < 2048)
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("folder_list", args) }
        #expect(engine.store.organization.folders.count == 1501)
    }
    @Test func querySupports5000MetadataRecordsWithoutStartingBrowsers() throws {
        var profiles = (0..<5000).map { BrowserProfile(name: "Synthetic \($0)") }
        for i in profiles.indices { profiles[i].tags = ["qa"] }
        let page = try MCPWorkspaceQuery(arguments: ["tags": ["qa"], "limit": 100]).page(profiles: profiles, organization: .empty)
        #expect(page["totalCount"] as? Int == 5000)
        #expect(page["count"] as? Int == 100)
        #expect(try MCPStdioServer.toolResult(page).count <= MCPStdioServer.maximumToolPayloadBytes)
    }
}
