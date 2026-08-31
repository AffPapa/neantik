import Foundation

enum ProfileMetadataBatchAction: Equatable, Sendable {
    case setPinned(Bool)
    case setArchived(Bool)
    case addTag(String)
    case removeTag(String)
}

struct ProfileMetadataBatchUndoReceipt: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let previous: BrowserProfile
        let committedRevision: UInt64
    }

    let action: ProfileMetadataBatchAction
    let entries: [Entry]

    var affectedProfileIDs: Set<UUID> {
        Set(entries.map(\.previous.id))
    }

    var affectedCount: Int { entries.count }
    var canUndo: Bool { !entries.isEmpty }
}

struct ProfileFolderBatchUndoReceipt: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let profileID: UUID
        let previousFolderID: UUID?
        let committedFolderID: UUID?
    }

    let entries: [Entry]

    var affectedProfileIDs: Set<UUID> {
        Set(entries.map(\.profileID))
    }

    var affectedCount: Int { entries.count }
    var canUndo: Bool { !entries.isEmpty }
}

enum ProfileBatchMutationError: LocalizedError, Equatable {
    case emptySelection
    case invalidTag
    case tagLimitReached(profileName: String)
    case undoConflict

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Сначала выбери хотя бы один профиль."
        case .invalidTag:
            "Проверь тег: до \(BrowserProfile.maximumTagLength) символов без переносов строк."
        case let .tagLimitReached(profileName):
            "В профиле «\(profileName)» уже максимум тегов. Ничего не изменено."
        case .undoConflict:
            "Не удалось отменить действие: один из профилей уже изменился. Новые данные не перезаписаны."
        }
    }
}

@MainActor
extension ProfileStore {
    func assignProfiles(
        _ requestedProfileIDs: [UUID],
        toFolderID folderID: UUID?
    ) throws {
        _ = try assignProfilesRecordingUndo(
            Set(requestedProfileIDs),
            toFolderID: folderID
        )
    }

    @discardableResult
    func assignProfilesRecordingUndo(
        _ profileIDs: Set<UUID>,
        toFolderID folderID: UUID?
    ) throws -> ProfileFolderBatchUndoReceipt {
        guard !profileIDs.isEmpty else {
            throw ProfileBatchMutationError.emptySelection
        }
        return try mutateOrganization { state in
            let knownProfileIDs = Set(profiles.map(\.id))
            guard profileIDs.isSubset(of: knownProfileIDs) else {
                throw ProfileOrganizationError.profileNotFound
            }
            if let folderID,
               state.folder(withID: folderID) == nil {
                throw ProfileOrganizationError.folderNotFound
            }
            let entries = profileIDs.sorted {
                $0.uuidString < $1.uuidString
            }.compactMap { profileID -> ProfileFolderBatchUndoReceipt.Entry? in
                let previousFolderID = state.folderID(
                    forProfileID: profileID
                )
                guard previousFolderID != folderID else { return nil }
                return .init(
                    profileID: profileID,
                    previousFolderID: previousFolderID,
                    committedFolderID: folderID
                )
            }
            state.assign(profileIDs: profileIDs, toFolderID: folderID)
            return ProfileFolderBatchUndoReceipt(entries: entries)
        }
    }

    func undoFolderAssignments(
        _ receipt: ProfileFolderBatchUndoReceipt
    ) throws {
        guard receipt.canUndo else { return }
        try mutateOrganization { state in
            let knownProfileIDs = Set(profiles.map(\.id))
            guard receipt.affectedProfileIDs.isSubset(of: knownProfileIDs),
                  receipt.entries.allSatisfy({
                      state.folderID(forProfileID: $0.profileID) ==
                          $0.committedFolderID
                  })
            else {
                throw ProfileBatchMutationError.undoConflict
            }
            for entry in receipt.entries {
                if let previousFolderID = entry.previousFolderID,
                   state.folder(withID: previousFolderID) == nil {
                    throw ProfileBatchMutationError.undoConflict
                }
            }
            for entry in receipt.entries {
                state.assign(
                    profileIDs: [entry.profileID],
                    toFolderID: entry.previousFolderID
                )
            }
        }
    }

    @discardableResult
    func applyBatch(
        _ action: ProfileMetadataBatchAction,
        to requestedProfileIDs: Set<UUID>,
        at date: Date = Date()
    ) throws -> ProfileMetadataBatchUndoReceipt {
        guard !requestedProfileIDs.isEmpty else {
            throw ProfileBatchMutationError.emptySelection
        }
        let normalizedTag: String?
        switch action {
        case let .addTag(tag), let .removeTag(tag):
            guard let value = BrowserProfile.normalizedTags([tag])?.first else {
                throw ProfileBatchMutationError.invalidTag
            }
            normalizedTag = value
        case .setPinned, .setArchived:
            normalizedTag = nil
        }

        return try mutateProfilesAtomically { profiles in
            let knownProfileIDs = Set(profiles.map(\.id))
            guard requestedProfileIDs.isSubset(of: knownProfileIDs) else {
                throw BrowserProfileDeletedError()
            }
            var entries: [ProfileMetadataBatchUndoReceipt.Entry] = []
            for profileID in requestedProfileIDs.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                guard let index = profiles.firstIndex(where: {
                    $0.id == profileID
                }) else {
                    throw BrowserProfileDeletedError()
                }
                let previous = profiles[index]
                var next = previous
                switch action {
                case let .setPinned(value):
                    next.isPinned = value
                case let .setArchived(value):
                    next.isArchived = value
                case .addTag:
                    guard let normalizedTag else {
                        throw ProfileBatchMutationError.invalidTag
                    }
                    let tagID = ProfileTagID(displayName: normalizedTag)
                    if !next.tags.contains(where: {
                        ProfileTagID(displayName: $0) == tagID
                    }) {
                        guard next.tags.count < BrowserProfile.maximumTagCount else {
                            throw ProfileBatchMutationError.tagLimitReached(
                                profileName: previous.name
                            )
                        }
                        next.tags.append(normalizedTag)
                    }
                case .removeTag:
                    guard let normalizedTag else {
                        throw ProfileBatchMutationError.invalidTag
                    }
                    let tagID = ProfileTagID(displayName: normalizedTag)
                    next.tags.removeAll {
                        ProfileTagID(displayName: $0) == tagID
                    }
                }
                guard next != previous else { continue }
                guard let normalized = next.normalizedForPersistence() else {
                    throw NeAntikError.invalidProfile
                }
                next = normalized
                next.updatedAt = date
                next.revision = try Self.nextRevision(after: previous.revision)
                profiles[index] = next
                entries.append(
                    .init(
                        previous: previous,
                        committedRevision: next.revision
                    )
                )
            }
            return ProfileMetadataBatchUndoReceipt(
                action: action,
                entries: entries
            )
        }
    }

    func undoBatch(
        _ receipt: ProfileMetadataBatchUndoReceipt,
        at date: Date = Date()
    ) throws {
        guard receipt.canUndo else { return }
        try mutateProfilesAtomically { profiles in
            let currentByID = Dictionary(
                uniqueKeysWithValues: profiles.map { ($0.id, $0) }
            )
            guard receipt.entries.allSatisfy({ entry in
                currentByID[entry.previous.id]?.revision ==
                    entry.committedRevision
            }) else {
                throw ProfileBatchMutationError.undoConflict
            }
            for entry in receipt.entries {
                guard let index = profiles.firstIndex(where: {
                    $0.id == entry.previous.id
                }) else {
                    throw ProfileBatchMutationError.undoConflict
                }
                var restored = entry.previous
                restored.updatedAt = date
                restored.revision = try Self.nextRevision(
                    after: entry.committedRevision
                )
                guard let normalized = restored.normalizedForPersistence() else {
                    throw NeAntikError.invalidProfile
                }
                profiles[index] = normalized
            }
        }
    }
}
