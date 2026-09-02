import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ProfileStoreTests {
    @Test
    func rejectsUnsafeOrOversizedProfileNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)

        #expect(throws: NeAntikError.self) {
            try store.upsert(BrowserProfile(name: "строка\nвторая"))
        }
        #expect(throws: NeAntikError.self) {
            try store.upsert(
                BrowserProfile(
                    name: String(
                        repeating: "д",
                        count: BrowserProfile.maximumNameLength + 1
                    )
                )
            )
        }
    }

    @Test
    func persistsProfilesAndCreatesPrivateDataDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let profile = BrowserProfile(name: "Persistent")
        try store.upsert(profile)

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profiles.count == 1)
        #expect(reloaded.profiles.first?.id == profile.id)
        #expect(reloaded.profiles.first?.name == profile.name)
        #expect(reloaded.profiles.first?.identity == profile.identity)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.browserDataDirectory(for: profile.id).path
            )
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: paths.profilesFile.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: paths.browserDataDirectory(for: profile.id).path
        )
        #expect(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue ==
                0o600
        )
        #expect(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ==
                    0o700
        )
        let document = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: paths.profilesFile)
            ) as? [String: Any]
        )
        #expect(document["schemaVersion"] as? Int == 1)
        #expect((document["profiles"] as? [[String: Any]])?.count == 1)
    }

    @Test
    func legacyProfileArrayMigratesToVersionedDocument() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profile = BrowserProfile(name: "Legacy document")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode([profile])
        try paths.writePrivateFile(
            legacyData,
            to: paths.profilesFile
        )

        let store = ProfileStore(paths: paths)

        #expect(store.hasTrustedMetadata)
        #expect(store.profiles.map(\.id) == [profile.id])
        let migrated = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: paths.profilesFile)
            ) as? [String: Any]
        )
        #expect(migrated["schemaVersion"] as? Int == 1)
        #expect((migrated["profiles"] as? [[String: Any]])?.count == 1)
        let downgradeRecovery = try paths.readPrivateFile(
            paths.profilesBackupFile,
            maximumBytes: ProfileStore.maximumProfilesMetadataBytes
        )
        #expect(downgradeRecovery == legacyData)
        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .iso8601
        let legacyProfiles = try legacyDecoder.decode(
            [BrowserProfile].self,
            from: downgradeRecovery
        )
        #expect(legacyProfiles.map(\.id) == [profile.id])
    }

    @Test
    func unknownProfileDocumentSchemaFailsClosedWithoutRewrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let unsupported = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 999,
                "profiles": "must-not-be-decoded",
            ]
        )
        try paths.writePrivateFile(unsupported, to: paths.profilesFile)

        let store = ProfileStore(paths: paths)

        #expect(!store.hasTrustedMetadata)
        #expect(store.profiles.isEmpty)
        #expect(try Data(contentsOf: paths.profilesFile) == unsupported)
        #expect(store.lastError?.contains("не поддерживается") == true)
    }

    @Test
    func oversizedProfileDocumentFailsBeforeDecode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        try paths.createPrivateFileExclusively(
            Data(),
            at: paths.profilesFile
        )
        let handle = try FileHandle(forWritingTo: paths.profilesFile)
        try handle.truncate(
            atOffset: UInt64(ProfileStore.maximumProfilesMetadataBytes + 1)
        )
        try handle.close()

        let store = ProfileStore(paths: paths)

        #expect(ProfileStore.maximumProfilesMetadataBytes == 128 * 1_024 * 1_024)
        #expect(!store.hasTrustedMetadata)
        #expect(store.profiles.isEmpty)
    }

    @Test
    func profileDocumentAndRecoveryUseExplicitSymmetricByteBoundaries() {
        #expect(
            ProfilesMetadataStorage.encodedByteCountIsAllowed(
                ProfilesMetadataStorage.maximumBytes
            )
        )
        #expect(
            !ProfilesMetadataStorage.encodedByteCountIsAllowed(
                ProfilesMetadataStorage.maximumBytes + 1
            )
        )
        #expect(
            ProfileRecoveryRetention.shouldPreserveRejectedFile(
                byteCount: Int(ProfileRecoveryRetention.maximumTotalBytes)
            )
        )
        #expect(
            !ProfileRecoveryRetention.shouldPreserveRejectedFile(
                byteCount:
                    Int(ProfileRecoveryRetention.maximumTotalBytes) + 1
            )
        )
    }

    @Test
    func recoveryRetentionDeletesOnlyManagedRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var recentFiles: [URL] = []
        for index in 0..<(ProfileRecoveryRetention.maximumFileCount + 2) {
            let file = paths.profilesRecoveryDirectory.appendingPathComponent(
                "profiles-rejected-\(UUID().uuidString).json"
            )
            try Data("recovery-\(index)".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-Double(index))],
                ofItemAtPath: file.path
            )
            recentFiles.append(file)
        }
        let expired = paths.profilesRecoveryDirectory.appendingPathComponent(
            "profile-organization-rejected-\(UUID().uuidString).json"
        )
        try Data("expired".utf8).write(to: expired)
        try FileManager.default.setAttributes(
            [
                .modificationDate:
                    now.addingTimeInterval(
                        -ProfileRecoveryRetention.maximumAge - 1
                    )
            ],
            ofItemAtPath: expired.path
        )
        let oversized = paths.profilesRecoveryDirectory.appendingPathComponent(
            "profiles-rejected-\(UUID().uuidString).json"
        )
        try Data().write(to: oversized)
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(
            atOffset: UInt64(ProfileRecoveryRetention.maximumTotalBytes + 1)
        )
        try oversizedHandle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(60)],
            ofItemAtPath: oversized.path
        )
        let unrelated = paths.profilesRecoveryDirectory
            .appendingPathComponent("user-notes.json")
        try Data("keep".utf8).write(to: unrelated)
        let outside = root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        let symlink = paths.profilesRecoveryDirectory.appendingPathComponent(
            "profiles-rejected-\(UUID().uuidString).json"
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: outside
        )

        try ProfileRecoveryRetention.prune(
            directory: paths.profilesRecoveryDirectory,
            preserving: oversized,
            now: now
        )

        let retainedRecent = recentFiles.count {
            FileManager.default.fileExists(atPath: $0.path)
        }
        #expect(retainedRecent == ProfileRecoveryRetention.maximumFileCount)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(!FileManager.default.fileExists(atPath: oversized.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: symlink.path
            ) == outside.path
        )
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test
    func markingLaunchDoesNotRewriteLastUserModificationDate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let editedAt = Date(timeIntervalSince1970: 1_000)
        let profile = try store.upsert(
            BrowserProfile(
                name: "Recency",
                createdAt: editedAt,
                updatedAt: editedAt
            )
        )
        let reloaded = ProfileStore(paths: paths)
        let beforeLaunch = try #require(
            reloaded.profile(withID: profile.id)
        )

        #expect(reloaded.markLaunched(profile.id))
        let launched = try #require(reloaded.profile(withID: profile.id))
        #expect(launched.lastLaunchedAt != nil)
        #expect(launched.updatedAt == beforeLaunch.updatedAt)
        #expect(launched.revision == beforeLaunch.revision + 1)
    }

    @Test
    func legacyZWJMetadataReloadsAndSurvivesSubsequentUpdate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()

        let family = "👨‍👩‍👧‍👦"
        let name = String(
            repeating: family,
            count: BrowserProfile.maximumNameLength
        )
        let tag = String(
            repeating: family,
            count: BrowserProfile.maximumTagLength
        )
        let username = String(repeating: family, count: 512)
        let urlPrefix = "https://example.com/?legacy="
        let startURL = urlPrefix + String(
            repeating: "a",
            count: 8 * 1_024 - urlPrefix.utf8.count
        )
        let profile = BrowserProfile(
            name: name,
            tags: [tag],
            startURL: startURL,
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8_080,
                username: username
            ),
            identity: BrowserIdentity(seed: 777)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode([profile])
        guard var legacyJSON = try JSONSerialization.jsonObject(with: encoded)
            as? [[String: Any]]
        else {
            Issue.record("Could not create legacy compatibility fixture")
            return
        }
        legacyJSON[0].removeValue(forKey: "note")
        legacyJSON[0].removeValue(forKey: "revision")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        try paths.writePrivateFile(legacyData, to: paths.profilesFile)

        let store = ProfileStore(paths: paths)
        #expect(store.hasTrustedMetadata)
        #expect(store.profile(withID: profile.id)?.name == name)
        #expect(store.profile(withID: profile.id)?.tags == [tag])
        #expect(store.profile(withID: profile.id)?.startURL == startURL)
        #expect(store.profile(withID: profile.id)?.proxy?.username == username)

        let updated = try store.mutateProfile(withID: profile.id) {
            $0.isPinned = true
        }
        let reloaded = ProfileStore(paths: paths)

        #expect(updated.isPinned)
        #expect(updated.revision == 1)
        #expect(reloaded.profile(withID: profile.id)?.name == name)
        #expect(reloaded.profile(withID: profile.id)?.tags == [tag])
        #expect(reloaded.profile(withID: profile.id)?.startURL == startURL)
        #expect(
            reloaded.profile(withID: profile.id)?.proxy?.username == username
        )
    }

    @Test
    func tenThousandProfileStartupAndLaunchMarkerStayWithinMeasuredBudget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profiles = (0..<10_000).map { index in
            BrowserProfile(
                name: String(format: "Profile %05d", index),
                tags: ["Scale", "Cohort \(index % 100)"],
                note: "Startup benchmark note \(index)",
                identity: BrowserIdentity(seed: UInt32(index + 1))
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(profiles),
            to: paths.profilesFile
        )

        let startupStartedAt = Date()
        let store = ProfileStore(paths: paths)
        let startupElapsed = Date().timeIntervalSince(startupStartedAt)
        let markerStartedAt = Date()
        let didMarkLaunched = store.markLaunched(profiles[5_000].id)
        let markerElapsed = Date().timeIntervalSince(markerStartedAt)
        let startupBudget: TimeInterval = _isDebugAssertConfiguration() ? 8 : 4
        let markerBudget: TimeInterval = _isDebugAssertConfiguration() ? 12 : 6

        print(
            "ProfileStore 10k benchmark: " +
                "startup=\(startupElapsed)s, " +
                "markLaunched=\(markerElapsed)s"
        )
        #expect(store.profiles.count == 10_000)
        #expect(didMarkLaunched)
        #expect(startupElapsed < startupBudget)
        #expect(markerElapsed < markerBudget)

        let overflow = BrowserProfile(name: "Profile overflow")
        #expect(throws: NeAntikError.self) {
            try store.upsert(overflow)
        }
        #expect(throws: NeAntikError.self) {
            try store.insertNewProfiles(
                [overflow],
                afterPersist: { _ in }
            )
        }
        #expect(store.profiles.count == ProfileStorageLimits.maximumProfileCount)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: overflow.id).path
            )
        )
    }

    @Test
    func noteIsNormalizedPersistedAndReloaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        var profile = BrowserProfile(name: "Заметка")
        profile.note = "  Первая строка\r\n\rВторая строка  "

        let saved = try store.upsert(profile)
        let reloaded = ProfileStore(paths: paths)

        #expect(saved.note == "Первая строка\n\nВторая строка")
        #expect(reloaded.profile(withID: saved.id)?.note == saved.note)
    }

    @Test
    func invalidNoteIsRejectedBySingleAndBulkWritePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        var invalid = BrowserProfile(name: "Слишком длинная заметка")
        invalid.note = String(
            repeating: "н",
            count: BrowserProfile.maximumNoteLength + 1
        )

        #expect(throws: NeAntikError.self) {
            try store.upsert(invalid)
        }
        #expect(throws: NeAntikError.self) {
            try store.insertNewProfiles(
                [invalid],
                afterPersist: { _ in }
            )
        }
        #expect(store.profiles.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: invalid.id).path
            )
        )
    }

    @Test
    func centralizedPersistenceValidationRejectsEveryWritePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        var invalidProfiles: [BrowserProfile] = []

        var invalidColor = BrowserProfile(name: "Invalid color")
        invalidColor.colorHex = "not-a-color"
        invalidProfiles.append(invalidColor)

        var invalidURL = BrowserProfile(name: "Invalid URL")
        invalidURL.startURL = "file:///tmp/private"
        invalidProfiles.append(invalidURL)

        var invalidProxy = BrowserProfile(name: "Invalid proxy")
        invalidProxy.proxy = ProxyConfiguration(
            kind: .http,
            host: "proxy.example",
            port: 0,
            username: "user"
        )
        invalidProfiles.append(invalidProxy)

        for invalid in invalidProfiles {
            #expect(throws: NeAntikError.self) {
                try store.upsert(invalid)
            }
            #expect(throws: NeAntikError.self) {
                try store.insertNewProfiles(
                    [invalid],
                    afterPersist: { _ in }
                )
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: paths.profileDirectory(for: invalid.id).path
                )
            )
        }
        #expect(store.profiles.isEmpty)
    }

    @Test
    func validExistingMetadataCreatesRecoverySnapshotOnFirstLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profile = BrowserProfile(name: "До первого изменения")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validData = try encoder.encode([profile])
        try paths.writePrivateFile(validData, to: paths.profilesFile)

        let firstLoad = ProfileStore(paths: paths)
        #expect(firstLoad.profile(withID: profile.id) != nil)
        #expect(
            try Data(contentsOf: paths.profilesBackupFile) == validData
        )

        try paths.writePrivateFile(
            Data("{not-json".utf8),
            to: paths.profilesFile
        )
        let recovered = ProfileStore(paths: paths)
        #expect(recovered.profile(withID: profile.id) != nil)
        #expect(recovered.lastError?.contains("восстановил") == true)
    }

    @Test
    func migratesLegacyProfileToStableIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profile = BrowserProfile(name: "Legacy")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode([profile])
        guard var array = try JSONSerialization.jsonObject(with: encoded)
            as? [[String: Any]]
        else {
            Issue.record("Could not create legacy fixture")
            return
        }
        array[0].removeValue(forKey: "identity")
        let legacyData = try JSONSerialization.data(withJSONObject: array)
        try legacyData.write(to: paths.profilesFile)

        let firstLoad = ProfileStore(paths: paths)
        let secondLoad = ProfileStore(paths: paths)

        let expected = BrowserIdentity.migrated(profileID: profile.id)
        #expect(firstLoad.profiles.first?.identity == expected)
        #expect(secondLoad.profiles.first?.identity == expected)
    }

    @Test
    func rollsBackMemoryWhenProfilePersistenceFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        try FileManager.default.createDirectory(
            at: paths.profilesFile,
            withIntermediateDirectories: false
        )

        let profile = BrowserProfile(name: "Must not remain")
        #expect(throws: (any Error).self) {
            try store.upsert(profile)
        }
        #expect(store.profiles.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )
        )
    }

    @Test
    func rollsBackNewProfileWhenFollowupSaveFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let profile = BrowserProfile(name: "Credential failure")

        #expect(throws: (any Error).self) {
            try store.upsert(profile) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(store.profiles.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )
        )
        #expect(ProfileStore(paths: paths).profiles.isEmpty)
    }

    @Test
    func failedNewCredentialRollbackCreatesDurableCleanupMarkers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let backend = ProfileSaveRollbackKeychainBackend()
        backend.failingDeleteServices = [
            KeychainStore.currentService,
            KeychainStore.legacyService,
        ]
        let keychain = KeychainStore(backend: backend)
        let profile = BrowserProfile(name: "Credential rollback")

        #expect(throws: KeychainNewCredentialRollbackError.self) {
            try store.upsert(profile, toFolderID: nil) { saved in
                try keychain.saveProxyPassword(
                    "orphaned-until-recovery",
                    profileID: saved.id
                )
            }
        }

        #expect(store.profile(withID: profile.id) == nil)
        #expect(
            try paths.privateFileEntryKind(
                paths.profileDirectory(for: profile.id)
            ) == .missing
        )
        #expect(
            try paths.privateFileEntryKind(
                paths.profileDeletionTombstone(for: profile.id)
            ) == .regular
        )
        #expect(
            try paths.privateFileEntryKind(
                paths.profileCredentialCleanupMarker(for: profile.id)
            ) == .regular
        )
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profile.id
            ) == "orphaned-until-recovery"
        )
    }

    @Test
    func restoresExistingMetadataWithoutRemovingBrowserData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(
            BrowserProfile(name: "Original")
        )
        let marker = paths.browserDataDirectory(for: original.id)
            .appendingPathComponent("session-marker")
        try Data("keep".utf8).write(to: marker)

        var edited = original
        edited.name = "Edited"
        #expect(throws: (any Error).self) {
            try store.upsert(edited) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }

        #expect(store.profile(withID: original.id)?.name == "Original")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profile(withID: original.id)?.name == "Original")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func credentialCleanupFailureNeverResurrectsDeletedProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let localTrash = root.appendingPathComponent(
            "CommittedTrash",
            isDirectory: true
        )
        let store = ProfileStore(
            paths: paths,
            trashDirectory: { source in
                try FileManager.default.moveItem(
                    at: source,
                    to: localTrash
                )
                return localTrash
            }
        )
        let profile = try store.upsert(
            BrowserProfile(name: "Keep after credential failure")
        )
        let folder = try store.createFolder(named: "Deleted profile folder")
        try store.assignProfile(profile.id, toFolderID: folder.id)
        let marker = paths.browserDataDirectory(for: profile.id)
            .appendingPathComponent("session-marker")
        try Data("keep".utf8).write(to: marker)
        let backend = ProfileDeleteKeychainBackend()
        backend.set(
            "current-secret",
            service: KeychainStore.currentService,
            profileID: profile.id
        )
        backend.set(
            "legacy-secret",
            service: KeychainStore.legacyService,
            profileID: profile.id
        )
        backend.deleteFailureService = KeychainStore.legacyService
        let keychain = KeychainStore(backend: backend)
        let processManager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )

        let outcome = try store.delete(
            profile,
            processManager: processManager
        ) { _ in
            try keychain.deleteProxyPassword(profileID: profile.id)
        }

        #expect(outcome == .credentialCleanupPending)
        #expect(outcome.warningDescription?.contains("уже удалены") == true)
        #expect(store.profile(withID: profile.id) == nil)
        #expect(store.folderID(forProfileID: profile.id) == nil)
        #expect(store.folder(withID: folder.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(
            FileManager.default.fileExists(
                atPath: localTrash.appendingPathComponent(
                    "BrowserData/session-marker"
                ).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: paths.profileDeletionTombstone(
                    for: profile.id
                ).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: paths.profileCredentialCleanupMarker(
                    for: profile.id
                ).path
            )
        )
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profile.id
            ) == nil
        )
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profile.id
            ) == "legacy-secret"
        )
        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profile(withID: profile.id) == nil)
        #expect(reloaded.folderID(forProfileID: profile.id) == nil)
        #expect(reloaded.folder(withID: folder.id) != nil)
        #expect(throws: BrowserProfileDeletedError.self) {
            try reloaded.upsert(profile)
        }
    }

    @Test
    func deletionTombstoneBlocksStaleLaunchAndMarkLaunched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let localTrash = root.appendingPathComponent(
            "TestTrash",
            isDirectory: true
        )
        let trash: (URL) throws -> URL = { source in
            try FileManager.default.createDirectory(
                at: localTrash,
                withIntermediateDirectories: true
            )
            let destination = localTrash.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            try FileManager.default.moveItem(
                at: source,
                to: destination
            )
            return destination
        }
        let restore: (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(
                at: source,
                to: destination
            )
        }
        let deletingStore = ProfileStore(
            paths: paths,
            trashDirectory: trash,
            restoreTrashedDirectory: restore
        )
        let profile = try deletingStore.upsert(
            BrowserProfile(name: "Deleted elsewhere")
        )
        let staleStore = ProfileStore(
            paths: paths,
            trashDirectory: trash,
            restoreTrashedDirectory: restore
        )
        let processManager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )

        try deletingStore.delete(
            profile,
            processManager: processManager
        ) { _ in }
        #expect(
            try paths.privateFileEntryKind(
                paths.profileCredentialCleanupMarker(for: profile.id)
            ) == .missing
        )

        let staleManager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let runtime = BrowserRuntime(
            name: "Never launched",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            source: "Test"
        )
        #expect(throws: NeAntikError.self) {
            try staleManager.launch(profile: profile, runtime: runtime)
        }
        staleStore.markLaunched(profile.id)
        #expect(staleStore.profile(withID: profile.id) == nil)
        #expect(staleStore.lastError == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.profileDeletionTombstone(
                    for: profile.id
                ).path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )
        )
        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profile(withID: profile.id) == nil)
    }

    @Test
    func staleUnrelatedMutationReloadsAndMergesLatestMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let initialStore = ProfileStore(paths: paths)
        let first = try initialStore.upsert(
            BrowserProfile(name: "First")
        )
        let staleStore = ProfileStore(paths: paths)
        let freshStore = ProfileStore(paths: paths)
        let second = try freshStore.upsert(
            BrowserProfile(name: "Second")
        )
        var editedFirst = first
        editedFirst.name = "First edited"

        _ = try staleStore.upsert(editedFirst)

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profiles.count == 2)
        #expect(reloaded.profile(withID: first.id)?.name == "First edited")
        #expect(reloaded.profile(withID: second.id)?.name == "Second")
    }

    @Test
    func unknownTrashLocationLeavesTombstoneAndBlocksLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let hiddenRecovery = root.appendingPathComponent(
            "HiddenRecovery",
            isDirectory: true
        )
        let store = ProfileStore(
            paths: paths,
            trashDirectory: { source in
                try FileManager.default.moveItem(
                    at: source,
                    to: hiddenRecovery
                )
                throw ProfileStoreTestError()
            }
        )
        let profile = try store.upsert(
            BrowserProfile(name: "Unknown Trash result")
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )

        do {
            try store.delete(
                profile,
                processManager: manager,
                credentialCleanup: { _ in }
            )
            Issue.record("Удаление должно было завершиться ошибкой")
        } catch let error as ProfileDeleteRollbackError {
            #expect(error.rollbackError != nil)
            #expect(error.recoveryTrashURL == nil)
            #expect(!error.localizedDescription.contains(root.path))
        }

        #expect(FileManager.default.fileExists(atPath: hiddenRecovery.path))
        #expect(
            FileManager.default.fileExists(
                atPath: paths.profileDeletionTombstone(
                    for: profile.id
                ).path
            )
        )
        let runtime = BrowserRuntime(
            name: "Never launched",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            source: "Test"
        )
        #expect(throws: NeAntikError.self) {
            try manager.launch(profile: profile, runtime: runtime)
        }
        manager.reconcile(profiles: [profile])
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
    }

    @Test
    func failedTrashRestoreReportsRecoveryLocationAndKeepsBlocked()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let knownTrash = root.appendingPathComponent(
            "KnownTrash",
            isDirectory: true
        )
        let store = ProfileStore(
            paths: paths,
            trashDirectory: { source in
                try FileManager.default.moveItem(
                    at: source,
                    to: knownTrash
                )
                return knownTrash
            },
            restoreTrashedDirectory: { _, _ in
                throw ProfileStoreTestError()
            },
            afterDeleteMetadataPersist: {
                throw ProfileStoreTestError()
            }
        )
        let profile = try store.upsert(
            BrowserProfile(name: "Restore failure")
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )

        do {
            try store.delete(
                profile,
                processManager: manager,
                credentialCleanup: { _ in }
            )
            Issue.record("Откат должен был завершиться ошибкой")
        } catch let error as ProfileDeleteRollbackError {
            #expect(error.rollbackError != nil)
            #expect(error.recoveryTrashURL == knownTrash)
            #expect(!error.localizedDescription.contains(root.path))
        }

        #expect(FileManager.default.fileExists(atPath: knownTrash.path))
        #expect(
            FileManager.default.fileExists(
                atPath: paths.profileDeletionTombstone(
                    for: profile.id
                ).path
            )
        )
        #expect(
            try paths.privateFileEntryKind(
                paths.profileCredentialCleanupMarker(for: profile.id)
            ) == .missing
        )
        let runtime = BrowserRuntime(
            name: "Never launched",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            source: "Test"
        )
        #expect(throws: NeAntikError.self) {
            try manager.launch(profile: profile, runtime: runtime)
        }
        manager.reconcile(profiles: [profile])
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
    }

    @Test
    func corruptMetadataFailsClosedWithoutOverwritingOrCreatingData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let corruptData = Data("{ definitely-not-json".utf8)
        try paths.writePrivateFile(corruptData, to: paths.profilesFile)

        let store = ProfileStore(paths: paths)
        #expect(store.profiles.isEmpty)
        #expect(store.lastError != nil)
        let attempted = BrowserProfile(name: "Must not overwrite")

        #expect(throws: (any Error).self) {
            try store.upsert(attempted)
        }
        #expect(try Data(contentsOf: paths.profilesFile) == corruptData)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: attempted.id).path
            )
        )
    }

    @Test
    func recoversPreviousRevisionWithoutTouchingBrowserData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(
            BrowserProfile(name: "Previous revision")
        )
        let marker = paths.browserDataDirectory(for: original.id)
            .appendingPathComponent("session-marker")
        try Data("keep".utf8).write(to: marker)

        var edited = original
        edited.name = "Newest revision"
        _ = try store.upsert(edited)
        let corruptData = Data("{ partial-write".utf8)
        try paths.writePrivateFile(corruptData, to: paths.profilesFile)

        let recovered = ProfileStore(paths: paths)

        #expect(
            recovered.profile(withID: original.id)?.name ==
                "Previous revision"
        )
        #expect(recovered.lastError?.contains("Recovery") == true)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: paths.profilesRecoveryDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(recoveryFiles.count == 1)
        #expect(try Data(contentsOf: recoveryFiles[0]) == corruptData)
        let backupMode = try FileManager.default.attributesOfItem(
            atPath: paths.profilesBackupFile.path
        )[.posixPermissions] as? NSNumber
        let rejectedMode = try FileManager.default.attributesOfItem(
            atPath: recoveryFiles[0].path
        )[.posixPermissions] as? NSNumber
        #expect(backupMode?.intValue == 0o600)
        #expect(rejectedMode?.intValue == 0o600)
    }

    @Test
    func symlinkedRecoverySnapshotBlocksProfileOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(BrowserProfile(name: "Original"))
        try FileManager.default.removeItem(at: paths.profilesBackupFile)
        let protectedData = Data("outside".utf8)
        try protectedData.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.profilesBackupFile,
            withDestinationURL: outside
        )

        var edited = original
        edited.name = "Must not persist"
        #expect(throws: (any Error).self) {
            try store.upsert(edited)
        }

        #expect(store.profile(withID: original.id)?.name == "Original")
        #expect(try Data(contentsOf: outside) == protectedData)
    }

    @Test
    func rejectsSymlinkedProfileDirectoryWithoutWritingOutsideRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let profileID = UUID()
        try FileManager.default.createSymbolicLink(
            at: paths.profileDirectory(for: profileID),
            withDestinationURL: outside
        )

        #expect(throws: (any Error).self) {
            try paths.prepareProfileDirectories(for: profileID)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: outside
                    .appendingPathComponent("BrowserData")
                    .path
            )
        )
    }

    @Test
    func symlinkedProfilesFileFailsClosedWithoutChangingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let protectedData = Data("outside".utf8)
        try protectedData.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.profilesFile,
            withDestinationURL: outside
        )

        let store = ProfileStore(paths: paths)
        #expect(store.lastError != nil)
        #expect(throws: (any Error).self) {
            try store.upsert(BrowserProfile(name: "Blocked"))
        }
        #expect(try Data(contentsOf: outside) == protectedData)
    }

    @Test
    func symlinkInsertedBeforeMutationCannotReplaceInMemorySnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let saved = try store.upsert(BrowserProfile(name: "Trusted"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let outsideData = try encoder.encode([
            BrowserProfile(name: "Injected")
        ])
        try outsideData.write(to: outside)
        try FileManager.default.removeItem(at: paths.profilesFile)
        try FileManager.default.createSymbolicLink(
            at: paths.profilesFile,
            withDestinationURL: outside
        )

        #expect(throws: (any Error).self) {
            try store.mutateProfile(withID: saved.id) {
                $0.name = "Must not commit"
            }
        }
        #expect(store.profiles == [saved])
        #expect(try Data(contentsOf: outside) == outsideData)
    }

    @Test
    func rejectsFingerprintSeedCollisionsOnUpsert() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        let first = try store.upsert(
            BrowserProfile(
                name: "First",
                identity: BrowserIdentity(seed: 42)
            )
        )
        let second = try store.upsert(
            BrowserProfile(
                name: "Second",
                identity: BrowserIdentity(seed: 42)
            )
        )

        #expect(first.identity.seed == 42)
        #expect(second.identity.seed == 53)
        #expect(
            first.identity.deviceTupleID ==
                second.identity.deviceTupleID
        )
        #expect(
            second.identity.issuanceVersion ==
                BrowserIdentityIssuancePolicy.legacyVersion
        )
        #expect(
            Set(store.profiles.map(\.identity.seed)).count ==
                store.profiles.count
        )

        let reloaded = ProfileStore(paths: AppPaths(rootDirectory: root))
        #expect(
            Set(reloaded.profiles.map(\.identity.seed)).count ==
                reloaded.profiles.count
        )
        #expect(
            reloaded.profile(withID: second.id)?.identity.seed == 53
        )
    }

    @Test
    func currentIssuanceCollisionStaysInTheSameReviewedCohort() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        let identity = BrowserIdentity()
        let first = try store.upsert(
            BrowserProfile(name: "First current", identity: identity)
        )
        let second = try store.upsert(
            BrowserProfile(name: "Second current", identity: identity)
        )
        let tupleCount = UInt32(BrowserIdentityCatalog.tupleIDs.count)
        let residue = identity.seed % tupleCount
        let wrappedSeed = residue == 0 ? tupleCount : residue
        let expectedSecondSeed =
            identity.seed <= BrowserIdentity.maximumRuntimeSeed - tupleCount
                ? identity.seed + tupleCount
                : wrappedSeed

        #expect(first.identity.seed == identity.seed)
        #expect(second.identity.seed == expectedSecondSeed)
        #expect(first.identity.seed != second.identity.seed)
        #expect(
            first.identity.deviceTupleID ==
                second.identity.deviceTupleID
        )
        #expect(
            second.identity.issuanceVersion ==
                BrowserIdentityIssuancePolicy.currentVersion
        )
        #expect(
            BrowserIdentityIssuancePolicy.isCurrentSeed(
                second.identity.seed
            )
        )

        let reloaded = ProfileStore(paths: AppPaths(rootDirectory: root))
        #expect(reloaded.lastError == nil)
        #expect(
            reloaded.profile(withID: second.id)?.identity ==
                second.identity
        )
    }

    @Test
    func editingProxyContextPreservesCurrentIssuance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        let original = try store.upsert(
            BrowserProfile(name: "Current identity")
        )
        var edited = original
        edited.identity = edited.identity.replacingProxyContext(
            timezoneIdentifier: "Europe/Berlin",
            localeIdentifier: "de-DE",
            evidence: .ipAPI(
                observedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let saved = try store.upsert(edited)

        #expect(saved.identity.seed == original.identity.seed)
        #expect(
            saved.identity.deviceTupleID ==
                original.identity.deviceTupleID
        )
        #expect(
            saved.identity.issuanceVersion ==
                BrowserIdentityIssuancePolicy.currentVersion
        )
    }

    @Test
    func repairsDuplicateIDsAndSeedsFromPersistedProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let sharedID = UUID()
        let profiles = [
            BrowserProfile(
                id: sharedID,
                name: "First",
                identity: BrowserIdentity(seed: 100)
            ),
            BrowserProfile(
                id: sharedID,
                name: "Second",
                identity: BrowserIdentity(seed: 100)
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(profiles),
            to: paths.profilesFile
        )

        let repaired = ProfileStore(paths: paths)
        #expect(repaired.lastError == nil)
        #expect(repaired.profiles.count == 2)
        #expect(Set(repaired.profiles.map(\.id)).count == 2)
        #expect(Set(repaired.profiles.map(\.identity.seed)).count == 2)

        let secondLoad = ProfileStore(paths: paths)
        #expect(secondLoad.lastError == nil)
        #expect(secondLoad.profiles == repaired.profiles)
    }

    @Test
    func migratesLegacyUnsignedSeedsWithoutRuntimeCollisions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profiles = [
            BrowserProfile(
                name: "Existing low seed",
                identity: BrowserIdentity(seed: 1)
            ),
            BrowserProfile(
                name: "Legacy high collision",
                identity: BrowserIdentity(seed: 2)
            ),
            BrowserProfile(
                name: "Legacy high maximum",
                identity: BrowserIdentity(seed: 3)
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        object[1]["identity"] = [
            "seed": UInt64(Int32.max) + 1
        ]
        object[2]["identity"] = [
            "seed": UInt64(UInt32.max)
        ]
        try paths.writePrivateFile(
            JSONSerialization.data(withJSONObject: object),
            to: paths.profilesFile
        )

        let repaired = ProfileStore(paths: paths)
        let seeds = repaired.profiles.map(\.identity.seed)
        #expect(repaired.lastError == nil)
        #expect(Set(seeds).count == profiles.count)
        #expect(
            seeds.allSatisfy {
                (1...BrowserIdentity.maximumRuntimeSeed).contains($0)
            }
        )

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.lastError == nil)
        #expect(reloaded.profiles == repaired.profiles)
    }

    @Test
    func migratesRealLegacyUnsignedSeedsSeenInCrashReport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profiles = [
            BrowserProfile(name: "Legacy 0.3.7 A"),
            BrowserProfile(name: "Legacy 0.3.7 B")
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        object[0]["identity"] = ["seed": 2_456_110_098]
        object[1]["identity"] = ["seed": 3_454_592_789]
        try paths.writePrivateFile(
            JSONSerialization.data(withJSONObject: object),
            to: paths.profilesFile
        )

        let repaired = ProfileStore(paths: paths)
        #expect(repaired.lastError == nil)
        #expect(
            repaired.profiles.map(\.identity.seed) == [
                308_626_450,
                1_307_109_141
            ]
        )
        #expect(
            repaired.profiles.allSatisfy {
                $0.identity.seed == $0.identity.runtimeSeed
            }
        )

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profiles == repaired.profiles)
    }

    @Test
    func batchMetadataMutationPersistsOnceAndUndoRestoresEveryProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let first = try store.upsert(BrowserProfile(name: "First"))
        let second = try store.upsert(BrowserProfile(name: "Second"))
        let untouched = try store.upsert(BrowserProfile(name: "Untouched"))
        let committedAt = Date(timeIntervalSince1970: 1_000)

        let receipt = try store.applyBatch(
            .setPinned(true),
            to: [first.id, second.id],
            at: committedAt
        )

        #expect(receipt.affectedCount == 2)
        #expect(receipt.canUndo)
        #expect(store.profile(withID: first.id)?.isPinned == true)
        #expect(store.profile(withID: second.id)?.isPinned == true)
        #expect(store.profile(withID: untouched.id)?.isPinned == false)
        #expect(store.profile(withID: first.id)?.updatedAt == committedAt)
        #expect(store.profile(withID: first.id)?.revision == 2)

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profile(withID: first.id)?.isPinned == true)
        #expect(reloaded.profile(withID: second.id)?.isPinned == true)

        let undoneAt = Date(timeIntervalSince1970: 2_000)
        try reloaded.undoBatch(receipt, at: undoneAt)

        #expect(reloaded.profile(withID: first.id)?.isPinned == false)
        #expect(reloaded.profile(withID: second.id)?.isPinned == false)
        #expect(reloaded.profile(withID: untouched.id)?.revision == 1)
        #expect(reloaded.profile(withID: first.id)?.revision == 3)
        #expect(reloaded.profile(withID: first.id)?.updatedAt == undoneAt)
    }

    @Test
    func batchUndoRejectsNewerRevisionWithoutPartialRollback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        let first = try store.upsert(BrowserProfile(name: "First"))
        let second = try store.upsert(BrowserProfile(name: "Second"))
        let receipt = try store.applyBatch(
            .setPinned(true),
            to: [first.id, second.id]
        )
        _ = try store.mutateProfile(withID: first.id) {
            $0.note = "Newer note"
        }

        #expect(throws: ProfileBatchMutationError.self) {
            try store.undoBatch(receipt)
        }
        #expect(store.profile(withID: first.id)?.isPinned == true)
        #expect(store.profile(withID: first.id)?.note == "Newer note")
        #expect(store.profile(withID: second.id)?.isPinned == true)
    }

    @Test
    func batchTagLimitFailureChangesNoProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        let available = try store.upsert(BrowserProfile(name: "Available"))
        let full = try store.upsert(
            BrowserProfile(
                name: "Full",
                tags: (0..<BrowserProfile.maximumTagCount).map {
                    "Tag \($0)"
                }
            )
        )

        #expect(throws: ProfileBatchMutationError.self) {
            try store.applyBatch(
                .addTag("Campaign"),
                to: [available.id, full.id]
            )
        }
        #expect(store.profile(withID: available.id)?.tags.isEmpty == true)
        #expect(
            store.profile(withID: full.id)?.tags.count ==
                BrowserProfile.maximumTagCount
        )
        let reloaded = ProfileStore(paths: store.paths)
        #expect(reloaded.profile(withID: available.id)?.tags.isEmpty == true)
    }

    @Test
    func batchFolderAssignmentCanBeUndoneAndRejectsConflicts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        let first = try store.upsert(BrowserProfile(name: "First"))
        let second = try store.upsert(BrowserProfile(name: "Second"))
        let source = try store.createFolder(named: "Source")
        let target = try store.createFolder(named: "Target")
        try store.assignProfile(first.id, toFolderID: source.id)

        let receipt = try store.assignProfilesRecordingUndo(
            [first.id, second.id],
            toFolderID: target.id
        )
        #expect(receipt.affectedCount == 2)
        #expect(store.folderID(forProfileID: first.id) == target.id)
        #expect(store.folderID(forProfileID: second.id) == target.id)

        try store.undoFolderAssignments(receipt)
        #expect(store.folderID(forProfileID: first.id) == source.id)
        #expect(store.folderID(forProfileID: second.id) == nil)

        let conflictingReceipt = try store.assignProfilesRecordingUndo(
            [first.id, second.id],
            toFolderID: target.id
        )
        try store.assignProfile(second.id, toFolderID: nil)
        #expect(throws: ProfileBatchMutationError.self) {
            try store.undoFolderAssignments(conflictingReceipt)
        }
        #expect(store.folderID(forProfileID: first.id) == target.id)
        #expect(store.folderID(forProfileID: second.id) == nil)
    }
}

private struct ProfileStoreTestError: Error {}

private final class ProfileDeleteKeychainBackend:
    KeychainBackend,
    @unchecked Sendable
{
    var deleteFailureService: String?
    private var values: [String: Data] = [:]

    func data(service: String, profileID: UUID) throws -> Data? {
        values[key(service: service, profileID: profileID)]
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        values[key(service: service, profileID: profileID)] = data
    }

    func delete(service: String, profileID: UUID) throws {
        if deleteFailureService == service {
            throw ProfileStoreTestError()
        }
        values.removeValue(forKey: key(service: service, profileID: profileID))
    }

    func set(_ value: String, service: String, profileID: UUID) {
        values[key(service: service, profileID: profileID)] =
            Data(value.utf8)
    }

    func string(service: String, profileID: UUID) -> String? {
        values[key(service: service, profileID: profileID)]
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private func key(service: String, profileID: UUID) -> String {
        "\(service)|\(profileID.uuidString)"
    }
}

private final class ProfileSaveRollbackKeychainBackend:
    KeychainBackend,
    @unchecked Sendable
{
    var failingDeleteServices = Set<String>()
    private var values: [String: Data] = [:]

    func data(service: String, profileID: UUID) throws -> Data? {
        values[key(service: service, profileID: profileID)]
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        values[key(service: service, profileID: profileID)] = data
    }

    func delete(service: String, profileID: UUID) throws {
        if failingDeleteServices.contains(service) {
            throw ProfileStoreTestError()
        }
        values.removeValue(forKey: key(service: service, profileID: profileID))
    }

    func string(service: String, profileID: UUID) -> String? {
        values[key(service: service, profileID: profileID)]
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private func key(service: String, profileID: UUID) -> String {
        "\(service)|\(profileID.uuidString)"
    }
}
