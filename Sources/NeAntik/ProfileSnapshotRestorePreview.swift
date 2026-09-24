import Foundation

struct ProfileSnapshotRestorePreview: Equatable, Sendable {
    let snapshotDate: Date
    let profileCount: Int
    let folderCount: Int
    let reusedFolderCount: Int
    let newFolderCount: Int

    init(
        payload: ProfileSnapshotRestorePayload,
        existingFolderNames: [String]
    ) {
        snapshotDate = payload.createdAt
        profileCount = payload.profiles.count

        let incomingKeys = Set(payload.folderNames.compactMap { name in
            name.flatMap(ProfileFolder.normalizedName)
                .map(ProfileFolder.comparisonKey)
        })
        let existingKeys = Set(existingFolderNames.map(ProfileFolder.comparisonKey))
        folderCount = incomingKeys.count
        reusedFolderCount = incomingKeys.intersection(existingKeys).count
        newFolderCount = incomingKeys.subtracting(existingKeys).count
    }
}
