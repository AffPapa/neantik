import Combine
import Darwin
import Foundation

protocol ProfileCredentialCleanupRecoveryProviding: Error {
    var profileIDsRequiringCredentialCleanup: [UUID] { get }
}

@MainActor
final class ProfileStore: ObservableObject {
    /// Stores for the same canonical workspace share these admission gates.
    /// This closes the publication race between the detached writer and a
    /// second window/store instance that could otherwise mutate the same files.
    private static var importingRoots = Set<String>()
    private static var refreshingRoots = Set<String>()
    @Published private(set) var profiles: [BrowserProfile] = [] {
        didSet { profileListRevision &+= 1 }
    }
    @Published private(set) var organization = ProfileOrganizationState.empty {
        didSet { profileListRevision &+= 1 }
    }
    @Published private(set) var recoveryNotice: ProfileRecoveryNotice?
    @Published private(set) var metadataUndo: ProfileMetadataUndo?
    @Published var lastError: String?

    /// Monotonic cache key for derived profile-list indexes.
    ///
    /// This avoids comparing complete profile and organization payloads on
    /// every SwiftUI computed-property access. The published properties still
    /// drive rendering; this key only proves whether a cached index is current.
    private(set) var profileListRevision: UInt64 = 0

    lazy var managerLibrary = ManagerLibraryController(paths: paths)

    let paths: AppPaths
    private var storageIsAvailable = true
    private var organizationStorageIsAvailable = true
    private let trashDirectory: (URL) throws -> URL
    private let restoreTrashedDirectory: (URL, URL) throws -> Void
    private let beforeDeleteMetadataPersist: () throws -> Void
    private let afterDeleteMetadataPersist: () throws -> Void
    private let beforeOrganizationPersist: () throws -> Void
    private let beforeBackgroundImportOrganizationPersist:
        @Sendable () throws -> Void

    init(
        paths: AppPaths = AppPaths(),
        readOnlyMetadata: Bool = false,
        trashDirectory: ((URL) throws -> URL)? = nil,
        restoreTrashedDirectory: ((URL, URL) throws -> Void)? = nil,
        beforeDeleteMetadataPersist: @escaping () throws -> Void = {},
        afterDeleteMetadataPersist: @escaping () throws -> Void = {},
        beforeOrganizationPersist: @escaping () throws -> Void = {},
        beforeBackgroundImportOrganizationPersist:
            @escaping @Sendable () throws -> Void = {}
    ) {
        self.paths = paths
        self.trashDirectory =
            trashDirectory ?? Self.moveDirectoryToTrash
        self.restoreTrashedDirectory =
            restoreTrashedDirectory ?? Self.restoreDirectoryFromTrash
        self.beforeDeleteMetadataPersist = beforeDeleteMetadataPersist
        self.afterDeleteMetadataPersist = afterDeleteMetadataPersist
        self.beforeOrganizationPersist = beforeOrganizationPersist
        self.beforeBackgroundImportOrganizationPersist =
            beforeBackgroundImportOrganizationPersist
        if readOnlyMetadata {
            do {
                try paths.validatePrivateDirectory(paths.rootDirectory)
                try paths.withProfilesMetadataGuard {
                    guard let bytes = try Self.boundedMetadata(paths.profilesFile) else { throw POSIXError(.ENOENT) }
                    let decoded = try Self.decodeProfiles(bytes)
                    let checked = try Self.normalizedForIsolation(decoded)
                    guard !checked.changed else { throw POSIXError(.EINVAL) }
                    let organizationBytes = try Self.boundedMetadata(paths.profileOrganizationFile)
                    let folders = try organizationBytes.map { try Self.decodeOrganization($0, knownProfileIDs: Set(decoded.map(\.id))) } ?? (state: ProfileOrganizationState.empty, changed: false)
                    guard !folders.changed else { throw POSIXError(.EINVAL) }
                    profiles = decoded
                    organization = folders.state
                }
            } catch {
                storageIsAvailable = false
                organizationStorageIsAvailable = false
                lastError = "Metadata unavailable. Open NeAntik to inspect recovery; read mode did not repair or replace files."
            }
            return
        }
        do {
            try paths.prepareBaseDirectories()
            try paths.withProfilesMetadataGuard {
                try paths.validatePrivateFile(paths.profilesFile)
                let load = try Self.readProfilesWithRecovery(
                    paths: paths
                )
                let normalized = try Self.normalizedForIsolation(
                    load.profiles
                )
                profiles = normalized.profiles
                if load.recovered {
                    recordRecoveryNotice(profileMetadataRecovered: true)
                }
                if FileManager.default.fileExists(
                    atPath: paths.profilesFile.path
                ) {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: paths.profilesFile.path
                    )
                }
                if normalized.changed {
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
                    if organizationLoad.recovered {
                        recordRecoveryNotice(folderMetadataRecovered: true)
                    }
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

    private var externalMetadataStamp: String?
    private var metadataRefreshFailureWarning: String?

    /// Poll only inode/mtime/size; parsing runs off MainActor after a real change.
    /// Admission spans read and publication, preventing an older snapshot from
    /// replacing a local commit. Drafts retain their original revision.
    func refreshExternalMetadata(force: Bool = false) async throws {
        let rootKey = paths.rootDirectory.resolvingSymlinksInPath().path
        guard !Self.importingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path), !Self.refreshingRoots.contains(rootKey) else { return }
        let paths = paths
        let stamp: String
        do {
            stamp = try await Task.detached {
                try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
                return [paths.profilesFile, paths.profileOrganizationFile].map { url in
                    var info = stat()
                    guard lstat(url.path, &info) == 0 else { return "missing" }
                    return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
                }.joined(separator: "|")
            }.value
        } catch {
            // A fence can appear without changing metadata stamps. Preserve
            // cached rows, but withdraw admission and force the next real read.
            externalMetadataStamp = nil
            storageIsAvailable = false
            organizationStorageIsAvailable = false
            lastError = error is BrowserDataRestoreError ? error.localizedDescription :
                "Профили временно недоступны. Сохранённые данные не заменены. Повтори открытие приложения."
            metadataRefreshFailureWarning = lastError
            throw error
        }
        guard force || stamp != externalMetadataStamp else { return }
        guard !Self.importingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path), !Self.refreshingRoots.contains(rootKey) else { return }
        let hadProfiles = !profiles.isEmpty
        let hadOrganization = organization != .empty
        Self.refreshingRoots.insert(rootKey)
        defer { Self.refreshingRoots.remove(rootKey) }
        let snapshot: ([BrowserProfile], Result<ProfileOrganizationState, Error>)
        do {
            snapshot = try await Task.detached {
                try paths.withProfilesMetadataGuard {
                    let profileData = try Self.boundedMetadata(paths.profilesFile)
                    guard profileData != nil || !hadProfiles else { throw POSIXError(.ENOENT) }
                    let decoded = try profileData.map(Self.decodeProfiles) ?? []
                    let normalized = try Self.normalizedForIsolation(decoded)
                    guard !normalized.changed else { throw POSIXError(.EINVAL) }
                    // Folder metadata has its own availability contract. A bad
                    // sidecar must not disable independently validated profiles.
                    let organization = Result<ProfileOrganizationState, Error> {
                        let organizationData = try Self.boundedMetadata(paths.profileOrganizationFile)
                        guard organizationData != nil || !hadOrganization else { throw POSIXError(.ENOENT) }
                        let decodedOrganization = try organizationData.map {
                            try Self.decodeOrganization($0, knownProfileIDs: Set(decoded.map(\.id)))
                        } ?? (state: ProfileOrganizationState.empty, changed: false)
                        guard !decodedOrganization.changed else { throw POSIXError(.EINVAL) }
                        return decodedOrganization.state
                    }
                    return (decoded, organization)
                }
            }.value
        } catch is ProfileMetadataBusyError {
            // Contention is not corrupted metadata. Retain last-good trust and
            // let the caller retry once the other transaction finishes.
            throw ProfileMetadataBusyError()
        } catch {
            // Preserve last-good UI data and prohibit writes until a trusted read.
            externalMetadataStamp = nil
            storageIsAvailable = false
            organizationStorageIsAvailable = false
            lastError = "Профили временно недоступны. Сохранённые данные не заменены. Проверь файлы данных и повтори открытие приложения."
            metadataRefreshFailureWarning = lastError
            throw error
        }
        if profiles != snapshot.0 { profiles = snapshot.0 }
        storageIsAvailable = true
        switch snapshot.1 {
        case .success(let refreshedOrganization):
            if organization != refreshedOrganization { organization = refreshedOrganization }
            organizationStorageIsAvailable = true
            externalMetadataStamp = stamp
            if let metadataRefreshFailureWarning, lastError == metadataRefreshFailureWarning { lastError = nil }
            metadataRefreshFailureWarning = nil
        case .failure(let error):
            organizationStorageIsAvailable = false
            lastError = "Папки временно недоступны. Профили и данные браузеров не изменены. Проверь файл папок и повтори открытие приложения."
            metadataRefreshFailureWarning = lastError
            throw error
        }
    }

    nonisolated private static func boundedMetadata(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_size <= 64 * 1_024 * 1_024 else { throw POSIXError(.EFTYPE) }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 64 * 1_024 * 1_024 + 1) ?? Data()
        guard bytes.count <= 64 * 1_024 * 1_024 else { throw POSIXError(.EFBIG) }
        return bytes
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
        at date: Date = Date(),
        expectedOrganizationRevision: UUID?? = nil
    ) throws -> ProfileFolder {
        try requireSynchronousMutationAdmission()
        guard let name = ProfileFolder.normalizedName(requestedName) else {
            throw ProfileOrganizationError.invalidFolderName
        }
        return try mutateOrganization(expectedRevision: expectedOrganizationRevision) { state in
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
        at date: Date = Date(),
        expectedOrganizationRevision: UUID?? = nil
    ) throws -> ProfileFolder {
        try requireSynchronousMutationAdmission()
        guard let name = ProfileFolder.normalizedName(requestedName) else {
            throw ProfileOrganizationError.invalidFolderName
        }
        return try mutateOrganization(expectedRevision: expectedOrganizationRevision) { state in
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
    func deleteFolder(withID folderID: UUID, expectedOrganizationRevision: UUID?? = nil) throws -> [UUID] {
        try requireSynchronousMutationAdmission()
        return try mutateOrganization(expectedRevision: expectedOrganizationRevision) { state in
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

    func assignProfiles(
        _ requestedProfileIDs: [UUID],
        toFolderID folderID: UUID?
    ) throws {
        try requireSynchronousMutationAdmission()
        let profileIDs = Set(requestedProfileIDs)
        try mutateOrganization { state in
            let knownProfileIDs = Set(profiles.map(\.id))
            guard profileIDs.isSubset(of: knownProfileIDs) else {
                throw ProfileOrganizationError.profileNotFound
            }
            if let folderID,
               state.folder(withID: folderID) == nil {
                throw ProfileOrganizationError.folderNotFound
            }
            state.assign(profileIDs: profileIDs, toFolderID: folderID)
        }
    }

    func moveProfileWithUndo(_ profile: BrowserProfile, toFolderID folderID: UUID?) throws {
        var before: BrowserProfile?
        var oldFolderID: UUID?
        try mutateOrganization { state in
            guard let current = profiles.first(where: { $0.id == profile.id }),
                  current.revision == profile.revision else { throw ProfileMetadataUndoConflict() }
            if let folderID, state.folder(withID: folderID) == nil { throw ProfileOrganizationError.folderNotFound }
            oldFolderID = state.folderID(forProfileID: profile.id)
            guard oldFolderID != folderID else { return }
            before = current
            state.assign(profileIDs: [profile.id], toFolderID: folderID)
        }
        if let before {
            metadataUndo = ProfileMetadataUndo(before: before, after: before, folderID: oldFolderID,
                organizationRevision: organization.mutationRevision, folderOnly: true)
        }
    }

    func unfileProfile(_ profileID: UUID) throws {
        try assignProfile(profileID, toFolderID: nil)
    }

    func validateInsertionCapacity(
        forAdditionalProfileCount additionalCount: Int
    ) throws {
        try requireSynchronousMutationAdmission()
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
        try requireSynchronousMutationAdmission()
        return try paths.withProfilesMetadataGuard {
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
        registerMetadataUndo: Bool = false,
        _ mutation: (inout BrowserProfile) throws -> Void
    ) throws -> BrowserProfile {
        try requireSynchronousMutationAdmission()
        return try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            guard var current = profiles.first(where: { $0.id == profileID })
            else {
                throw BrowserProfileDeletedError()
            }
            let before = current
            if registerMetadataUndo { try reloadLatestOrganizationForMutation() }
            let expectedRevision = current.revision
            try mutation(&current)
            guard current.id == profileID,
                  current.revision == expectedRevision
            else {
                throw NeAntikError.invalidProfile
            }
            let saved = try upsertAfterMetadataReload(current, afterPersist: { _ in })
            if registerMetadataUndo, ProfileMetadataUndo.onlyAllowedFieldsChanged(before: before, after: saved) {
                metadataUndo = ProfileMetadataUndo(before: before, after: saved,
                    folderID: organization.folderID(forProfileID: saved.id),
                    organizationRevision: organization.mutationRevision)
            }
            return saved
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
        registerMetadataUndo: Bool = false,
        expectedOrganizationRevision: UUID?? = nil,
        afterPersist: (BrowserProfile) throws -> Void = { _ in }
    ) throws -> BrowserProfile {
        try requireSynchronousMutationAdmission()
        return try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            return try upsertWithFolderAfterMetadataReload(
                profile, toFolderID: folderID,
                registerMetadataUndo: registerMetadataUndo,
                expectedOrganizationRevision: expectedOrganizationRevision,
                afterPersist: afterPersist
            )
        }
    }

    /// Caller owns the metadata guard and has reloaded the profile document.
    /// Both ordinary saves and configuration copies share folder/credential rollback.
    private func upsertWithFolderAfterMetadataReload(
        _ profile: BrowserProfile,
        toFolderID folderID: UUID?,
        registerMetadataUndo: Bool = false,
        expectedOrganizationRevision: UUID?? = nil,
        afterPersist: (BrowserProfile) throws -> Void
    ) throws -> BrowserProfile {
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

        if let expectedOrganizationRevision,
           expectedOrganizationRevision != organization.mutationRevision {
            throw ProfileMetadataUndoConflict()
        }
        let previousProfiles = profiles
        let previousOrganization = organization
        var createdDirectory: OwnedProfileDirectory?
        let saved = try upsertAfterMetadataReload(
            profile,
            afterPersist: { _ in },
            createdDirectory: { createdDirectory = $0 }
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
                committedOrganization = organization
            }
            try afterPersist(saved)
        } catch {
            let operationError = error
            let createdDirectories = createdDirectory.map { [$0] } ?? []
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
        if registerMetadataUndo,
           let before = previousProfiles.first(where: { $0.id == saved.id }),
           ProfileMetadataUndo.onlyAllowedFieldsChanged(before: before, after: saved) {
            metadataUndo = ProfileMetadataUndo(before: before, after: saved,
                folderID: previousOrganization.folderID(forProfileID: saved.id),
                organizationRevision: organization.mutationRevision)
        }
        return saved
    }

    @discardableResult
    func undoLastMetadataChange() throws -> BrowserProfile {
        guard let token = metadataUndo,
              var profile = profile(withID: token.profileID), profile.revision == token.revision
        else { throw ProfileMetadataUndoConflict() }
        if token.folderOnly {
            try mutateOrganization { state in
                guard state.mutationRevision == token.organizationRevision,
                      profiles.first(where: { $0.id == token.profileID })?.revision == token.revision
                else { throw ProfileMetadataUndoConflict() }
                if let folderID = token.folderID, state.folder(withID: folderID) == nil { throw ProfileOrganizationError.folderNotFound }
                state.assign(profileIDs: [token.profileID], toFolderID: token.folderID)
            }
            metadataUndo = nil
            return profile
        }
        profile.name = token.name; profile.tags = token.tags; profile.isArchived = token.isArchived
        let saved = try upsert(profile, toFolderID: token.folderID,
            expectedOrganizationRevision: .some(token.organizationRevision))
        metadataUndo = nil
        return saved
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

    /// Bookmarks enter only a newly minted profile, never an existing identity
    /// or an open BrowserData tree. This operation does not start the browser.
    func createProfileFromBookmarks(name: String, document: BookmarkImportDocument) async throws -> BrowserProfile {
        let profile = BrowserProfile(name: name, startURL: "about:blank", proxy: nil)
        let inserted = try await insertImportedProfilesOffMainActor([profile], folderNames: [nil], initialBookmarks: [profile.id: document])
        guard inserted.count == 1, let saved = inserted.first else { throw NeAntikError.invalidProfile }
        return saved
    }

    /// Runs the import's complete metadata transaction away from the main
    /// actor. The synchronous mutation admission gate stays closed until the
    /// disk transaction finishes and its small in-memory publication occurs.
    @discardableResult
    func insertImportedProfilesOffMainActor(
        _ requestedProfiles: [BrowserProfile],
        folderNames: [String?],
        initialBookmarks: [UUID: BookmarkImportDocument] = [:]
    ) async throws -> [BrowserProfile] {
        guard !Self.importingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path), !Self.refreshingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path) else {
            throw ProfileMetadataMutationInProgressError()
        }
        guard storageIsAvailable else {
            throw ProfileStorageUnavailableError()
        }
        guard organizationStorageIsAvailable else {
            throw ProfileOrganizationError.storageUnavailable
        }
        let rootKey = paths.rootDirectory.resolvingSymlinksInPath().path
        Self.importingRoots.insert(rootKey)
        defer { Self.importingRoots.remove(rootKey) }

        let paths = self.paths
        let beforeOrganizationPersist =
            beforeBackgroundImportOrganizationPersist
        let worker = Task.detached(priority: .userInitiated) {
            try ProfileMetadataImportTransaction.run(
                paths: paths,
                requestedProfiles: requestedProfiles,
                folderNames: folderNames,
                initialBookmarks: initialBookmarks,
                beforeOrganizationPersist: beforeOrganizationPersist
            )
        }
        let result: ProfileMetadataImportResult
        do {
            result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        } catch {
            let importError = error
            let reconciliation = Task.detached(priority: .userInitiated) {
                try ProfileMetadataImportTransaction.reconcile(paths: paths)
            }
            do {
                let recoveredState = try await reconciliation.value
                profiles = recoveredState.profiles
                organization = recoveredState.organization
                if recoveredState.profileMetadataRecovered {
                    recordRecoveryNotice(profileMetadataRecovered: true)
                }
                if recoveredState.folderMetadataRecovered {
                    recordRecoveryNotice(folderMetadataRecovered: true)
                }
                lastError = Self.joinWarnings(
                    lastError,
                    recoveredState.warning
                )
            } catch {
                // A failed reload means the published snapshot can no longer
                // be trusted. Fail closed instead of leaving stale profiles
                // visible after recovery or normalization changed disk state.
                storageIsAvailable = false
                organizationStorageIsAvailable = false
                profiles = []
                organization = .empty
                lastError = Self.joinWarnings(
                    lastError,
                    "Локальные данные профилей требуют проверки. Импорт остановлен. \(error.localizedDescription)"
                )
            }
            throw importError
        }
        // No suspension after the worker completes: the gate prevents a
        // synchronous mutation from publishing a newer in-memory revision
        // while this transaction owns the on-disk metadata lock.
        profiles = result.profiles
        organization = result.organization
        if result.profileMetadataRecovered {
            recordRecoveryNotice(profileMetadataRecovered: true)
        }
        if result.folderMetadataRecovered {
            recordRecoveryNotice(folderMetadataRecovered: true)
        }
        lastError = Self.joinWarnings(lastError, result.warning)
        return result.insertedProfiles
    }

    private func insertNewProfiles(
        _ requestedProfiles: [BrowserProfile],
        targetFolderID: UUID?,
        afterPersist: ([BrowserProfile]) throws -> Void
    ) throws -> [BrowserProfile] {
        try OwnedProfileDirectory.requireDescriptorBudget(profileCount: requestedProfiles.count)
        try requireSynchronousMutationAdmission()
        return try paths.withProfilesMetadataGuard {
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
            var createdDirectories: [OwnedProfileDirectory] = []
            do {
                for profile in inserted {
                    let directory = paths.profileDirectory(for: profile.id)
                    guard !FileManager.default.fileExists(
                        atPath: directory.path
                    ) else {
                        throw NeAntikError.invalidProfile
                    }
                    let owned = try OwnedProfileDirectory(paths: paths, profileID: profile.id)
                    createdDirectories.append(owned)
                    try owned.prepareBrowserData()
                }

                profiles = normalized
                sortProfiles()
                try persist()
            } catch {
                let operationError = error
                profiles = previousProfiles
                do { try removeNewProfileDirectories(createdDirectories) }
                catch { throw ProfileSaveRollbackError(operationError: operationError, rollbackError: error) }
                throw operationError
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
                        committedOrganization = organization
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

    /// Copy config under the same metadata lock as the source revision check.
    func duplicateProfile(_ original: BrowserProfile, name: String,
                          afterPersist: (BrowserProfile) throws -> Void = { _ in }) throws -> BrowserProfile {
        try requireSynchronousMutationAdmission()
        return try paths.withProfilesMetadataGuard {
            try reloadLatestProfilesForMutation()
            guard let current = profile(withID: original.id), current.revision == original.revision else {
                throw BrowserProfileRevisionConflictError(profileID: original.id)
            }
            var copy = current.duplicated()
            copy.name = name
            // Read the source folder under the same guard as its revision.
            // A copy has a fresh identity; this never copies BrowserData.
            try requireOrganizationStorage()
            try reloadLatestOrganizationForMutation()
            let folderID = organization.folderID(forProfileID: current.id)
            return try upsertWithFolderAfterMetadataReload(
                copy, toFolderID: folderID, afterPersist: afterPersist
            )
        }
    }

    private func upsertAfterMetadataReload(
        _ profile: BrowserProfile,
        afterPersist: (BrowserProfile) throws -> Void,
        createdDirectory: ((OwnedProfileDirectory?) -> Void)? = nil
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
        guard current != nil || !profileDirectoryExisted else { throw NeAntikError.invalidProfile }
        var owned: OwnedProfileDirectory?
        do {
            if profileDirectoryExisted {
                try paths.prepareProfileDirectories(for: value.id)
            } else {
                try OwnedProfileDirectory.requireDescriptorBudget(profileCount: 1)
                owned = try OwnedProfileDirectory(paths: paths, profileID: value.id)
                try owned!.prepareBrowserData()
            }
            createdDirectory?(owned)
        } catch {
            let operationError = error
            do { try owned?.removeEmptyOwnedDirectories() }
            catch { throw ProfileSaveRollbackError(operationError: operationError, rollbackError: error) }
            throw operationError
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
            let operationError = error
            profiles = previousProfiles
            do { try owned?.removeEmptyOwnedDirectories() }
            catch { throw ProfileSaveRollbackError(operationError: operationError, rollbackError: error) }
            throw operationError
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
            do { try owned?.removeEmptyOwnedDirectories() }
            catch { throw ProfileSaveRollbackError(operationError: operationError, rollbackError: error) }
            throw operationError
        }
        return value
    }

    @discardableResult
    func markLaunched(_ id: UUID) -> Bool {
        guard !Self.importingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path), !Self.refreshingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path) else {
            lastError = ProfileMetadataMutationInProgressError()
                .localizedDescription
            return false
        }
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
                profiles[index].updatedAt = Date()
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

    func delete(
        _ profile: BrowserProfile,
        processManager: BrowserProcessManager
    ) throws {
        try requireSynchronousMutationAdmission()
        try delete(
            profile,
            processManager: processManager,
            afterCommit: { _ in }
        )
    }

    func delete(
        _ profile: BrowserProfile,
        processManager: BrowserProcessManager,
        afterCommit: (BrowserProfile) throws -> Void
    ) throws {
        try requireSynchronousMutationAdmission()
        try processManager.withVerifiedProfileDeletion(
            profileID: profile.id
        ) {
            try deleteAfterVerifiedPreflight(profile)
        }
        pruneOrganizationAfterProfileDeletion()
        do {
            try afterCommit(profile)
            try paths.removeCredentialCleanupMarker(for: profile.id)
        } catch {
            throw ProfileCredentialCleanupPendingError(
                cleanupError: error
            )
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
        guard let current = profiles.first(where: { $0.id == profile.id }) else {
            throw BrowserProfileDeletedError()
        }
        guard current.revision == profile.revision else {
            throw ProfileDeleteRevisionConflictError()
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
        _ directories: [OwnedProfileDirectory]
    ) throws {
        for directory in directories.reversed() {
            try directory.removeEmptyOwnedDirectories()
        }
    }

    private func rollbackCompoundMutation(
        previousProfiles: [BrowserProfile],
        committedProfiles: [BrowserProfile],
        previousOrganization: ProfileOrganizationState,
        committedOrganization: ProfileOrganizationState,
        createdDirectories: [OwnedProfileDirectory],
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
        let load = try Self.readProfilesWithRecovery(paths: paths)
        if load.recovered {
            recordRecoveryNotice(profileMetadataRecovered: true)
        }
        let normalized = try Self.normalizedForIsolation(load.profiles)
        profiles = normalized.profiles
        sortProfiles()
        if normalized.changed {
            try persist()
        }
        if let warning = load.warning {
            lastError = warning
        }
    }

    private func mutateOrganization<Result>(
        expectedRevision: UUID?? = nil,
        _ mutation: (inout ProfileOrganizationState) throws -> Result
    ) throws -> Result {
        try requireStorage()
        try requireOrganizationStorage()
        // Fail before waiting on a worker-owned flock; UI mutations must not
        // interleave with the import's disk commit and state publication.
        try requireSynchronousMutationAdmission()
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

            if let expectedRevision, organization.mutationRevision != expectedRevision {
                throw ProfileMetadataUndoConflict()
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
        if load.recovered {
            recordRecoveryNotice(folderMetadataRecovered: true)
        }
        if load.changed {
            try persistOrganization()
        }
        if let warning = load.warning {
            lastError = Self.joinWarnings(lastError, warning)
        }
    }

    private func recordRecoveryNotice(
        profileMetadataRecovered: Bool = false,
        folderMetadataRecovered: Bool = false
    ) {
        let current = recoveryNotice
        let profilesRecovered =
            (current?.profileMetadataRecovered ?? false) ||
            profileMetadataRecovered
        let foldersRecovered =
            (current?.folderMetadataRecovered ?? false) ||
            folderMetadataRecovered
        guard profilesRecovered || foldersRecovered else { return }
        recoveryNotice = ProfileRecoveryNotice(
            profileMetadataRecovered: profilesRecovered,
            folderMetadataRecovered: foldersRecovered
        )
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        if synchronizeRecoverySnapshot {
            try paths.writePrivateFile(
                data,
                to: paths.profilesBackupFile
            )
            try paths.writePrivateFile(data, to: paths.profilesFile)
            return
        }
        if FileManager.default.fileExists(atPath: paths.profilesFile.path) {
            try paths.validatePrivateFile(paths.profilesFile)
            let previousData = try Data(contentsOf: paths.profilesFile)
            _ = try Self.decodeProfiles(previousData)
            try paths.writePrivateFile(
                previousData,
                to: paths.profilesBackupFile
            )
        } else {
            try paths.writePrivateFile(
                data,
                to: paths.profilesBackupFile
            )
        }
        try paths.writePrivateFile(data, to: paths.profilesFile)
    }

    private func ensureRecoverySnapshotIfNeeded() throws {
        guard FileManager.default.fileExists(
            atPath: paths.profilesFile.path
        ) else {
            return
        }
        if FileManager.default.fileExists(
            atPath: paths.profilesBackupFile.path
        ) {
            try paths.validatePrivateFile(paths.profilesBackupFile)
            return
        }
        try paths.validatePrivateFile(paths.profilesFile)
        let data = try Data(contentsOf: paths.profilesFile)
        try paths.writePrivateFile(
            data,
            to: paths.profilesBackupFile
        )
    }

    private func persistOrganization(
        synchronizeRecoverySnapshot: Bool = false
    ) throws {
        try requireOrganizationStorage()
        try beforeOrganizationPersist()
        var next = organization
        next.mutationRevision = UUID()
        let data = try Self.encodeOrganization(next)
        if synchronizeRecoverySnapshot {
            try paths.writePrivateFile(
                data,
                to: paths.profileOrganizationBackupFile
            )
            try paths.writePrivateFile(
                data,
                to: paths.profileOrganizationFile
            )
            organization = next
            return
        }
        switch try paths.privateFileEntryKind(
            paths.profileOrganizationFile
        ) {
        case .regular:
            try paths.validatePrivateFile(paths.profileOrganizationFile)
            let previousData = try Data(
                contentsOf: paths.profileOrganizationFile
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
        organization = next
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
            let data = try Data(contentsOf: paths.profileOrganizationFile)
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

    private func requireSynchronousMutationAdmission() throws {
        guard !Self.importingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path), !Self.refreshingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path) else {
            throw ProfileMetadataMutationInProgressError()
        }
    }

    /// Reserve a launch while holding process -> metadata guards in that order.
    /// A captured UI value is never authority for a route after another writer
    /// changes its revision. Compare identity at the persisted ISO8601 precision.
    static func withValidatedLaunchSnapshot<Result>(
        _ expected: BrowserProfile, paths: AppPaths,
        operation: () throws -> Result
    ) throws -> Result {
        guard !importingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path), !refreshingRoots.contains(paths.rootDirectory.resolvingSymlinksInPath().path) else {
            throw ProfileMetadataMutationInProgressError()
        }
        return try withPersistedLaunchSnapshot(expected, paths: paths, operation: operation)
    }

    /// Disk-only snapshot guard for relay activation on its executor. The
    /// metadata guard is held through the bounded commit acknowledgement so a
    /// concurrent writer cannot publish a new route between validation and
    /// activation. UI mutation admission remains in the MainActor wrapper.
    nonisolated static func withPersistedLaunchSnapshot<Result>(
        _ expected: BrowserProfile, paths: AppPaths, operation: () throws -> Result
    ) throws -> Result {
        return try paths.withProfilesMetadataGuard {
            let profiles = try readProfilesWithRecovery(paths: paths).profiles
            let normalized = try normalizedForIsolation(profiles)
            guard !normalized.changed else { throw ProfileStorageUnavailableError() }
            guard let current = profiles.first(where: { $0.id == expected.id }) else {
                throw BrowserProfileDeletedError()
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let persistedExpectedIdentity = try decoder.decode(BrowserIdentity.self, from: encoder.encode(expected.identity))
            guard current.revision == expected.revision,
                  current.proxy == expected.proxy,
                  current.identity == persistedExpectedIdentity,
                  current.startURL == expected.startURL,
                  current.isArchived == expected.isArchived else {
                throw BrowserProfileRevisionConflictError(profileID: expected.id)
            }
            return try operation()
        }
    }

    func validateLaunchSnapshot(_ profile: BrowserProfile) throws {
        try requireStorage()
        try Self.withValidatedLaunchSnapshot(profile, paths: paths) {}
    }

    nonisolated static func readProfiles(from url: URL) throws -> [BrowserProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decodeProfiles(Data(contentsOf: url))
    }

    nonisolated static func decodeProfiles(_ data: Data) throws -> [BrowserProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == 0x7B {
            let document = try decoder.decode(LegacyProfilesDocument.self, from: data)
            guard document.schemaVersion == 1 else {
                throw UnsupportedProfilesSchemaError()
            }
            return document.profiles
        }
        return try decoder.decode([BrowserProfile].self, from: data)
    }

    nonisolated static func readProfilesWithRecovery(
        paths: AppPaths
    ) throws -> (
        profiles: [BrowserProfile],
        warning: String?,
        recovered: Bool
    ) {
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
        // Every caller, including mutation reloads, must fail before reading if
        // another process replaced metadata with a symlink or non-regular
        // entry. The metadata guard coordinates NeAntik instances; this check
        // also protects against unrelated local path replacement.
        try paths.validatePrivateFile(paths.profilesFile)
        if try paths.privateFileEntryKind(paths.profilesFile) == .missing {
            switch try paths.privateFileEntryKind(paths.profilesBackupFile) {
            case .missing:
                return ([], nil, false)
            case .unsafe:
                throw POSIXError(.EFTYPE)
            case .regular:
                try paths.validatePrivateFile(paths.profilesBackupFile)
                let backupData = try Data(contentsOf: paths.profilesBackupFile)
                let recovered = try decodeProfiles(backupData)
                try paths.writePrivateFile(backupData, to: paths.profilesFile)
                return (
                    recovered,
                    "Основной файл профилей отсутствовал. NeAntik восстановил предыдущую локальную версию; данные браузеров не изменялись.",
                    true
                )
            }
        }
        do {
            return (
                try readProfiles(from: paths.profilesFile),
                nil,
                false
            )
        } catch is DecodingError {
            try paths.validatePrivateFile(paths.profilesFile)
            try paths.validatePrivateFile(paths.profilesBackupFile)
            let backupData = try Data(contentsOf: paths.profilesBackupFile)
            let recovered = try decodeProfiles(backupData)
            let rejectedData = try Data(contentsOf: paths.profilesFile)
            let rejectedURL = paths.profilesRecoveryDirectory
                .appendingPathComponent(
                    "profiles-rejected-\(UUID().uuidString).json"
                )
            try paths.writePrivateFile(rejectedData, to: rejectedURL)
            try paths.writePrivateFile(backupData, to: paths.profilesFile)
            return (
                recovered,
                "Повреждённый файл профилей сохранён в папке Recovery. NeAntik восстановил предыдущую локальную версию; данные браузеров не изменялись.",
                true
            )
        }
    }

    nonisolated static func readOrganizationWithRecovery(
        paths: AppPaths,
        knownProfileIDs: Set<UUID>
    ) throws -> ProfileOrganizationLoad {
        switch try paths.privateFileEntryKind(
            paths.profileOrganizationFile
        ) {
        case .missing:
            switch try paths.privateFileEntryKind(
                paths.profileOrganizationBackupFile
            ) {
            case .missing:
                return ProfileOrganizationLoad(
                    state: .empty,
                    changed: false,
                    warning: nil,
                    recovered: false
                )
            case .unsafe:
                throw POSIXError(.EFTYPE)
            case .regular:
                try paths.validatePrivateFile(paths.profileOrganizationBackupFile)
                let backupData = try Data(
                    contentsOf: paths.profileOrganizationBackupFile
                )
                let recovered = try decodeOrganization(
                    backupData,
                    knownProfileIDs: knownProfileIDs
                )
                try paths.writePrivateFile(
                    backupData,
                    to: paths.profileOrganizationFile
                )
                return ProfileOrganizationLoad(
                    state: recovered.state,
                    changed: recovered.changed,
                    warning: "Основной файл папок отсутствовал. NeAntik восстановил предыдущую организацию; профили и данные браузеров не изменялись.",
                    recovered: true
                )
            }
        case .unsafe:
            throw POSIXError(.EFTYPE)
        case .regular:
            break
        }

        let currentData = try Data(
            contentsOf: paths.profileOrganizationFile
        )
        do {
            let decoded = try decodeOrganization(
                currentData,
                knownProfileIDs: knownProfileIDs
            )
            return ProfileOrganizationLoad(
                state: decoded.state,
                changed: decoded.changed,
                warning: nil,
                recovered: false
            )
        } catch ProfileOrganizationDocumentError.unsupportedSchema {
            // A newer document is not corruption. Never downgrade it from backup.
            throw ProfileOrganizationDocumentError.unsupportedSchema
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

            let backupData = try Data(
                contentsOf: paths.profileOrganizationBackupFile
            )
            let recovered = try decodeOrganization(
                backupData,
                knownProfileIDs: knownProfileIDs
            )
            let rejectedURL = paths.profilesRecoveryDirectory
                .appendingPathComponent(
                    "profile-organization-rejected-\(UUID().uuidString).json"
                )
            try paths.writePrivateFile(currentData, to: rejectedURL)
            try paths.writePrivateFile(
                backupData,
                to: paths.profileOrganizationFile
            )
            return ProfileOrganizationLoad(
                state: recovered.state,
                changed: recovered.changed,
                warning:
                    "Повреждённый файл папок сохранён в Recovery. NeAntik восстановил предыдущую организацию; профили и данные браузеров не изменялись.",
                recovered: true
            )
        }
    }

    nonisolated static func encodeOrganization(
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

    nonisolated static func decodeOrganization(
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

    nonisolated static func normalizedForIsolation(
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

    nonisolated static func requireInsertionCapacity(
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

    nonisolated static func nextAvailableSeed(
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

    private static func nextRevision(after revision: UInt64) throws -> UInt64 {
        guard revision < UInt64.max else {
            throw BrowserProfileRevisionExhaustedError()
        }
        return revision + 1
    }
}

struct ProfileOrganizationLoad: Sendable {
    let state: ProfileOrganizationState
    let changed: Bool
    let warning: String?
    let recovered: Bool
}

/// Older NeAntik installations stored the same profile records in a v1
/// envelope. Keep reading it so an upgrade never turns valid user profiles
/// into an apparent empty workspace. New writes continue using the array form.
private struct LegacyProfilesDocument: Decodable {
    let schemaVersion: Int
    let profiles: [BrowserProfile]

    private enum CodingKeys: String, CodingKey { case schemaVersion, profiles }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        // Check the contract before interpreting an unknown payload shape.
        guard schemaVersion == 1 else { throw UnsupportedProfilesSchemaError() }
        profiles = try values.decode([BrowserProfile].self, forKey: .profiles)
    }
}

private struct UnsupportedProfilesSchemaError: LocalizedError {
    var errorDescription: String? {
        "Версия файла профилей не поддерживается. Данные не изменены. Открой их в совместимой версии NeAntik или обратись в поддержку."
    }
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

struct ProfileDeleteRevisionConflictError: LocalizedError, Equatable {
    var errorDescription: String? {
        "Профиль изменился в другом окне. Удаление отменено; проверь текущие данные и повтори действие."
    }
}

private struct BrowserProfileRevisionExhaustedError: LocalizedError {
    var errorDescription: String? {
        "Профиль достиг предельной версии и не был изменён."
    }
}

struct ProfileSaveRollbackError: LocalizedError {
    let operationError: Error
    let rollbackError: Error

    var errorDescription: String? {
        // Both nested file-system errors can disclose private paths. The
        // detailed values remain available to the private debugger while the
        // user-facing error stays safe and actionable.
        "Не удалось сохранить профиль, а откат старых метаданных тоже не " +
            "прошёл. Повтори операцию позже или проверь доступ к данным " +
            "приложения."
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

struct ProfileCredentialCleanupPendingError: LocalizedError {
    let cleanupError: Error

    var errorDescription: String? {
        "Профиль и его данные уже удалены. Не удалось полностью очистить пароль прокси из Связки ключей; повторный запуск профиля заблокирован. NeAntik безопасно повторит очистку при следующем запуске."
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
