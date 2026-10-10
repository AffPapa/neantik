import CryptoKit
import Foundation
import Security

/// Separate immutable device-local scope, never proxy credentials. Restore
/// cannot create or repair it. Backend failure is surfaced without fallback.
protocol BackupCompatibilityScopeBackend: Sendable {
    func read() throws -> Data?
    /// Returns false when another creator won; never overwrites an item.
    func insertIfAbsent(_ bytes: Data) throws -> Bool
}

struct SecurityBackupCompatibilityScopeBackend: BackupCompatibilityScopeBackend {
    let service: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "browser-data-backup-scope-v1",
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw KeychainError(status: status) }
        return bytes
    }
    func insertIfAbsent(_ bytes: Data) throws -> Bool {
        var query = query
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }
}

enum BackupCompatibilityScopeError: LocalizedError, Equatable {
    case unavailable
    var errorDescription: String? {
        "Не удалось подтвердить локальный ключ совместимости копии. Данные не заменены. Разблокируй Связку ключей и повтори. Если ключ удалён или это другой Mac, автоматическое восстановление недоступно."
    }
}

struct BackupCompatibilityScopeStore: Sendable {
    private let backend: any BackupCompatibilityScopeBackend
    private let random: @Sendable () throws -> Data
    init(backend: any BackupCompatibilityScopeBackend,
         random: @escaping @Sendable () throws -> Data = Self.secureRandom) {
        self.backend = backend; self.random = random
    }
    func digest(createForExport: Bool) throws -> String {
        if let bytes = try backend.read() { return try Self.digest(bytes) }
        guard createForExport else { throw BackupCompatibilityScopeError.unavailable }
        let candidate = try random()
        guard candidate.count == 32 else { throw BackupCompatibilityScopeError.unavailable }
        // Always read back the persisted winner, including our own insertion.
        // A lost write or concurrent replacement cannot become an in-memory
        // scope that was never actually stored.
        _ = try backend.insertIfAbsent(candidate)
        guard let winner = try backend.read() else { throw BackupCompatibilityScopeError.unavailable }
        return try Self.digest(winner)
    }
    private static func digest(_ bytes: Data) throws -> String {
        guard bytes.count == 32 else { throw BackupCompatibilityScopeError.unavailable }
        return SHA256.hash(data: Data("neantik-browser-data-same-device-scope-v1\0".utf8) + bytes)
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func secureRandom() throws -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return bytes
    }
}
