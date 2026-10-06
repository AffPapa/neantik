import Darwin
import Foundation

struct ProfileMetadataImportResult: Sendable {
    let insertedProfiles: [BrowserProfile]
    let profiles: [BrowserProfile]
    let organization: ProfileOrganizationState
    let profileMetadataRecovered: Bool
    let folderMetadataRecovered: Bool
    let warning: String?
}

/// Owns the blocking part of an imported-profile metadata transaction.
/// It intentionally has no reference to ProfileStore or any actor-isolated UI
/// state. The caller holds a main-actor admission gate until this returns.
enum ProfileMetadataImportTransaction {
    /// Reloads the state that may have been repaired before a later import
    /// validation failed. Callers run this under the same metadata lock.
    static func reconcile(paths: AppPaths) throws -> ProfileMetadataImportResult {
        try paths.withProfilesMetadataGuard {
            let profileLoad = try ProfileStore.readProfilesWithRecovery(
                paths: paths
            )
            let normalized = try ProfileStore.normalizedForIsolation(
                profileLoad.profiles
            )
            let profiles = normalized.profiles.sorted(
                by: ProfileListProjection.areInIncreasingOrder
            )
            if normalized.changed {
                try persistProfiles(profiles, paths: paths)
            }

            let knownProfileIDs = Set(profiles.map(\.id))
            let organizationLoad = try ProfileStore
                .readOrganizationWithRecovery(
                    paths: paths,
                    knownProfileIDs: knownProfileIDs
                )
            if organizationLoad.changed {
                try persistOrganization(
                    organizationLoad.state,
                    paths: paths,
                    knownProfileIDs: knownProfileIDs
                )
            }
            let warning = [profileLoad.warning, organizationLoad.warning]
                .compactMap { $0 }
                .joined(separator: "\n")
            return ProfileMetadataImportResult(
                insertedProfiles: [],
                profiles: profiles,
                organization: organizationLoad.state,
                profileMetadataRecovered: profileLoad.recovered,
                folderMetadataRecovered: organizationLoad.recovered,
                warning: warning.isEmpty ? nil : warning
            )
        }
    }

    static func run(
        paths: AppPaths,
        requestedProfiles: [BrowserProfile],
        folderNames: [String?],
        beforeOrganizationPersist: @Sendable () throws -> Void = {}
    ) throws -> ProfileMetadataImportResult {
        guard !requestedProfiles.isEmpty,
              requestedProfiles.count == folderNames.count
        else {
            throw NeAntikError.invalidProfile
        }

        return try paths.withProfilesMetadataGuard {
            let profileLoad = try ProfileStore.readProfilesWithRecovery(
                paths: paths
            )
            let normalized = try ProfileStore.normalizedForIsolation(
                profileLoad.profiles
            )
            let previousProfiles = normalized.profiles.sorted(
                by: ProfileListProjection.areInIncreasingOrder
            )
            if normalized.changed {
                try persistProfiles(previousProfiles, paths: paths)
            }

            let organizationLoad = try ProfileStore
                .readOrganizationWithRecovery(
                    paths: paths,
                    knownProfileIDs: Set(previousProfiles.map(\.id))
                )
            let previousOrganization = organizationLoad.state
            if organizationLoad.changed {
                try persistOrganization(
                    previousOrganization,
                    paths: paths,
                    knownProfileIDs: Set(previousProfiles.map(\.id))
                )
            }
            try ProfileStore.requireInsertionCapacity(
                existingCount: previousProfiles.count,
                additionalCount: requestedProfiles.count
            )

            let operationDate = Date()
            var nextOrganization = previousOrganization
            var folderIDByComparisonKey: [String: UUID] = [:]
            var folderIDs = Set(previousOrganization.folders.map(\.id))
            var newFolders: [ProfileFolder] = []
            for folder in previousOrganization.folders {
                folderIDByComparisonKey[
                    ProfileFolder.comparisonKey(folder.name)
                ] = folder.id
            }

            var folderIDsByProfileIndex: [UUID?] = []
            folderIDsByProfileIndex.reserveCapacity(folderNames.count)
            for requestedName in folderNames {
                guard let requestedName else {
                    folderIDsByProfileIndex.append(nil)
                    continue
                }
                guard let normalizedName = ProfileFolder.normalizedName(
                    requestedName
                ) else {
                    throw ProfileOrganizationError.invalidFolderName
                }
                let key = ProfileFolder.comparisonKey(normalizedName)
                if let existingID = folderIDByComparisonKey[key] {
                    folderIDsByProfileIndex.append(existingID)
                    continue
                }
                var folderID = UUID()
                while !folderIDs.insert(folderID).inserted {
                    folderID = UUID()
                }
                newFolders.append(ProfileFolder(
                    id: folderID,
                    name: normalizedName,
                    createdAt: operationDate,
                    updatedAt: operationDate
                ))
                folderIDByComparisonKey[key] = folderID
                folderIDsByProfileIndex.append(folderID)
            }
            nextOrganization.addFolders(newFolders)

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
                prepared[index].updatedAt = operationDate
                prepared[index].revision = 1
            }

            let normalizedAllProfiles = try ProfileStore.normalizedForIsolation(
                previousProfiles + prepared
            ).profiles
            let inserted = Array(normalizedAllProfiles.suffix(prepared.count))
            let allProfiles = normalizedAllProfiles.sorted(
                by: ProfileListProjection.areInIncreasingOrder
            )
            guard inserted.count == prepared.count else {
                throw NeAntikError.invalidProfile
            }
            for (profile, folderID) in zip(
                inserted,
                folderIDsByProfileIndex
            ) {
                if let folderID {
                    nextOrganization.assign(
                        profileIDs: [profile.id],
                        toFolderID: folderID
                    )
                }
            }
            if nextOrganization != previousOrganization {
                // An import is a metadata mutation even when it only adds
                // folders for new profiles. Advance the revision so Undo in
                // another manager window cannot accept a stale snapshot.
                nextOrganization.mutationRevision = UUID()
            }

            var createdDirectories: [URL] = []
            do {
                for profile in inserted {
                    let directory = paths.profileDirectory(for: profile.id)
                    guard try paths.privateFileEntryKind(directory) == .missing
                    else {
                        throw NeAntikError.invalidProfile
                    }
                    // Register before preparation: if creating BrowserData
                    // fails after the profile directory itself was created,
                    // the rollback still knows which new directory to clean.
                    createdDirectories.append(directory)
                    try paths.prepareProfileDirectories(for: profile.id)
                }

                try persistProfiles(allProfiles, paths: paths)
                if nextOrganization != previousOrganization {
                    try beforeOrganizationPersist()
                    try persistOrganization(
                        nextOrganization,
                        paths: paths,
                        knownProfileIDs: Set(allProfiles.map(\.id))
                    )
                }
            } catch {
                let operationError = error
                var rollbackError: Error?
                do {
                    try persistProfiles(
                        previousProfiles,
                        paths: paths,
                        synchronizeRecoverySnapshot: true
                    )
                } catch {
                    rollbackError = error
                }
                do {
                    try persistOrganization(
                        previousOrganization,
                        paths: paths,
                        knownProfileIDs: Set(previousProfiles.map(\.id)),
                        synchronizeRecoverySnapshot: true
                    )
                } catch {
                    if rollbackError == nil { rollbackError = error }
                }
                do {
                    try removeCreatedDirectories(createdDirectories, paths: paths)
                } catch {
                    if rollbackError == nil { rollbackError = error }
                }
                if let rollbackError {
                    throw ProfileSaveRollbackError(
                        operationError: operationError,
                        rollbackError: rollbackError
                    )
                }
                throw operationError
            }

            let warning = [profileLoad.warning, organizationLoad.warning]
                .compactMap { $0 }
                .joined(separator: "\n")
            return ProfileMetadataImportResult(
                insertedProfiles: inserted,
                profiles: allProfiles,
                organization: nextOrganization,
                profileMetadataRecovered: profileLoad.recovered,
                folderMetadataRecovered: organizationLoad.recovered,
                warning: warning.isEmpty ? nil : warning
            )
        }
    }

    private static func persistProfiles(
        _ profiles: [BrowserProfile],
        paths: AppPaths,
        synchronizeRecoverySnapshot: Bool = false
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes
        ]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        if synchronizeRecoverySnapshot {
            try paths.writePrivateFile(data, to: paths.profilesBackupFile)
            try paths.writePrivateFile(data, to: paths.profilesFile)
            return
        }
        if FileManager.default.fileExists(atPath: paths.profilesFile.path) {
            try paths.validatePrivateFile(paths.profilesFile)
            let previousData = try Data(contentsOf: paths.profilesFile)
            _ = try ProfileStore.readProfiles(from: paths.profilesFile)
            try paths.writePrivateFile(
                previousData,
                to: paths.profilesBackupFile
            )
        } else {
            try paths.writePrivateFile(data, to: paths.profilesBackupFile)
        }
        try paths.writePrivateFile(data, to: paths.profilesFile)
    }

    private static func persistOrganization(
        _ state: ProfileOrganizationState,
        paths: AppPaths,
        knownProfileIDs: Set<UUID>,
        synchronizeRecoverySnapshot: Bool = false
    ) throws {
        let data = try ProfileStore.encodeOrganization(state)
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
        switch try paths.privateFileEntryKind(paths.profileOrganizationFile) {
        case .regular:
            try paths.validatePrivateFile(paths.profileOrganizationFile)
            let oldData = try Data(contentsOf: paths.profileOrganizationFile)
            _ = try ProfileStore.decodeOrganization(
                oldData,
                knownProfileIDs: knownProfileIDs
            )
            try paths.writePrivateFile(
                oldData,
                to: paths.profileOrganizationBackupFile
            )
        case .missing:
            try paths.writePrivateFile(
                try ProfileStore.encodeOrganization(.empty),
                to: paths.profileOrganizationBackupFile
            )
        case .unsafe:
            throw POSIXError(.EFTYPE)
        }
        try paths.writePrivateFile(data, to: paths.profileOrganizationFile)
    }

    private static func removeCreatedDirectories(
        _ directories: [URL],
        paths: AppPaths
    ) throws {
        for directory in directories.reversed() {
            guard let identity = try paths.privateFileEntryIdentity(directory)
            else { continue }
            guard (identity.mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw POSIXError(.EFTYPE)
            }
            try FileManager.default.removeItem(at: directory)
        }
    }
}

struct ProfileMetadataMutationInProgressError: LocalizedError {
    var errorDescription: String? {
        "Импорт профилей ещё сохраняется. Повтори действие через мгновение."
    }
}
