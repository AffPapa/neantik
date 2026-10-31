import Foundation

/// The authenticated release-audit startup never reads the system Keychain.
/// Credentials are transient test input, not a persistence qualification. This
/// backend is selected only at the app composition root after authentication.
final class ReleaseAuditKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [UUID: Data]] = [:]
    func data(service: String, profileID: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[service]?[profileID]
    }
    func upsert(_ data: Data, service: String, profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        values[service, default: [:]][profileID] = data
    }
    func delete(service: String, profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        values[service]?[profileID] = nil
    }
}
