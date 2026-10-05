import Foundation
import Testing
@testable import NeAntik

struct KeychainStoreTests {
    @Test
    func legacyReadMigratesSecretAndRemovesFallback() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        backend.set(
            "legacy-secret",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        let store = KeychainStore(backend: backend)

        #expect(try store.proxyPassword(profileID: profileID) == "legacy-secret")
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "legacy-secret"
        )
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == nil
        )
    }

    @Test
    func corruptCurrentPreservesValidLegacyCredential() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        let corrupt = Data([0xFF, 0xFE])
        backend.set(
            corrupt,
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.set(
            "legacy-secret",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        let store = KeychainStore(backend: backend)

        #expect(throws: (any Error).self) {
            try store.proxyPassword(profileID: profileID)
        }
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.dataValue(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == corrupt
        )
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == "legacy-secret"
        )
    }

    @Test
    func corruptLegacyCredentialIsNotPromoted() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        let corrupt = Data([0xC3, 0x28])
        backend.set(
            corrupt,
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        let store = KeychainStore(backend: backend)

        #expect(throws: (any Error).self) {
            try store.proxyPassword(profileID: profileID)
        }
        #expect(backend.upsertCallCount == 0)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.dataValue(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == nil
        )
        #expect(
            backend.dataValue(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == corrupt
        )
    }

    @Test
    func saveRemovesAnyLegacySecret() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        backend.set(
            "old",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        let store = KeychainStore(backend: backend)

        try store.saveProxyPassword("new", profileID: profileID)

        #expect(try store.proxyPassword(profileID: profileID) == "new")
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == nil
        )
    }

    @Test
    func failedNewCredentialCompensationCarriesCleanupRecovery() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        backend.deleteFailureServices = [
            KeychainStore.currentService,
            KeychainStore.legacyService,
        ]
        let store = KeychainStore(backend: backend)

        do {
            try store.saveProxyPassword("orphan", profileID: profileID)
            Issue.record("Expected the new credential transaction to fail.")
        } catch let error as KeychainNewCredentialRollbackError {
            #expect(error.profileIDsRequiringCredentialCleanup == [profileID])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "orphan"
        )
    }

    @Test
    func deleteClearsBothNamespaces() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        for service in [
            KeychainStore.currentService,
            KeychainStore.legacyService
        ] {
            backend.set("secret", service: service, profileID: profileID)
        }
        let store = KeychainStore(backend: backend)

        try store.deleteProxyPassword(profileID: profileID)

        #expect(try store.proxyPassword(profileID: profileID) == nil)
    }

    @Test
    func partialPurgeNeverRestoresAlreadyDeletedCurrentSecret() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        backend.set(
            "current",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.set(
            "legacy",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        backend.deleteFailureService = KeychainStore.legacyService
        let store = KeychainStore(backend: backend)

        #expect(throws: KeychainCredentialPurgeError.self) {
            try store.deleteProxyPassword(profileID: profileID)
        }

        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == nil
        )
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == "legacy"
        )
    }

    @Test
    func profileEditDeleteRestoresBothNamespacesAfterPartialFailure() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        backend.set(
            "current",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.set(
            "legacy",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        backend.deleteFailureService = KeychainStore.legacyService
        let store = KeychainStore(backend: backend)

        #expect(throws: MemoryKeychainError.self) {
            try store.updateProxyPasswordForProfileEdit(
                nil,
                profileID: profileID
            )
        }

        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "current"
        )
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == "legacy"
        )
    }

    @Test
    func profileEditReplaceRestoresOldSecretAfterLegacyFailure() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        backend.set(
            "current",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.set(
            "legacy",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        backend.deleteFailureService = KeychainStore.legacyService
        let store = KeychainStore(backend: backend)

        #expect(throws: MemoryKeychainError.self) {
            try store.updateProxyPasswordForProfileEdit(
                "replacement",
                profileID: profileID
            )
        }

        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "current"
        )
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == "legacy"
        )
    }

    @Test
    func profileEditReportsWhenCredentialRollbackAlsoFails() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        backend.set(
            "current",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.set(
            "legacy",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        backend.deleteFailureService = KeychainStore.legacyService
        backend.upsertAlwaysFails = true
        let store = KeychainStore(backend: backend)

        #expect(throws: KeychainProfileEditRollbackError.self) {
            try store.updateProxyPasswordForProfileEdit(
                nil,
                profileID: profileID
            )
        }
    }

    @Test @MainActor
    func existingProfileProxyAssignmentRollsBackMetadataWhenKeychainFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profiles = ProfileStore(paths: paths)
        let original = try profiles.upsert(BrowserProfile(name: "Existing"))
        let persistedBefore = ProfileStore(paths: paths)
            .profile(withID: original.id)
        let browserData = paths.browserDataDirectory(for: original.id)
        let marker = browserData.appendingPathComponent("untouched.txt")
        try Data("keep".utf8).write(to: marker)

        let backend = MemoryKeychainBackend()
        backend.upsertAlwaysFails = true
        let keychain = KeychainStore(backend: backend)
        var edited = original
        edited.proxy = ProxyConfiguration(
            kind: .http,
            host: "proxy.example",
            port: 8080,
            username: "user"
        )

        #expect(throws: MemoryKeychainError.self) {
            try profiles.upsert(edited, toFolderID: nil) { saved in
                try keychain.updateProxyPasswordForProfileEdit(
                    "synthetic-password",
                    profileID: saved.id
                )
            }
        }

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profile(withID: original.id) == persistedBefore)
        #expect(backend.string(
            service: KeychainStore.currentService,
            profileID: original.id
        ) == nil)
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    @Test @MainActor
    func staleExistingProfileProxyAssignmentCannotOverwriteNewerEdit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let firstWindow = ProfileStore(paths: paths)
        let original = try firstWindow.upsert(BrowserProfile(name: "Existing"))
        let secondWindow = ProfileStore(paths: paths)
        var newer = original
        newer.note = "edited elsewhere"
        _ = try secondWindow.upsert(newer)

        var stale = original
        stale.proxy = ProxyConfiguration(
            kind: .http,
            host: "proxy.example",
            port: 8080,
            username: "user"
        )
        var credentialCallbackRan = false
        #expect(throws: BrowserProfileRevisionConflictError.self) {
            try firstWindow.upsert(stale, toFolderID: nil) { _ in
                credentialCallbackRan = true
            }
        }

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profile(withID: original.id)?.note == "edited elsewhere")
        #expect(reloaded.profile(withID: original.id)?.proxy == nil)
        #expect(!credentialCallbackRan)
    }

    @Test @MainActor
    func existingProfileProxyAssignmentPersistsOnlySelectedProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profiles = ProfileStore(paths: paths)
        let selected = try profiles.upsert(BrowserProfile(name: "Selected"))
        let untouched = try profiles.upsert(BrowserProfile(name: "Untouched"))
        let untouchedBefore = ProfileStore(paths: paths)
            .profile(withID: untouched.id)
        let marker = paths.browserDataDirectory(for: selected.id)
            .appendingPathComponent("untouched.txt")
        try Data("keep".utf8).write(to: marker)

        let backend = MemoryKeychainBackend()
        let keychain = KeychainStore(backend: backend)
        var edited = selected
        edited.proxy = ProxyConfiguration(
            kind: .http,
            host: "proxy.example",
            port: 8080,
            username: "user"
        )
        let saved = try profiles.upsert(edited, toFolderID: nil) { profile in
            try keychain.updateProxyPasswordForProfileEdit(
                "synthetic-password",
                profileID: profile.id
            )
        }

        let reloaded = ProfileStore(paths: paths)
        #expect(saved.revision == selected.revision + 1)
        #expect(reloaded.profile(withID: selected.id)?.proxy == edited.proxy)
        #expect(reloaded.profile(withID: untouched.id) == untouchedBefore)
        #expect(try keychain.proxyPassword(profileID: selected.id) ==
            "synthetic-password")
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    @Test
    func purgeNeverAttemptsCompensatingRestore() throws {
        let backend = MemoryKeychainBackend()
        let profileID = UUID()
        backend.set(
            "current",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.set(
            "legacy",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        backend.deleteFailureService = KeychainStore.legacyService
        backend.upsertAlwaysFails = true
        let store = KeychainStore(backend: backend)

        #expect(throws: KeychainCredentialPurgeError.self) {
            try store.deleteProxyPassword(profileID: profileID)
        }

        #expect(backend.upsertCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == nil
        )
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == "legacy"
        )
    }

    @Test
    func recoveryRetriesTransientFailureAndRemovesMarker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try createCommittedCleanupMarkers(
            paths: paths,
            profileID: profileID
        )

        let backend = MemoryKeychainBackend()
        backend.set(
            "current",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.set(
            "legacy",
            service: KeychainStore.legacyService,
            profileID: profileID
        )
        backend.deleteFailureService = KeychainStore.legacyService
        let keychain = KeychainStore(backend: backend)
        #expect(throws: KeychainCredentialPurgeError.self) {
            try keychain.deleteProxyPassword(profileID: profileID)
        }

        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: keychain
        )
        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(summary.attemptedCount == 1)
        #expect(summary.clearedCount == 1)
        #expect(summary.failedCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == nil
        )
        #expect(
            backend.string(
                service: KeychainStore.legacyService,
                profileID: profileID
            ) == nil
        )
        #expect(
            try paths.privateFileEntryKind(
                paths.profileCredentialCleanupMarker(for: profileID)
            ) == .missing
        )
        #expect(
            await cleanup.runOnce(
                metadataIsTrusted: true,
                excluding: []
            ) == .alreadyCompleted
        )
    }

    @Test
    func recoveryNeverDeletesSecretForActiveProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try createCommittedCleanupMarkers(
            paths: paths,
            profileID: profileID
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "active-secret",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: [profileID]
        )

        #expect(summary.attemptedCount == 0)
        #expect(summary.skippedActiveCount == 1)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "active-secret"
        )
        #expect(
            try paths.privateFileEntryKind(
                paths.profileCredentialCleanupMarker(for: profileID)
            ) == .regular
        )
    }

    @Test
    func untrustedMetadataSkipsCredentialRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try createCommittedCleanupMarkers(
            paths: paths,
            profileID: profileID
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "secret",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: false,
            excluding: []
        )

        #expect(summary.skippedBecauseMetadataUntrusted)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "secret"
        )
    }

    @Test
    func ordinaryDeletionTombstoneIsNotCredentialRecoveryQueue()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try paths.createPrivateFileExclusively(
            Data("deleted-v1".utf8),
            at: paths.profileDeletionTombstone(for: profileID)
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "must-remain",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(summary.attemptedCount == 0)
        #expect(!summary.inspectionFailed)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "must-remain"
        )
    }

    @Test
    func unsafeAndMalformedPendingMarkersNeverReachKeychain()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try paths.createPrivateFileExclusively(
            Data("deleted-v1".utf8),
            at: paths.profileDeletionTombstone(for: profileID)
        )
        try FileManager.default.createSymbolicLink(
            at: paths.profileCredentialCleanupMarker(for: profileID),
            withDestinationURL: paths.profileDeletionTombstone(
                for: profileID
            )
        )
        try paths.createPrivateFileExclusively(
            Data("ignored".utf8),
            at: paths.processLocksDirectory.appendingPathComponent(
                "not-a-uuid.credentials-pending"
            )
        )
        let validProfileID = UUID()
        try createCommittedCleanupMarkers(
            paths: paths,
            profileID: validProfileID
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "must-remain",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.set(
            "remove-me",
            service: KeychainStore.currentService,
            profileID: validProfileID
        )
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(summary.attemptedCount == 1)
        #expect(summary.clearedCount == 1)
        #expect(summary.inspectionFailed)
        #expect(backend.deleteCallCount == 2)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "must-remain"
        )
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: validProfileID
            ) == nil
        )
    }

    @Test
    func existingProfileDirectoryBlocksCredentialCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try createCommittedCleanupMarkers(
            paths: paths,
            profileID: profileID
        )
        try FileManager.default.createDirectory(
            at: paths.profileDirectory(for: profileID),
            withIntermediateDirectories: false
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "must-remain",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(summary.attemptedCount == 0)
        #expect(summary.inspectionFailed)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "must-remain"
        )
    }

    @Test
    func missingDeletionTombstoneReportsInspectionFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try paths.createPrivateFileExclusively(
            Data("keychain-cleanup-v1".utf8),
            at: paths.profileCredentialCleanupMarker(for: profileID)
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "must-remain",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(summary.inspectionFailed)
        #expect(summary.attemptedCount == 0)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "must-remain"
        )
    }

    @Test
    func cleanupRevalidatesAfterDeletionTransactionLock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try createCommittedCleanupMarkers(
            paths: paths,
            profileID: profileID
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "must-remain",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        let candidateEnumerated = DispatchSemaphore(value: 0)
        let continueToLock = DispatchSemaphore(value: 0)
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend),
            beforeCandidateRevalidation: { candidate in
                guard candidate == profileID else { return }
                candidateEnumerated.signal()
                continueToLock.wait()
            }
        )
        let cleanupTask = Task.detached {
            await cleanup.runOnce(
                metadataIsTrusted: true,
                excluding: []
            )
        }

        await Task.detached {
            waitSynchronously(candidateEnumerated)
        }.value
        try paths.withProcessLockGuard(for: profileID) {
            continueToLock.signal()
            try paths.removeCredentialCleanupMarker(for: profileID)
        }
        let summary = await cleanupTask.value

        #expect(summary.attemptedCount == 0)
        #expect(summary.clearedCount == 0)
        #expect(!summary.inspectionFailed)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "must-remain"
        )
    }

    @Test
    func malformedPendingMarkerIsIgnoredWithoutInspectionFailure()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        try paths.createPrivateFileExclusively(
            Data("ignored".utf8),
            at: paths.processLocksDirectory.appendingPathComponent(
                "not-a-uuid.credentials-pending"
            )
        )
        let backend = MemoryKeychainBackend()
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(!summary.inspectionFailed)
        #expect(summary.attemptedCount == 0)
        #expect(backend.deleteCallCount == 0)
    }

    @Test
    func unsafeProcessGuardReportsInspectionFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try createCommittedCleanupMarkers(
            paths: paths,
            profileID: profileID
        )
        try FileManager.default.createSymbolicLink(
            at: paths.lockGuardFile(for: profileID),
            withDestinationURL: paths.profileDeletionTombstone(
                for: profileID
            )
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "must-remain",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(summary.inspectionFailed)
        #expect(summary.attemptedCount == 0)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "must-remain"
        )
    }

    @Test
    func keychainFailureIsNotMisreportedAsInspectionFailure()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profileID = UUID()
        try createCommittedCleanupMarkers(
            paths: paths,
            profileID: profileID
        )
        let backend = MemoryKeychainBackend()
        backend.set(
            "must-remain",
            service: KeychainStore.currentService,
            profileID: profileID
        )
        backend.deleteFailureService = KeychainStore.currentService
        let cleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: KeychainStore(backend: backend)
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(summary.failedCount == 1)
        #expect(!summary.inspectionFailed)
        #expect(
            try paths.privateFileEntryKind(
                paths.profileCredentialCleanupMarker(for: profileID)
            ) == .regular
        )
    }

    private func createCommittedCleanupMarkers(
        paths: AppPaths,
        profileID: UUID
    ) throws {
        try paths.createPrivateFileExclusively(
            Data("deleted-v1".utf8),
            at: paths.profileDeletionTombstone(for: profileID)
        )
        try paths.createPrivateFileExclusively(
            Data("keychain-cleanup-v1".utf8),
            at: paths.profileCredentialCleanupMarker(for: profileID)
        )
    }
}

private final class MemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    var deleteFailureService: String?
    var deleteFailureServices = Set<String>()
    var upsertAlwaysFails = false
    private(set) var upsertCallCount = 0
    private(set) var deleteCallCount = 0
    private var values: [String: Data] = [:]

    func data(service: String, profileID: UUID) throws -> Data? {
        values[key(service: service, profileID: profileID)]
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        upsertCallCount += 1
        if upsertAlwaysFails {
            throw MemoryKeychainError()
        }
        values[key(service: service, profileID: profileID)] = data
    }

    func delete(service: String, profileID: UUID) throws {
        deleteCallCount += 1
        if deleteFailureServices.contains(service) {
            throw MemoryKeychainError()
        }
        if deleteFailureService == service {
            deleteFailureService = nil
            throw MemoryKeychainError()
        }
        values.removeValue(forKey: key(service: service, profileID: profileID))
    }

    func set(_ value: String, service: String, profileID: UUID) {
        values[key(service: service, profileID: profileID)] = Data(value.utf8)
    }

    func set(_ value: Data, service: String, profileID: UUID) {
        values[key(service: service, profileID: profileID)] = value
    }

    func dataValue(service: String, profileID: UUID) -> Data? {
        values[key(service: service, profileID: profileID)]
    }

    func string(service: String, profileID: UUID) -> String? {
        values[key(service: service, profileID: profileID)]
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private func key(service: String, profileID: UUID) -> String {
        "\(service)|\(profileID.uuidString)"
    }
}

private struct MemoryKeychainError: Error {}

private func waitSynchronously(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
