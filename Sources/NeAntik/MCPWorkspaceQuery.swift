import Foundation
import CoreFoundation
import CryptoKit

/// A metadata-only query. Private notes and proxy endpoints are not searchable:
/// even a match/no-match response must not reveal excluded fields.
struct MCPWorkspaceQuery: Sendable {
    static var properties: [String: Any] { [
        "text": ["type": "string", "maxLength": 256],
        "tags": ["type": "array", "maxItems": 8, "items": ["type": "string", "maxLength": 64]],
        "folderID": ["type": ["string", "null"]],
        "isPinned": ["type": "boolean"], "isArchived": ["type": "boolean"],
        "limit": ["type": "integer", "minimum": 1, "maximum": 100], "cursor": ["type": "string"]
    ] }
    let text: String
    let tags: [String]
    let folder: UUID??
    let pinned: Bool?
    let archived: Bool
    let limit: Int
    let suppliedCursor: String?
    private let filter: String

    init(arguments: [String: Any]) throws {
        func invalid() -> MCPProfileManagement.Failure { .invalid }
        guard Set(arguments.keys).isSubset(of: Set(Self.properties.keys)) else { throw invalid() }
        if let value = arguments["text"], !(value is String) { throw invalid() }
        text = ProfileTagID(rawValue: arguments["text"] as? String ?? "").rawValue
        guard text.count <= 256 else { throw invalid() }
        if let value = arguments["tags"], !(value is [String]) { throw invalid() }
        let requestedTags = arguments["tags"] as? [String] ?? []
        guard requestedTags.count <= 8, requestedTags.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else { throw invalid() }
        tags = Array(Set(requestedTags.map { ProfileTagID(rawValue: $0).rawValue })).sorted()
        if arguments["folderID"] == nil { folder = nil }
        else if arguments["folderID"] is NSNull { folder = .some(nil) }
        else if let value = arguments["folderID"] as? String, let id = UUID(uuidString: value) { folder = .some(id) }
        else { throw invalid() }
        func boolean(_ key: String) throws -> Bool? {
            guard let value = arguments[key] else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid() }
            return number.boolValue
        }
        pinned = try boolean("isPinned"); archived = try boolean("isArchived") ?? false
        if let value = arguments["limit"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue), (1...100).contains(number.intValue) else { throw invalid() }
            limit = number.intValue
        } else { limit = 50 }
        if let value = arguments["cursor"], !(value is String) { throw invalid() }
        suppliedCursor = arguments["cursor"] as? String
        let identity: [String: Any] = ["text": text, "tags": tags, "folder": folder.map { $0?.uuidString as Any? ?? NSNull() } ?? "all",
            "pinned": pinned as Any? ?? NSNull(), "archived": archived, "limit": limit]
        filter = Self.hash(try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
    }

    func cursor(snapshot: String, offset: Int) -> String { "\(snapshot):\(filter):\(offset)" }
    func offset(snapshot: String) throws -> Int {
        guard let suppliedCursor else { return 0 }
        let parts = suppliedCursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == snapshot, parts[1] == filter,
              let value = Int(parts[2]), value >= 0, String(value) == parts[2] else { throw MCPProfileManagement.Failure.cursor }
        return value
    }

    func page(profiles: [BrowserProfile], organization: ProfileOrganizationState) throws -> [String: Any] {
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Include both metadata revisions: moving/renaming a project invalidates
        // pagination just as a profile edit does. Hashes never expose private values.
        let snapshot = Self.hash(try encoder.encode(profiles) + encoder.encode(ProfileOrganizationDocument(state: organization)))
        let folderNames = Dictionary(uniqueKeysWithValues: organization.folders.map { ($0.id, ProfileTagID(rawValue: $0.name).rawValue) })
        let matches = profiles.filter { profile in
            guard profile.isArchived == archived, pinned == nil || profile.isPinned == pinned else { return false }
            let id = organization.folderID(forProfileID: profile.id)
            if let folder, folder != id { return false }
            let profileTags = Set(profile.tags.map { ProfileTagID(rawValue: $0).rawValue })
            guard tags.allSatisfy(profileTags.contains) else { return false }
            return text.isEmpty || ([ProfileTagID(rawValue: profile.name).rawValue] + Array(profileTags) + [id.flatMap { folderNames[$0] } ?? ""]).contains { $0.contains(text) }
        }
        let offset = try offset(snapshot: snapshot)
        guard offset <= matches.count else { throw MCPProfileManagement.Failure.cursor }
        var end = min(offset + limit, matches.count)
        while true {
            try Task.checkCancellation()
            let values: [[String: Any]] = matches[offset..<end].map { profile in [
                "id": profile.id.uuidString, "revision": String(profile.revision), "name": profile.name,
                "tags": profile.tags, "isPinned": profile.isPinned, "isArchived": profile.isArchived,
                "folderID": organization.folderID(forProfileID: profile.id)?.uuidString as Any? ?? NSNull(),
                "processState": "unverified"
            ] }
            let payload: [String: Any] = ["profiles": values, "count": values.count, "totalCount": matches.count,
                "organizationRevision": organization.mutationRevision?.uuidString as Any? ?? NSNull(),
                "nextCursor": end < matches.count ? cursor(snapshot: snapshot, offset: end) as Any : NSNull()]
            if try MCPStdioServer.toolResult(payload).count <= MCPStdioServer.maximumToolPayloadBytes { return payload }
            guard end - offset > 1 else { throw MCPProfileManagement.Failure.responseLimit }
            end = offset + (end - offset) / 2
        }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
