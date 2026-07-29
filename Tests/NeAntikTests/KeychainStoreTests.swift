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
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "must-remain"
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

        candidateEnumerated.wait()
        try paths.withProcessLockGuard(for: profileID) {
            continueToLock.signal()
            try paths.removeCredentialCleanupMarker(for: profileID)
        }
        let summary = await cleanupTask.value

        #expect(summary.attemptedCount == 0)
        #expect(summary.clearedCount == 0)
        #expect(backend.deleteCallCount == 0)
        #expect(
            backend.string(
                service: KeychainStore.currentService,
                profileID: profileID
            ) == "must-remain"
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
        if deleteFailureService == service {
            deleteFailureService = nil
            throw MemoryKeychainError()
        }
        values.removeValue(forKey: key(service: service, profileID: profileID))
    }

    func set(_ value: String, service: String, profileID: UUID) {
        values[key(service: service, profileID: profileID)] = Data(value.utf8)
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
