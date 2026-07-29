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
}

private final class MemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    var deleteFailureService: String?
    var upsertAlwaysFails = false
    private(set) var upsertCallCount = 0
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
