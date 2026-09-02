import Combine
import Darwin
import Foundation

protocol ProfileCredentialCleanupRecoveryProviding: Error {
    var profileIDsRequiringCredentialCleanup: [UUID] { get }
}

@MainActor
final class ProfileStore: ObservableObject {
    /// 128 MiB keeps a wide safety margin for the supported 10,000 ordinary
    /// bounded profiles while preventing a corrupt metadata file from forcing
    /// a half-gigabyte allocation on the main actor during startup.
    static let maximumProfilesMetadataBytes =
        ProfilesMetadataStorage.maximumBytes
    private static let maximumOrganizationMetadataBytes = 64 * 1_024 * 1_024

    @Published private(set) var profiles: [BrowserProfile] = [] {
        didSet { profileListRevision &+= 1 }
    }
    @Published private(set) var organization = ProfileOrganizationState.empty {
        didSet { profileListRevision &+= 1 }
    }
    @Published var lastError: String?

    /// Monotonic cache key for derived profile-list indexes.
    ///
    /// This avoids comparing complete profile and organization payloads on
    /// every SwiftUI computed-property access. The published properties still
    /// drive rendering; this key only proves whether a cached index is current.
    private(set) var profileListRevision: UInt64 = 0

    let paths: AppPaths
    private var storageIsAvailable = true
    private var organizationStorageIsAvailable = true
    private let trashDirectory: (URL) throws -> URL
    private let restoreTrashedDirectory: (URL, URL) throws -> Void
    private let beforeDeleteMetadataPersist: () throws -> Void
    private let afterDeleteMetadataPersist: () throws -> Void
    private let beforeOrganizationPersist: () throws -> Void

    init(
        paths: AppPaths = AppPaths(),
        trashDirectory: ((URL) throws -> URL)? = nil,
        restoreTrashedDirectory: ((URL, URL) throws -> Void)? = nil,
        beforeDeleteMetadataPersist: @escaping () throws -> Void = {},
        afterDeleteMetadataPersist: @escaping () throws -> Void = {},
        beforeOrganizationPersist: @escaping () throws -> Void = {}
    ) {
        self.paths = paths
        self.trashDirectory =
            trashDirectory ?? Self.moveDirectoryToTrash
        self.restoreTrashedDirectory =
            restoreTrashedDirectory ?? Self.restoreDirectoryFromTrash
        self.beforeDeleteMetadataPersist = beforeDeleteMetadataPersist
        self.afterDeleteMetadataPersist = afterDeleteMetadataPersist
        self.beforeOrganizationPersist = beforeOrganizationPersist
        do {
            try paths.prepareBaseDirectories()
            try? ProfileRecoveryRetention.prune(
                directory: paths.profilesRecoveryDirectory
            )
            try paths.withProfilesMetadataGuard {
                try paths.validatePrivateFile(paths.profilesFile)
                let load = try ProfilesMetadataStorage.readWithRecovery(
                    paths: paths
                )
                let normalized = try Self.normalizedForIsolation(
                    load.profiles
                )
                profiles = normalized.profiles
                if FileManager.default.fileExists(
                    atPath: paths.profilesFile.path
                ) {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: paths.profilesFile.path
                    )
                }
                if normalized.changed || load.requiresMigration {
                    sortProfiles()
                    try persist()
                } else {
                    try ensureRecoverySnapshotIfNeeded()
                }
                lastError = load.warning ?? paths.migrationWarning

                do {
                    let organizationLoad = try Self
                        .readOrganizationWithRecovery(
                            paths: paths,
                            knownProfileIDs: Set(profiles.map(\.id))
                        )
                    organization = organizationLoad.state
                    if FileManager.default.fileExists(
                        atPath: paths.profileOrganizationFile.path
                    ) {
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath:
                                paths.profileOrganizationFile.path
                        )
                    }
                    if organizationLoad.changed {
                        try persistOrganization()
                    } else {
                        try ensureOrganizationRecoverySnapshotIfNeeded()
                    }
                    lastError = Self.joinWarnings(
                        lastError,
                        organizationLoad.warning
                    )
                } catch {
                    organizationStorageIsAvailable = false
                    organization = .empty
                    lastError = Self.joinWarnings(
                        lastError,
                        "Папки временно недоступны. Профили и данные браузеров не изменены. \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            storageIsAvailable = false
            lastError = error.localizedDescription
        }
    }

    var hasTrustedMetadata: Bool {
        storageIsAvailable
    }

    var hasTrustedOrganization: Bool {
        organizationStorageIsAvailable
    }

    func profile(withID id: UUID?) -> BrowserProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func folder(withID id: UUID?) -> ProfileFolder? {
        organization.folder(withID: id)
    }

    func folderID(forProfileID profileID: UUID) -> UUID? {
        organization.folderID(forProfileID: profileID)
    }

    @discardableResult
    func createFolder(
        named requestedName: String,
        at date: Date = Date()
    ) throws -> ProfileFolder {
        guard let name = ProfileFolder.normalizedName(requestedName) else {
            throw ProfileOrganizationError.invalidFolderName
        }
        return try mutateOrganization { state in
            let key = ProfileFolder.comparisonKey(name)
            guard !state.folders.contains(where: {
                ProfileFolder.comparisonKey($0.name) == key
            }) else {
                throw ProfileOrganizationError.duplicateFolderName
            }
            var id = UUID()
            while state.folder(withID: id) != nil {
                id = UUID()
            }
            let folder = ProfileFolder(
                id: id,
                name: name,
                createdAt: date,
                updatedAt: date
            )
            state.addFolder(folder)
            return folder
        }
    }

    @discardableResult
    func renameFolder(
        withID folderID: UUID,
        to requestedName: String,
        at date: Date = Date()
    ) throws -> ProfileFolder {
        guard let name = ProfileFolder.normalizedName(requestedName) else {
            throw ProfileOrganizationError.invalidFolderName
        }
        return try mutateOrganization { state in
            guard var folder = state.folder(withID: folderID) else {
                throw ProfileOrganizationError.folderNotFound
            }
            let key = ProfileFolder.comparisonKey(name)
            guard !state.folders.contains(where: {
                $0.id != folderID &&
                    ProfileFolder.comparisonKey($0.name) == key
            }) else {
                throw ProfileOrganizationError.duplicateFolderName
            }
            guard folder.name != name else { return folder }
            folder.name = name
            folder.updatedAt = date
            state.replaceFolder(folder)
            return folder
        }
    }

    @discardableResult
    func deleteFolder(withID folderID: UUID) throws -> [UUID] {
        try mutateOrganization { state in
            guard state.folder(withID: folderID) != nil else {
                throw ProfileOrganizationError.folderNotFound
            }
            return state.removeFolder(withID: folderID)
        }
    }

    func assignProfile(
        _ profileID: UUID,
        toFolderID folderID: UUID?
    ) throws {
        try assignProfiles([profileID], toFolderID: folderID)
    }


    func validateInsertionCapacity(
        forAdditionalProfileCount additionalCount: Int
    ) throws {
        guard additionalCount > 0 else {
            throw NeAntikError.invalidProfile
        }
        try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            try requireStorage()
            try Self.requireInsertionCapacity(
                existingCount: profiles.count,
                additionalCount: additionalCount
            )
        }
    }

    @discardableResult
    func upsert(_ profile: BrowserProfile) throws -> BrowserProfile {
        try upsert(profile, afterPersist: { _ in })
    }

    @discardableResult
    func upsert(
        _ profile: BrowserProfile,
        afterPersist: (BrowserProfile) throws -> Void
    ) throws -> BrowserProfile {
        try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            return try upsertAfterMetadataReload(
                profile,
                afterPersist: afterPersist
            )
        }
    }

    /// Applies a narrow mutation to the latest persisted profile revision.
    ///
    /// UI actions such as pin/archive must use this instead of rebuilding a
    /// whole profile from a value captured before another window's edit.
    @discardableResult
    func mutateProfile(
        withID profileID: UUID,
        _ mutation: (inout BrowserProfile) throws -> Void
    ) throws -> BrowserProfile {
        try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            guard var current = profiles.first(where: { $0.id == profileID })
            else {
                throw BrowserProfileDeletedError()
            }
            let expectedRevision = current.revision
            try mutation(&current)
            guard current.id == profileID,
                  current.revision == expectedRevision
            else {
                throw NeAntikError.invalidProfile
            }
            return try upsertAfterMetadataReload(
                current,
                afterPersist: { _ in }
            )
        }
    }

    func mutateProfilesAtomically<Result>(
        _ mutation: (inout [BrowserProfile]) throws -> Result
    ) throws -> Result {
        try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            try requireStorage()
            let previousProfiles = profiles
            var nextProfiles = previousProfiles
            let result = try mutation(&nextProfiles)
            guard nextProfiles != previousProfiles else { return result }
            profiles = nextProfiles
            sortProfiles()
            do {
                try persist()
            } catch {
                profiles = previousProfiles
                throw error
            }
            return result
        }
    }

    /// Commits profile metadata, its folder assignment and a dependent
    /// credential mutation as one recoverable operation.
    ///
    /// A folder conflict is validated before profile metadata is written. If
    /// folder persistence or `afterPersist` fails, both metadata documents are
    /// restored and a newly created profile directory is removed.
    @discardableResult
    func upsert(
        _ profile: BrowserProfile,
        toFolderID folderID: UUID?,
        afterPersist: (BrowserProfile) throws -> Void = { _ in }
    ) throws -> BrowserProfile {
        try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            try requireOrganizationStorage()
            do {
                try reloadLatestOrganizationForMutation()
            } catch {
                organizationStorageIsAvailable = false
                organization = .empty
                lastError = Self.joinWarnings(
                    lastError,
                    "Папки временно недоступны. Профили и данные браузеров не изменены. \(error.localizedDescription)"
                )
                throw ProfileOrganizationError.storageUnavailable
            }
            if let folderID,
               organization.folder(withID: folderID) == nil {
                throw ProfileOrganizationError.folderNotFound
            }

            let previousProfiles = profiles
            let previousOrganization = organization
            let profileDirectory = paths.profileDirectory(for: profile.id)
            let profileDirectoryExisted = FileManager.default.fileExists(
                atPath: profileDirectory.path
            )
            let saved = try upsertAfterMetadataReload(
                profile,
                afterPersist: { _ in }
            )
            let committedProfiles = profiles
            var committedOrganization = previousOrganization

            do {
                var nextOrganization = previousOrganization
                nextOrganization.assign(
                    profileIDs: [saved.id],
                    toFolderID: folderID
                )
                if nextOrganization != previousOrganization {
                    organization = nextOrganization
                    try persistOrganization()
                    committedOrganization = nextOrganization
                }
                try afterPersist(saved)
            } catch {
                let operationError = error
                let createdDirectories = profileDirectoryExisted
                    ? []
                    : [profileDirectory]
                do {
                    try rollbackCompoundMutation(
                        previousProfiles: previousProfiles,
                        committedProfiles: committedProfiles,
                        previousOrganization: previousOrganization,
                        committedOrganization: committedOrganization,
                        createdDirectories: createdDirectories,
                        credentialCleanupRecovery: operationError as?
                            any ProfileCredentialCleanupRecoveryProviding
                    )
                } catch {
                    throw ProfileSaveRollbackError(
                        operationError: operationError,
                        rollbackError: error
                    )
                }
                throw operationError
            }
            return saved
        }
    }

    @discardableResult
    func insertNewProfiles(
        _ requestedProfiles: [BrowserProfile],
        afterPersist: ([BrowserProfile]) throws -> Void
    ) throws -> [BrowserProfile] {
        try insertNewProfiles(
            requestedProfiles,
            targetFolderID: nil,
            afterPersist: afterPersist
        )
    }

    @discardableResult
    func insertNewProfiles(
        _ requestedProfiles: [BrowserProfile],
        toFolderID folderID: UUID,
        afterPersist: ([BrowserProfile]) throws -> Void
    ) throws -> [BrowserProfile] {
        try insertNewProfiles(
            requestedProfiles,
            targetFolderID: folderID,
            afterPersist: afterPersist
        )
    }

    private func insertNewProfiles(
        _ requestedProfiles: [BrowserProfile],
        targetFolderID: UUID?,
        afterPersist: ([BrowserProfile]) throws -> Void
    ) throws -> [BrowserProfile] {
        try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            try requireStorage()
            var previousOrganization: ProfileOrganizationState?
            if let targetFolderID {
                try requireOrganizationStorage()
                do {
                    try reloadLatestOrganizationForMutation()
                } catch {
                    organizationStorageIsAvailable = false
                    organization = .empty
                    lastError = Self.joinWarnings(
                        lastError,
                        "Папки временно недоступны. Профили и данные браузеров не изменены. \(error.localizedDescription)"
                    )
                    throw ProfileOrganizationError.storageUnavailable
                }
                guard organization.folder(withID: targetFolderID) != nil else {
                    throw ProfileOrganizationError.folderNotFound
                }
                previousOrganization = organization
            }
            guard !requestedProfiles.isEmpty else {
                throw NeAntikError.invalidProfile
            }

            let previousProfiles = profiles
            try Self.requireInsertionCapacity(
                existingCount: previousProfiles.count,
                additionalCount: requestedProfiles.count
            )
            let existingIDs = Set(previousProfiles.map(\.id))
            var requestedIDs = Set<UUID>()
            var prepared = requestedProfiles
            for index in prepared.indices {
                guard let normalizedProfile = prepared[index]
                    .normalizedForPersistence(),
                      !existingIDs.contains(prepared[index].id),
                      requestedIDs.insert(prepared[index].id).inserted,
                      prepared[index].revision == 0,
                      try paths.privateFileEntryKind(
                          paths.profileDeletionTombstone(
                              for: prepared[index].id
                          )
                      ) == .missing
                else {
                    throw NeAntikError.invalidProfile
                }
                prepared[index] = normalizedProfile
                prepared[index].updatedAt = Date()
                prepared[index].revision = 1
            }

            let normalized = try Self.normalizedForIsolation(
                previousProfiles + prepared
            ).profiles
            let inserted = Array(normalized.suffix(prepared.count))
            var createdDirectories: [URL] = []
            do {
                for profile in inserted {
                    let directory = paths.profileDirectory(for: profile.id)
                    guard !FileManager.default.fileExists(
                        atPath: directory.path
                    ) else {
                        throw NeAntikError.invalidProfile
                    }
                    try paths.prepareProfileDirectories(for: profile.id)
                    createdDirectories.append(directory)
                }

                profiles = normalized
                sortProfiles()
                try persist()
            } catch {
                profiles = previousProfiles
                for directory in createdDirectories.reversed() {
                    try? FileManager.default.removeItem(at: directory)
                }
                throw error
            }

            let persistedProfiles = profiles
            var committedOrganization = previousOrganization
            do {
                if let targetFolderID,
                   let previousOrganization {
                    var nextOrganization = previousOrganization
                    nextOrganization.assign(
                        profileIDs: Set(inserted.map(\.id)),
                        toFolderID: targetFolderID
                    )
                    if nextOrganization != previousOrganization {
                        organization = nextOrganization
                        try persistOrganization()
                        committedOrganization = nextOrganization
                    }
                }
                try afterPersist(inserted)
            } catch {
                let operationError = error
                if let previousOrganization {
                    do {
                        try rollbackCompoundMutation(
                            previousProfiles: previousProfiles,
                            committedProfiles: persistedProfiles,
                            previousOrganization: previousOrganization,
                            committedOrganization:
                                committedOrganization ?? previousOrganization,
                            createdDirectories: createdDirectories,
                            credentialCleanupRecovery: operationError as?
                                any ProfileCredentialCleanupRecoveryProviding
                        )
                    } catch {
                        throw ProfileSaveRollbackError(
                            operationError: operationError,
                            rollbackError: error
                        )
                    }
                    throw operationError
                }
                profiles = previousProfiles
                do {
                    try persist(synchronizeRecoverySnapshot: true)
                } catch {
                    profiles = persistedProfiles
                    throw ProfileSaveRollbackError(
                        operationError: operationError,
                        rollbackError: error
                    )
                }
                do {
                    try removeNewProfileDirectories(createdDirectories)
                    if let recovery = operationError as?
                        any ProfileCredentialCleanupRecoveryProviding
                    {
                        try authorizeCredentialCleanup(
                            for: recovery
                                .profileIDsRequiringCredentialCleanup
                        )
                    }
                } catch {
                    throw ProfileSaveRollbackError(
                        operationError: operationError,
                        rollbackError: error
                    )
                }
                throw operationError
            }
            return inserted
        }
    }

    private func upsertAfterMetadataReload(
        _ profile: BrowserProfile,
        afterPersist: (BrowserProfile) throws -> Void
    ) throws -> BrowserProfile {
        try requireStorage()
        switch try paths.privateFileEntryKind(
            paths.profileDeletionTombstone(for: profile.id)
        ) {
        case .regular, .unsafe:
            throw BrowserProfileDeletedError()
        case .missing:
            break
        }
        let previousProfiles = profiles
        guard var value = profile.normalizedForPersistence() else {
            throw NeAntikError.invalidProfile
        }
        let current = profiles.first(where: { $0.id == value.id })
        if let current {
            guard value.revision == current.revision else {
                throw BrowserProfileRevisionConflictError(
                    profileID: value.id
                )
            }
            value.revision = try Self.nextRevision(after: current.revision)
        } else {
            try Self.requireInsertionCapacity(
                existingCount: profiles.count,
                additionalCount: 1
            )
            guard value.revision == 0 else {
                throw BrowserProfileRevisionConflictError(
                    profileID: value.id
                )
            }
            value.revision = 1
        }
        value.updatedAt = Date()
        let usedSeeds = Set(
            profiles
                .filter { $0.id != value.id }
                .map { $0.identity.runtimeSeed }
        )
        let requestedSeed = value.identity.runtimeSeed
        if requestedSeed != value.identity.seed ||
            usedSeeds.contains(requestedSeed) {
            let replacementSeed = try usedSeeds.contains(requestedSeed)
                ? Self.nextAvailableSeed(
                        after: requestedSeed,
                        excluding: usedSeeds
                    )
                : requestedSeed
            guard let replacementIdentity =
                value.identity.replacingSeed(replacementSeed)
            else {
                throw BrowserIdentityAllocationError()
            }
            value.identity = replacementIdentity
        }
        let profileDirectory = paths.profileDirectory(for: value.id)
        let profileDirectoryExisted = FileManager.default.fileExists(
            atPath: profileDirectory.path
        )
        do {
            try paths.prepareProfileDirectories(for: value.id)
        } catch {
            if !profileDirectoryExisted {
                try? FileManager.default.removeItem(at: profileDirectory)
            }
            throw error
        }

        if let index = profiles.firstIndex(where: { $0.id == value.id }) {
            profiles[index] = value
        } else {
            profiles.append(value)
        }
        sortProfiles()
        do {
            try persist()
        } catch {
            profiles = previousProfiles
            if !profileDirectoryExisted {
                try? FileManager.default.removeItem(at: profileDirectory)
            }
            throw error
        }
        let persistedProfiles = profiles
        do {
            try afterPersist(value)
        } catch {
            let operationError = error
            profiles = previousProfiles
            do {
                try persist(synchronizeRecoverySnapshot: true)
            } catch {
                // The first persist succeeded, so its state is the last
                // metadata known to be durable if the rollback cannot commit.
                profiles = persistedProfiles
                throw ProfileSaveRollbackError(
                    operationError: operationError,
                    rollbackError: error
                )
            }
            if !profileDirectoryExisted {
                try? FileManager.default.removeItem(at: profileDirectory)
            }
            throw operationError
        }
        return value
    }

    @discardableResult
    func markLaunched(_ id: UUID) -> Bool {
        guard storageIsAvailable else {
            lastError = ProfileStorageUnavailableError().localizedDescription
            return false
        }
        do {
            return try paths.withProfilesMetadataGuard {
                try reloadLatestProfilesForMutation()
                guard try paths.privateFileEntryKind(
                    paths.profileDeletionTombstone(for: id)
                ) == .missing,
                    let index = profiles.firstIndex(
                        where: { $0.id == id }
                    )
                else {
                    return false
                }
                let previousProfiles = profiles
                profiles[index].lastLaunchedAt = Date()
                profiles[index].revision = try Self.nextRevision(
                    after: profiles[index].revision
                )
                do {
                    try persist()
                } catch {
                    profiles = previousProfiles
                    throw error
                }
                return true
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func delete(
        _ profile: BrowserProfile,
        processManager: BrowserProcessManager,
        credentialCleanup: (BrowserProfile) throws -> Void
    ) throws -> ProfileDeletionOutcome {
        try processManager.withVerifiedProfileDeletion(
            profileID: profile.id
        ) {
            try deleteAfterVerifiedPreflight(profile)
        }
        pruneOrganizationAfterProfileDeletion()
        do {
            try credentialCleanup(profile)
            try paths.removeCredentialCleanupMarker(for: profile.id)
            return .complete
        } catch {
            return .credentialCleanupPending
        }
    }

    private func pruneOrganizationAfterProfileDeletion() {
        guard organizationStorageIsAvailable else { return }
        do {
            // Reloading against the already-committed profiles revision drops
            // orphan assignments and persists the normalized sidecar. Folder
            // failure must never resurrect or block a deleted profile.
            try mutateOrganization { _ in () }
        } catch {
            lastError = Self.joinWarnings(
                lastError,
                "Профиль удалён, но список папок будет очищен при следующем безопасном чтении. \(error.localizedDescription)"
            )
        }
    }

    private func deleteAfterVerifiedPreflight(
        _ profile: BrowserProfile
    ) throws {
        try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            try deleteAfterMetadataReload(profile)
        }
    }

    private func deleteAfterMetadataReload(
        _ profile: BrowserProfile
    ) throws {
        try requireStorage()
        guard profiles.contains(where: { $0.id == profile.id }) else {
            throw BrowserProfileDeletedError()
        }
        let previousProfiles = profiles
        let directory = paths.profileDirectory(for: profile.id)
        let tombstone = paths.profileDeletionTombstone(for: profile.id)
        do {
            try paths.createPrivateFileExclusively(
                Data("deleted-v1".utf8),
                at: tombstone
            )
        } catch where Self.isExistingPathError(error) {
            throw BrowserProfileDeletedError()
        }

        var trashedURL: URL?
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                trashedURL = try trashDirectory(directory)
            } catch {
                let originalStillExists =
                    FileManager.default.fileExists(
                        atPath: directory.path
                    )
                var rollbackError: Error?
                if originalStillExists {
                    do {
                        try removeDeletionTombstone(tombstone)
                    } catch {
                        rollbackError = error
                    }
                } else {
                    rollbackError = ProfileDirectoryRecoveryRequiredError()
                }
                throw ProfileDeleteRollbackError(
                    operationError: error,
                    rollbackError: rollbackError,
                    recoveryTrashURL: nil
                )
            }
        }
        profiles.removeAll { $0.id == profile.id }
        let deletedProfiles = profiles
        let cleanupMarker =
            paths.profileCredentialCleanupMarker(for: profile.id)
        do {
            try beforeDeleteMetadataPersist()
            try persist()
            try afterDeleteMetadataPersist()
            // Only a successfully committed deletion may authorize automatic
            // Keychain cleanup. A crash before this marker can leave an
            // orphaned secret, which is safer than deleting credentials for
            // BrowserData that may still be recoverable from the Trash.
            try paths.createPrivateFileExclusively(
                Data("keychain-cleanup-v1".utf8),
                at: cleanupMarker
            )
        } catch {
            let operationError = error
            do {
                try rollbackDeletion(
                    previousProfiles: previousProfiles,
                    directory: directory,
                    trashedURL: trashedURL,
                    tombstone: tombstone,
                    cleanupProfileID: profile.id
                )
            } catch {
                profiles = deletedProfiles
                throw ProfileDeleteRollbackError(
                    operationError: operationError,
                    rollbackError: error,
                    recoveryTrashURL: trashedURL
                )
            }
            throw operationError
        }
    }

    private func rollbackDeletion(
        previousProfiles: [BrowserProfile],
        directory: URL,
        trashedURL: URL?,
        tombstone: URL,
        cleanupProfileID: UUID
    ) throws {
        if let trashedURL {
            guard FileManager.default.fileExists(atPath: trashedURL.path),
                  !FileManager.default.fileExists(atPath: directory.path)
            else {
                throw ProfileDirectoryRecoveryRequiredError()
            }
            try restoreTrashedDirectory(trashedURL, directory)
            guard FileManager.default.fileExists(atPath: directory.path)
            else {
                throw ProfileDirectoryRecoveryRequiredError()
            }
        }
        profiles = previousProfiles
        try persist(synchronizeRecoverySnapshot: true)
        try removeDeletionTombstone(tombstone)
        try paths.removeCredentialCleanupMarker(
            for: cleanupProfileID
        )
    }

    private func removeDeletionTombstone(_ tombstone: URL) throws {
        switch try paths.privateFileEntryKind(tombstone) {
        case .missing:
            return
        case .unsafe:
            throw POSIXError(.EFTYPE)
        case .regular:
            try FileManager.default.removeItem(at: tombstone)
        }
    }

    private func removeNewProfileDirectories(
        _ directories: [URL]
    ) throws {
        for directory in directories.reversed() {
            guard let identity = try paths.privateFileEntryIdentity(directory)
            else {
                continue
            }
            guard (identity.mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw POSIXError(.EFTYPE)
            }
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func rollbackCompoundMutation(
        previousProfiles: [BrowserProfile],
        committedProfiles: [BrowserProfile],
        previousOrganization: ProfileOrganizationState,
        committedOrganization: ProfileOrganizationState,
        createdDirectories: [URL],
        credentialCleanupRecovery:
            (any ProfileCredentialCleanupRecoveryProviding)?
    ) throws {
        var firstRollbackError: Error?
        var profileRollbackSucceeded = false

        profiles = previousProfiles
        do {
            try persist(synchronizeRecoverySnapshot: true)
            profileRollbackSucceeded = true
        } catch {
            profiles = committedProfiles
            firstRollbackError = error
        }

        organization = previousOrganization
        do {
            try persistOrganization(synchronizeRecoverySnapshot: true)
        } catch {
            organization = committedOrganization
            if firstRollbackError == nil {
                firstRollbackError = error
            }
        }

        if profileRollbackSucceeded {
            do {
                try removeNewProfileDirectories(createdDirectories)
                if let credentialCleanupRecovery {
                    try authorizeCredentialCleanup(
                        for: credentialCleanupRecovery
                            .profileIDsRequiringCredentialCleanup
                    )
                }
            } catch {
                if firstRollbackError == nil {
                    firstRollbackError = error
                }
            }
        }

        if let firstRollbackError {
            throw firstRollbackError
        }
    }

    private func authorizeCredentialCleanup(
        for profileIDs: [UUID]
    ) throws {
        for profileID in Set(profileIDs) {
            guard !profiles.contains(where: { $0.id == profileID }),
                  try paths.privateFileEntryKind(
                      paths.profileDirectory(for: profileID)
                  ) == .missing
            else {
                throw NeAntikError.invalidProfile
            }

            let tombstone = paths.profileDeletionTombstone(for: profileID)
            switch try paths.privateFileEntryKind(tombstone) {
            case .missing:
                try paths.createPrivateFileExclusively(
                    Data("rolled-back-insert-v1".utf8),
                    at: tombstone
                )
            case .regular:
                break
            case .unsafe:
                throw POSIXError(.EFTYPE)
            }

            let marker = paths.profileCredentialCleanupMarker(for: profileID)
            switch try paths.privateFileEntryKind(marker) {
            case .missing:
                try paths.createPrivateFileExclusively(
                    Data("keychain-cleanup-v1".utf8),
                    at: marker
                )
            case .regular:
                break
            case .unsafe:
                throw POSIXError(.EFTYPE)
            }
        }
    }

    private func reloadLatestProfilesForMutation() throws {
        let load = try ProfilesMetadataStorage.readWithRecovery(paths: paths)
        let normalized = try Self.normalizedForIsolation(load.profiles)
        profiles = normalized.profiles
        sortProfiles()
        if normalized.changed || load.requiresMigration {
            try persist()
        }
        if let warning = load.warning {
            lastError = warning
        }
    }

    func mutateOrganization<Result>(
        _ mutation: (inout ProfileOrganizationState) throws -> Result
    ) throws -> Result {
        try requireStorage()
        try requireOrganizationStorage()
        return try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            do {
                try reloadLatestOrganizationForMutation()
            } catch {
                organizationStorageIsAvailable = false
                organization = .empty
                lastError = Self.joinWarnings(
                    lastError,
                    "Папки временно недоступны. Профили и данные браузеров не изменены. \(error.localizedDescription)"
                )
                throw ProfileOrganizationError.storageUnavailable
            }

            let previousOrganization = organization
            var nextOrganization = organization
            let result = try mutation(&nextOrganization)
            guard nextOrganization != previousOrganization else {
                return result
            }
            organization = nextOrganization
            do {
                try persistOrganization()
            } catch {
                organization = previousOrganization
                throw error
            }
            return result
        }
    }

    private func reloadLatestOrganizationForMutation() throws {
        let load = try Self.readOrganizationWithRecovery(
            paths: paths,
            knownProfileIDs: Set(profiles.map(\.id))
        )
        organization = load.state
        if load.changed {
            try persistOrganization()
        }
        if let warning = load.warning {
            lastError = Self.joinWarnings(lastError, warning)
        }
    }

    private static func moveDirectoryToTrash(_ directory: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(
            at: directory,
            resultingItemURL: &resultingURL
        )
        guard let resultingURL = resultingURL as URL? else {
            throw ProfileTrashLocationUnavailableError()
        }
        return resultingURL
    }

    private static func restoreDirectoryFromTrash(
        _ trashedURL: URL,
        _ directory: URL
    ) throws {
        try FileManager.default.moveItem(
            at: trashedURL,
            to: directory
        )
    }

    private static func isExistingPathError(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            return posix.code == .EEXIST
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain &&
            nsError.code == Int(EEXIST)
    }

    private func sortProfiles() {
        profiles.sort(by: ProfileListProjection.areInIncreasingOrder)
    }

    private func persist(
        synchronizeRecoverySnapshot: Bool = false
    ) throws {
        try requireStorage()
        try ProfilesMetadataStorage.persist(
            profiles,
            paths: paths,
            synchronizeRecoverySnapshot: synchronizeRecoverySnapshot
        )
    }

    private func ensureRecoverySnapshotIfNeeded() throws {
        try ProfilesMetadataStorage.ensureRecoverySnapshotIfNeeded(
            paths: paths
        )
    }

    private func persistOrganization(
        synchronizeRecoverySnapshot: Bool = false
    ) throws {
        try requireOrganizationStorage()
        try beforeOrganizationPersist()
        let data = try Self.encodeOrganization(organization)
        if synchronizeRecoverySnapshot {
            try paths.writePrivateFile(
                data,
                to: paths.profileOrganizationBackupFile
            )
            try paths.writePrivateFile(
                data,
                to: paths.profileOrganizationFile
            )
            return
        }
        switch try paths.privateFileEntryKind(
            paths.profileOrganizationFile
        ) {
        case .regular:
            try paths.validatePrivateFile(paths.profileOrganizationFile)
            let previousData = try paths.readPrivateFile(
                paths.profileOrganizationFile,
                maximumBytes: Self.maximumOrganizationMetadataBytes
            )
            _ = try Self.decodeOrganization(
                previousData,
                knownProfileIDs: Set(profiles.map(\.id))
            )
            try paths.writePrivateFile(
                previousData,
                to: paths.profileOrganizationBackupFile
            )
        case .missing:
            try paths.writePrivateFile(
                try Self.encodeOrganization(.empty),
                to: paths.profileOrganizationBackupFile
            )
        case .unsafe:
            throw POSIXError(.EFTYPE)
        }
        try paths.writePrivateFile(data, to: paths.profileOrganizationFile)
    }

    private func ensureOrganizationRecoverySnapshotIfNeeded() throws {
        switch try paths.privateFileEntryKind(
            paths.profileOrganizationFile
        ) {
        case .missing:
            return
        case .unsafe:
            throw POSIXError(.EFTYPE)
        case .regular:
            break
        }

        switch try paths.privateFileEntryKind(
            paths.profileOrganizationBackupFile
        ) {
        case .regular:
            try paths.validatePrivateFile(
                paths.profileOrganizationBackupFile
            )
        case .missing:
            let data = try paths.readPrivateFile(
                paths.profileOrganizationFile,
                maximumBytes: Self.maximumOrganizationMetadataBytes
            )
            _ = try Self.decodeOrganization(
                data,
                knownProfileIDs: Set(profiles.map(\.id))
            )
            try paths.writePrivateFile(
                data,
                to: paths.profileOrganizationBackupFile
            )
        case .unsafe:
            throw POSIXError(.EFTYPE)
        }
    }

    private func requireStorage() throws {
        guard storageIsAvailable else {
            throw ProfileStorageUnavailableError()
        }
    }

    private func requireOrganizationStorage() throws {
        guard organizationStorageIsAvailable else {
            throw ProfileOrganizationError.storageUnavailable
        }
    }

    private static func readOrganizationWithRecovery(
        paths: AppPaths,
        knownProfileIDs: Set<UUID>
    ) throws -> ProfileOrganizationLoad {
        switch try paths.privateFileEntryKind(
            paths.profileOrganizationFile
        ) {
        case .missing:
            return ProfileOrganizationLoad(
                state: .empty,
                changed: false,
                warning: nil
            )
        case .unsafe:
            throw POSIXError(.EFTYPE)
        case .regular:
            break
        }

        let currentData = try paths.readPrivateFile(
            paths.profileOrganizationFile,
            maximumBytes: Self.maximumOrganizationMetadataBytes
        )
        do {
            let decoded = try decodeOrganization(
                currentData,
                knownProfileIDs: knownProfileIDs
            )
            return ProfileOrganizationLoad(
                state: decoded.state,
                changed: decoded.changed,
                warning: nil
            )
        } catch let currentError {
            switch try paths.privateFileEntryKind(
                paths.profileOrganizationBackupFile
            ) {
            case .missing:
                throw currentError
            case .unsafe:
                throw POSIXError(.EFTYPE)
            case .regular:
                break
            }

            let backupData = try paths.readPrivateFile(
                paths.profileOrganizationBackupFile,
                maximumBytes: Self.maximumOrganizationMetadataBytes
            )
            let recovered = try decodeOrganization(
                backupData,
                knownProfileIDs: knownProfileIDs
            )
            let rejectedURL: URL?
            if ProfileRecoveryRetention.shouldPreserveRejectedFile(
                byteCount: currentData.count
            ) {
                let candidate = paths.profilesRecoveryDirectory
                    .appendingPathComponent(
                        "profile-organization-rejected-\(UUID().uuidString).json"
                    )
                try paths.writePrivateFile(currentData, to: candidate)
                rejectedURL = candidate
            } else {
                rejectedURL = nil
            }
            try paths.writePrivateFile(
                backupData,
                to: paths.profileOrganizationFile
            )
            try? ProfileRecoveryRetention.prune(
                directory: paths.profilesRecoveryDirectory,
                preserving: rejectedURL
            )
            return ProfileOrganizationLoad(
                state: recovered.state,
                changed: recovered.changed,
                warning: rejectedURL == nil
                    ? "NeAntik восстановил предыдущую организацию папок. Повреждённый файл превышал безопасный лимит Recovery и не сохранялся; профили и данные браузеров не изменялись."
                    : "Повреждённый файл папок сохранён в Recovery. NeAntik восстановил предыдущую организацию; профили и данные браузеров не изменялись."
            )
        }
    }

    private static func encodeOrganization(
        _ state: ProfileOrganizationState
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ProfileOrganizationDocument(state: state))
    }

    private static func decodeOrganization(
        _ data: Data,
        knownProfileIDs: Set<UUID>
    ) throws -> (state: ProfileOrganizationState, changed: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            ProfileOrganizationDocument.self,
            from: data
        )
        return try document.validatedState(
            knownProfileIDs: knownProfileIDs
        )
    }

    private static func joinWarnings(
        _ first: String?,
        _ second: String?
    ) -> String? {
        switch (first, second) {
        case let (first?, second?):
            return first == second ? first : first + "\n" + second
        case let (first?, nil):
            return first
        case let (nil, second?):
            return second
        case (nil, nil):
            return nil
        }
    }

    private static func normalizedForIsolation(
        _ profiles: [BrowserProfile]
    ) throws -> (profiles: [BrowserProfile], changed: Bool) {
        guard profiles.count <= ProfileStorageLimits.maximumProfileCount else {
            throw NeAntikError.profileLimitReached
        }
        var values = profiles
        var usedIDs = Set<UUID>()
        var usedSeeds = Set<UInt32>()
        var changed = false

        for index in values.indices {
            if !usedIDs.insert(values[index].id).inserted {
                var replacementID = UUID()
                while usedIDs.contains(replacementID) {
                    replacementID = UUID()
                }
                values[index].id = replacementID
                usedIDs.insert(replacementID)
                changed = true
            }

            let identity = values[index].identity
            let requestedSeed = identity.runtimeSeed
            let replacementSeed = usedSeeds.contains(requestedSeed)
                ? try nextAvailableSeed(
                    after: requestedSeed,
                    excluding: usedSeeds
                )
                : requestedSeed
            if replacementSeed != identity.seed {
                guard let replacementIdentity =
                    identity.replacingSeed(replacementSeed)
                else {
                    throw BrowserIdentityAllocationError()
                }
                values[index].identity = replacementIdentity
                changed = true
            }
            usedSeeds.insert(replacementSeed)
        }
        return (values, changed)
    }

    private static func requireInsertionCapacity(
        existingCount: Int,
        additionalCount: Int
    ) throws {
        let maximum = ProfileStorageLimits.maximumProfileCount
        guard existingCount >= 0,
              existingCount <= maximum,
              additionalCount >= 0,
              additionalCount <= maximum - existingCount
        else {
            throw NeAntikError.profileLimitReached
        }
    }

    private static func nextAvailableSeed(
        after seed: UInt32,
        excluding usedSeeds: Set<UInt32>
    ) throws -> UInt32 {
        let tupleCount = UInt32(BrowserIdentityCatalog.tupleIDs.count)
        let residue = seed % tupleCount
        let firstSeed = residue == 0 ? tupleCount : residue
        var candidate =
            seed <= BrowserIdentity.maximumRuntimeSeed - tupleCount
                ? seed + tupleCount
                : firstSeed
        while candidate != seed {
            if !usedSeeds.contains(candidate) {
                return candidate
            }
            candidate =
                candidate <=
                    BrowserIdentity.maximumRuntimeSeed - tupleCount
                    ? candidate + tupleCount
                    : firstSeed
        }
        throw BrowserIdentityAllocationError()
    }

    static func nextRevision(after revision: UInt64) throws -> UInt64 {
        guard revision < UInt64.max else {
            throw BrowserProfileRevisionExhaustedError()
        }
        return revision + 1
    }
}

private struct ProfileOrganizationLoad {
    let state: ProfileOrganizationState
    let changed: Bool
    let warning: String?
}

private struct BrowserIdentityAllocationError: LocalizedError {
    var errorDescription: String? {
        "Не удалось создать отдельный идентификатор профиля. Удали ненужный профиль или обратись в поддержку; существующие данные не изменены."
    }
}

struct BrowserProfileRevisionConflictError: LocalizedError, Equatable {
    let profileID: UUID

    var errorDescription: String? {
        "Профиль изменился в другом окне. Твои изменения не сохранены; открой редактор заново, чтобы не перезаписать более новую версию."
    }
}

private struct BrowserProfileRevisionExhaustedError: LocalizedError {
    var errorDescription: String? {
        "Профиль достиг предельной версии и не был изменён."
    }
}

private struct ProfileSaveRollbackError: LocalizedError {
    let operationError: Error
    let rollbackError: Error

    var errorDescription: String? {
        "Не удалось сохранить профиль, а откат старых метаданных тоже не прошёл. Ошибка сохранения: \(operationError.localizedDescription) Ошибка отката: \(rollbackError.localizedDescription)"
    }
}

struct ProfileDeleteRollbackError: LocalizedError {
    let operationError: Error
    let rollbackError: Error?
    let recoveryTrashURL: URL?

    var errorDescription: String? {
        if rollbackError != nil {
            return "Не удалось завершить удаление и автоматически восстановить папку данных профиля. Запуск профиля заблокирован. Проверь Корзину macOS или обратись в поддержку; данные не очищались безвозвратно."
        }
        return "Не удалось удалить профиль. Данные профиля не изменены."
    }
}

enum ProfileDeletionOutcome: Equatable, Sendable {
    case complete
    case credentialCleanupPending

    var warningDescription: String? {
        switch self {
        case .complete:
            nil
        case .credentialCleanupPending:
            "Профиль и его данные уже удалены. Не удалось полностью очистить пароль прокси из Связки ключей; NeAntik безопасно повторит очистку при следующем запуске."
        }
    }
}

private struct ProfileTrashLocationUnavailableError: LocalizedError {
    var errorDescription: String? {
        "macOS переместила папку данных профиля, но не сообщила её новое расположение."
    }
}

private struct ProfileDirectoryRecoveryRequiredError: LocalizedError {
    var errorDescription: String? {
        "Не удалось подтвердить или восстановить папку данных профиля из Корзины macOS."
    }
}

private struct ProfileStorageUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Не удалось загрузить профили. NeAntik не изменит повреждённое хранилище. Перезапусти приложение. Если ошибка повторится, скопируй сведения об ошибке и обратись в поддержку."
    }
}
