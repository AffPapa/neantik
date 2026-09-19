import Foundation
import Testing
@testable import NeAntik

/// Exercises the UI's save coordinator with real on-disk profile persistence.
/// Only the credential backend is replaced; no system Keychain is accessed.
@MainActor
struct ProfileDuplicationPersistenceTests {
    @Test func rejectedCredentialWriteRollsBackPersistedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-copy-rollback-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let source = try store.upsert(BrowserProfile(
            name: "Synthetic rollback source",
            proxy: ProxyConfiguration(kind: .https, host: "synthetic.invalid", port: 443, username: "synthetic")
        ))
        let backend = CopyMemoryCredentialBackend()
        let keychain = KeychainStore(backend: backend, service: "synthetic.rollback", legacyService: nil)
        let secret = "SYNTHETIC_ROLLBACK_SECRET"
        try keychain.saveProxyPassword(secret, profileID: source.id)
        backend.rejectWrites()
        var options = ProfileDuplicationOptions(name: "Rejected copy", destinationFolderID: nil)
        options.setCopiesProxy(true)
        options.setCopiesProxyPassword(true)
        #expect(throws: (any Error).self) {
            try ProfileDuplicator.saveCopy(
                sourceProfileID: source.id, expectedSourceRevision: source.revision,
                options: options, store: store, keychain: keychain
            )
        }
        #expect(store.profiles.map(\.id) == [source.id])
        #expect(ProfileStore(paths: paths).profiles.map(\.id) == [source.id])
        #expect(try keychain.proxyPassword(profileID: source.id) == secret)
    }

    @Test func proxyPasswordRequiresSeparateConsentAtPersistenceBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-copy-consent-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let source = try store.upsert(BrowserProfile(
            name: "Synthetic credential source",
            proxy: ProxyConfiguration(kind: .https, host: "synthetic.invalid", port: 443, username: "synthetic")
        ))
        var options = ProfileDuplicationOptions(name: "Proxy only", destinationFolderID: nil)
        options.setCopiesProxy(true)
        let proxyOnly = try ProfileDuplicator.saveCopy(
            sourceProfileID: source.id, expectedSourceRevision: source.revision,
            options: options, store: store,
            keychain: KeychainStore(backend: ForbiddenCopyCredentialBackend())
        )
        #expect(proxyOnly.proxy == source.proxy)

        let backend = CopyMemoryCredentialBackend()
        let keychain = KeychainStore(backend: backend, service: "synthetic.copy", legacyService: nil)
        let password = "SYNTHETIC_COPY_CONSENT_SECRET"
        try keychain.saveProxyPassword(password, profileID: source.id)
        options.name = "Proxy with consent"
        options.setCopiesProxyPassword(true)
        let optedIn = try ProfileDuplicator.saveCopy(
            sourceProfileID: source.id, expectedSourceRevision: source.revision,
            options: options, store: store, keychain: keychain
        )
        #expect(try keychain.proxyPassword(profileID: optedIn.id) == password)
        #expect(try keychain.proxyPassword(profileID: source.id) == password)
        #expect(try keychain.proxyPassword(profileID: proxyOnly.id) == nil)
        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profiles.count == 3)
        #expect(reloaded.profile(withID: optedIn.id)?.proxy == source.proxy)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: paths.browserDataDirectory(for: optedIn.id).path
        ).isEmpty)
        let metadata = try String(contentsOf: paths.profilesFile, encoding: .utf8)
        #expect(!metadata.contains(password))
    }

    @Test func defaultCopyPersistsConfigurationWithoutPrivateStateOrCredentialAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-copy-integration-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let source = try store.upsert(BrowserProfile(
            name: "Synthetic source", note: "SYNTHETIC_PRIVATE_NOTE",
            proxy: ProxyConfiguration(
                kind: .https, host: "synthetic.invalid", port: 8080,
                username: "SYNTHETIC_PRIVATE_USER"
            )
        ))
        let sourceData = paths.browserDataDirectory(for: source.id)
        let marker = sourceData.appendingPathComponent("Synthetic-cookie-state")
        let markerBytes = Data("SYNTHETIC_COOKIE_DO_NOT_COPY".utf8)
        try markerBytes.write(to: marker)
        let savedSource = try #require(store.profile(withID: source.id))
        let copy = try ProfileDuplicator.saveCopy(
            sourceProfileID: source.id,
            expectedSourceRevision: savedSource.revision,
            options: ProfileDuplicationOptions(name: "Synthetic copy", destinationFolderID: nil),
            store: store,
            keychain: KeychainStore(backend: ForbiddenCopyCredentialBackend())
        )
        let reloaded = ProfileStore(paths: paths)
        let persisted = try #require(reloaded.profile(withID: copy.id))
        #expect(persisted.id != source.id)
        #expect(persisted.identity != source.identity)
        #expect(persisted.proxy == nil)
        #expect(persisted.note.isEmpty)
        let copiedData = paths.browserDataDirectory(for: copy.id)
        #expect(copiedData != sourceData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copiedData.path).isEmpty)
        #expect(try Data(contentsOf: marker) == markerBytes)
        #expect(reloaded.profiles.count == 2)
    }
}

private struct ForbiddenCopyCredentialBackend: KeychainBackend {
    private enum UnexpectedAccess: Error { case credentialAccess }
    func data(service: String, profileID: UUID) throws -> Data? {
        throw UnexpectedAccess.credentialAccess
    }
    func upsert(_ data: Data, service: String, profileID: UUID) throws {
        throw UnexpectedAccess.credentialAccess
    }
    func delete(service: String, profileID: UUID) throws {
        throw UnexpectedAccess.credentialAccess
    }
}

private final class CopyMemoryCredentialBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [UUID: Data]] = [:]
    private var rejectsWrites = false
    private enum SyntheticFailure: Error { case writeRejected }
    func rejectWrites() {
        lock.lock(); defer { lock.unlock() }
        rejectsWrites = true
    }
    func data(service: String, profileID: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[service]?[profileID]
    }
    func upsert(_ data: Data, service: String, profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectsWrites { throw SyntheticFailure.writeRejected }
        values[service, default: [:]][profileID] = data
    }
    func delete(service: String, profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        values[service]?[profileID] = nil
    }
}
