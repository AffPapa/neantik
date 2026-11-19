import Foundation

struct ProfileSnapshotRestorePayload: Sendable {
    let profiles: [BrowserProfile]
    let folderNames: [String?]
    let folderPaths: [[String]?]
    let createdAt: Date

    init(
        profiles: [BrowserProfile],
        folderNames: [String?],
        folderPaths: [[String]?]? = nil,
        createdAt: Date
    ) {
        self.profiles = profiles
        self.folderNames = folderNames
        self.folderPaths = folderPaths ?? folderNames.map { $0.map { [$0] } }
        self.createdAt = createdAt
    }
}

/// Snapshot operations are bounded local metadata, but serializing, reading,
/// and reconstructing a large workspace still must not run on the main actor.
enum ProfileSnapshotFileService {
    static func save(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String],
        folderPathByProfileID: [UUID: [String]] = [:],
        paths: AppPaths
    ) async throws -> URL {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try ProfileSnapshotStore.save(
                profiles: profiles,
                folderNameByProfileID: folderNameByProfileID,
                folderPathByProfileID: folderPathByProfileID,
                paths: paths
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func prepareRestore(
        from url: URL,
        paths: AppPaths,
        now: Date = Date()
    ) async throws -> ProfileSnapshotRestorePayload {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let document = try ProfileSnapshotStore.document(
                from: url,
                paths: paths
            )
            try Task.checkCancellation()
            let profiles = try document.makeProfiles(now: now)
            try Task.checkCancellation()
            return ProfileSnapshotRestorePayload(
                profiles: profiles,
                folderNames: document.configuration.profiles.map(\.folderName),
                folderPaths: document.configuration.profiles.indices.map {
                    document.configuration.folderPath(at: $0)
                },
                createdAt: document.createdAt
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
