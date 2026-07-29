import Combine
import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [BrowserProfile] = []
    @Published var lastError: String?

    let paths: AppPaths
    private var storageIsAvailable = true

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        do {
            try paths.prepareBaseDirectories()
            try paths.validatePrivateFile(paths.profilesFile)
            let loadedProfiles = try Self.readProfiles(
                from: paths.profilesFile
            )
            let normalized = Self.normalizedForIsolation(loadedProfiles)
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
            lastError = paths.migrationWarning
        } catch {
            storageIsAvailable = false
            lastError = error.localizedDescription
        }
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
        try requireStorage()
        let previousProfiles = profiles
        var value = profile
        guard BrowserProfile.isValidName(value.name) else {
            throw NeAntikError.invalidProfile
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
            value.identity = BrowserIdentity(
                seed: usedSeeds.contains(requestedSeed)
                    ? Self.nextAvailableSeed(
                        after: requestedSeed,
                        excluding: usedSeeds
                    )
                    : requestedSeed,
                timezoneIdentifier: value.identity.timezoneIdentifier,
                localeIdentifier: value.identity.localeIdentifier
            )
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
                try persist()
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
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let previousProfiles = profiles
        profiles[index].lastLaunchedAt = Date()
        profiles[index].updatedAt = Date()
        do {
            try persist()
        } catch {
            profiles = previousProfiles
            lastError = error.localizedDescription
        }
    }

    func delete(_ profile: BrowserProfile) throws {
        try delete(profile, afterDelete: { _ in })
    }

    func delete(
        _ profile: BrowserProfile,
        afterDelete: (BrowserProfile) throws -> Void
    ) throws {
        try requireStorage()
        let previousProfiles = profiles
        let directory = paths.profileDirectory(for: profile.id)
        var trashedURL: URL?
        if FileManager.default.fileExists(atPath: directory.path) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(
                at: directory,
                resultingItemURL: &resultingURL
            )
            trashedURL = resultingURL as URL?
        }
        profiles.removeAll { $0.id == profile.id }
        let deletedProfiles = profiles
        do {
            try persist()
        } catch {
            profiles = previousProfiles
            if let trashedURL,
               FileManager.default.fileExists(atPath: trashedURL.path),
               !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.moveItem(
                    at: trashedURL,
                    to: directory
                )
            }
            throw error
        }
        do {
            try afterDelete(profile)
        } catch {
            let operationError = error
            do {
                if let trashedURL,
                   FileManager.default.fileExists(atPath: trashedURL.path),
                   !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.moveItem(
                        at: trashedURL,
                        to: directory
                    )
                }
                profiles = previousProfiles
                try persist()
            } catch {
                profiles = deletedProfiles
                throw ProfileDeleteRollbackError(
                    operationError: operationError,
                    rollbackError: error
                )
            }
            throw operationError
        }
    }

    private func sortProfiles() {
        profiles.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func persist() throws {
        try requireStorage()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
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

    private static func normalizedForIsolation(
        _ profiles: [BrowserProfile]
    ) -> (profiles: [BrowserProfile], changed: Bool) {
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
                ? nextAvailableSeed(
                    after: requestedSeed,
                    excluding: usedSeeds
                )
                : requestedSeed
            if replacementSeed != identity.seed {
                values[index].identity = BrowserIdentity(
                    seed: replacementSeed,
                    timezoneIdentifier: identity.timezoneIdentifier,
                    localeIdentifier: identity.localeIdentifier
                )
                changed = true
            }
            usedSeeds.insert(replacementSeed)
        }
        return (values, changed)
    }

    private static func nextAvailableSeed(
        after seed: UInt32,
        excluding usedSeeds: Set<UInt32>
    ) -> UInt32 {
        var candidate = seed == BrowserIdentity.maximumRuntimeSeed
            ? 1
            : seed + 1
        while usedSeeds.contains(candidate) {
            candidate = candidate == BrowserIdentity.maximumRuntimeSeed
                ? 1
                : candidate + 1
        }
        return candidate
    }
}

private struct ProfileSaveRollbackError: LocalizedError {
    let operationError: Error
    let rollbackError: Error

    var errorDescription: String? {
        "Не удалось сохранить профиль, а откат старых метаданных тоже не прошёл. Ошибка сохранения: \(operationError.localizedDescription) Ошибка отката: \(rollbackError.localizedDescription)"
    }
}

private struct ProfileDeleteRollbackError: LocalizedError {
    let operationError: Error
    let rollbackError: Error

    var errorDescription: String? {
        "Не удалось удалить профиль, а восстановление тоже не прошло. Ошибка удаления: \(operationError.localizedDescription) Ошибка отката: \(rollbackError.localizedDescription)"
    }
}

private struct ProfileStorageUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Не удалось загрузить хранилище профилей. NeAntik не будет перезаписывать файл профилей. Сделай копию или почини файл, затем перезапусти NeAntik."
    }
}
