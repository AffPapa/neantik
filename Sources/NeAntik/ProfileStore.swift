import Combine
import Darwin
import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [BrowserProfile] = []
    @Published var lastError: String?

    let paths: AppPaths
    private var storageIsAvailable = true
    private let trashDirectory: (URL) throws -> URL
    private let restoreTrashedDirectory: (URL, URL) throws -> Void
    private let beforeDeleteMetadataPersist: () throws -> Void
    private let afterDeleteMetadataPersist: () throws -> Void

    init(
        paths: AppPaths = AppPaths(),
        trashDirectory: ((URL) throws -> URL)? = nil,
        restoreTrashedDirectory: ((URL, URL) throws -> Void)? = nil,
        beforeDeleteMetadataPersist: @escaping () throws -> Void = {},
        afterDeleteMetadataPersist: @escaping () throws -> Void = {}
    ) {
        self.paths = paths
        self.trashDirectory =
            trashDirectory ?? Self.moveDirectoryToTrash
        self.restoreTrashedDirectory =
            restoreTrashedDirectory ?? Self.restoreDirectoryFromTrash
        self.beforeDeleteMetadataPersist = beforeDeleteMetadataPersist
        self.afterDeleteMetadataPersist = afterDeleteMetadataPersist
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
                }
                lastError = load.warning ?? paths.migrationWarning
            }
        } catch {
            storageIsAvailable = false
            lastError = error.localizedDescription
        }
    }

    var hasTrustedMetadata: Bool {
        storageIsAvailable
    }

    func profile(withID id: UUID?) -> BrowserProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
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
        var value = profile
        guard BrowserProfile.isValidName(value.name),
              ProfileAppearance.isSafeStoredSymbol(value.symbolName),
              let cleanTags = BrowserProfile.normalizedTags(value.tags)
        else {
            throw NeAntikError.invalidProfile
        }
        value.tags = cleanTags
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

    func markLaunched(_ id: UUID) {
        guard storageIsAvailable else {
            lastError = ProfileStorageUnavailableError().localizedDescription
            return
        }
        do {
            try paths.withProfilesMetadataGuard {
                try reloadLatestProfilesForMutation()
                guard try paths.privateFileEntryKind(
                    paths.profileDeletionTombstone(for: id)
                ) == .missing,
                    let index = profiles.firstIndex(
                        where: { $0.id == id }
                    )
                else {
                    return
                }
                let previousProfiles = profiles
                profiles[index].lastLaunchedAt = Date()
                profiles[index].updatedAt = Date()
                do {
                    try persist()
                } catch {
                    profiles = previousProfiles
                    throw error
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(
        _ profile: BrowserProfile,
        processManager: BrowserProcessManager
    ) throws {
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
        try processManager.withVerifiedProfileDeletion(
            profileID: profile.id
        ) {
            try deleteAfterVerifiedPreflight(profile)
        }
        do {
            try afterCommit(profile)
            try paths.removeCredentialCleanupMarker(for: profile.id)
        } catch {
            throw ProfileCredentialCleanupPendingError(
                cleanupError: error
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

    private func reloadLatestProfilesForMutation() throws {
        let load = try Self.readProfilesWithRecovery(paths: paths)
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(
                [BrowserProfile].self,
                from: previousData
            )
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

    private func requireStorage() throws {
        guard storageIsAvailable else {
            throw ProfileStorageUnavailableError()
        }
    }

    private static func readProfiles(from url: URL) throws -> [BrowserProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([BrowserProfile].self, from: Data(contentsOf: url))
    }

    private static func readProfilesWithRecovery(
        paths: AppPaths
    ) throws -> (profiles: [BrowserProfile], warning: String?) {
        do {
            return (
                try readProfiles(from: paths.profilesFile),
                nil
            )
        } catch is DecodingError {
            try paths.validatePrivateFile(paths.profilesFile)
            try paths.validatePrivateFile(paths.profilesBackupFile)
            let backupData = try Data(contentsOf: paths.profilesBackupFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let recovered = try decoder.decode(
                [BrowserProfile].self,
                from: backupData
            )
            let rejectedData = try Data(contentsOf: paths.profilesFile)
            let rejectedURL = paths.profilesRecoveryDirectory
                .appendingPathComponent(
                    "profiles-rejected-\(UUID().uuidString).json"
                )
            try paths.writePrivateFile(rejectedData, to: rejectedURL)
            try paths.writePrivateFile(backupData, to: paths.profilesFile)
            return (
                recovered,
                "Повреждённый файл профилей сохранён в папке Recovery. NeAntik восстановил предыдущую локальную версию; данные браузеров не изменялись."
            )
        }
    }

    private static func normalizedForIsolation(
        _ profiles: [BrowserProfile]
    ) throws -> (profiles: [BrowserProfile], changed: Bool) {
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
}

private struct BrowserIdentityAllocationError: LocalizedError {
    var errorDescription: String? {
        "Не удалось создать отдельный идентификатор профиля. Удали ненужный профиль или обратись в поддержку; существующие данные не изменены."
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
            return "Не удалось завершить удаление и автоматически восстановить папку профиля. Запуск профиля заблокирован. Проверь Корзину macOS или обратись в поддержку; данные не очищались безвозвратно."
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
        "macOS переместила папку профиля, но не сообщила её новое расположение."
    }
}

private struct ProfileDirectoryRecoveryRequiredError: LocalizedError {
    var errorDescription: String? {
        "Не удалось подтвердить или восстановить папку профиля из Корзины macOS."
    }
}

private struct ProfileStorageUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Не удалось загрузить хранилище профилей. NeAntik не будет перезаписывать файл профилей. Сделай копию или почини файл, затем перезапусти NeAntik."
    }
}
