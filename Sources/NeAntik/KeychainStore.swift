import Foundation
import Security

protocol KeychainBackend: Sendable {
    func data(service: String, profileID: UUID) throws -> Data?
    func upsert(_ data: Data, service: String, profileID: UUID) throws
    func delete(service: String, profileID: UUID) throws
}

struct SecurityKeychainBackend: KeychainBackend {
    func data(service: String, profileID: UUID) throws -> Data? {
        var query = lookup(service: service, profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        let lookup = lookup(service: service, profileID: profileID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(
            lookup as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            var insertion = lookup
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete(service: String, profileID: UUID) throws {
        let status = SecItemDelete(
            lookup(service: service, profileID: profileID) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func lookup(
        service: String,
        profileID: UUID
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
    }
}

struct KeychainStore: Sendable {
    static let currentService = "app.neantik.proxy"
    static let legacyService = [
        "app",
        "ne" + "vision",
        "proxy"
    ].joined(separator: ".")

    private let backend: any KeychainBackend
    private let service: String
    private let legacyService: String?

    init(
        backend: any KeychainBackend = SecurityKeychainBackend(),
        service: String = Self.currentService,
        legacyService: String? = Self.legacyService
    ) {
        self.backend = backend
        self.service = service
        self.legacyService = legacyService
    }

    func saveProxyPassword(_ password: String, profileID: UUID) throws {
        let credentialData = try validatedCredentialData(password)
        let previousCurrent = try backend.data(
            service: service,
            profileID: profileID
        )
        let previousLegacy = try legacyService.flatMap {
            try backend.data(service: $0, profileID: profileID)
        }
        do {
            try backend.upsert(
                credentialData,
                service: service,
                profileID: profileID
            )
            if let legacyService {
                try backend.delete(
                    service: legacyService,
                    profileID: profileID
                )
            }
        } catch {
            let operationError = error
            do {
                try restoreStrictly(
                    current: previousCurrent,
                    legacy: previousLegacy,
                    profileID: profileID
                )
            } catch {
                if previousCurrent == nil, previousLegacy == nil {
                    throw KeychainNewCredentialRollbackError(
                        profileID: profileID,
                        operationError: operationError,
                        rollbackError: error
                    )
                }
                throw KeychainProfileEditRollbackError(
                    operationError: operationError,
                    rollbackError: error
                )
            }
            throw operationError
        }
    }

    /// Applies an editor credential change with compensating rollback.
    ///
    /// Profile metadata is committed before this callback runs. Unlike the
    /// irreversible purge used after a profile deletion, an editor failure
    /// must restore both the current and legacy namespaces so the metadata
    /// transaction can safely roll back as well.
    func updateProxyPasswordForProfileEdit(
        _ password: String?,
        profileID: UUID
    ) throws {
        let credentialData = try password.map(validatedCredentialData)
        let previousCurrent = try backend.data(
            service: service,
            profileID: profileID
        )
        let previousLegacy = try legacyService.flatMap {
            try backend.data(service: $0, profileID: profileID)
        }
        do {
            if let credentialData {
                try backend.upsert(
                    credentialData,
                    service: service,
                    profileID: profileID
                )
            } else {
                try backend.delete(
                    service: service,
                    profileID: profileID
                )
            }
            if let legacyService {
                try backend.delete(
                    service: legacyService,
                    profileID: profileID
                )
            }
        } catch {
            let operationError = error
            do {
                try restoreStrictly(
                    current: previousCurrent,
                    legacy: previousLegacy,
                    profileID: profileID
                )
            } catch {
                throw KeychainProfileEditRollbackError(
                    operationError: operationError,
                    rollbackError: error
                )
            }
            throw operationError
        }
    }

    func proxyPassword(profileID: UUID) throws -> String? {
        if let current = try backend.data(
            service: service,
            profileID: profileID
        ) {
            let value = try decode(current)
            if let legacyService {
                try backend.delete(
                    service: legacyService,
                    profileID: profileID
                )
            }
            return value
        }
        guard let legacyService,
              let legacy = try backend.data(
                  service: legacyService,
                  profileID: profileID
              ) else {
            return nil
        }

        let value = try decode(legacy)
        do {
            try backend.upsert(
                legacy,
                service: service,
                profileID: profileID
            )
            try backend.delete(
                service: legacyService,
                profileID: profileID
            )
        } catch {
            try? backend.delete(
                service: service,
                profileID: profileID
            )
            throw error
        }
        return value
    }

    func deleteProxyPassword(profileID: UUID) throws {
        var failures = 0
        for service in [service, legacyService].compactMap({ $0 }) {
            do {
                try backend.delete(
                    service: service,
                    profileID: profileID
                )
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            throw KeychainCredentialPurgeError(
                failedNamespaceCount: failures
            )
        }
    }

    private func decode(_ data: Data) throws -> String {
        guard data.count <= ProxyImportParser.maximumPasswordBytes else {
            throw KeychainCredentialValidationError.tooLarge
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialValidationError.invalidEncoding
        }
        _ = try validatedCredentialData(value)
        return value
    }

    private func validatedCredentialData(_ value: String) throws -> Data {
        guard ProxyImportParser.passwordIsWithinLimits(value) else {
            throw KeychainCredentialValidationError.tooLarge
        }
        guard PersistedInlineText.isSafe(value) else {
            throw KeychainCredentialValidationError.unsafeCharacters
        }
        return Data(value.utf8)
    }

    private func restoreStrictly(
        current: Data?,
        legacy: Data?,
        profileID: UUID
    ) throws {
        var failedNamespaceCount = 0
        do {
            try restoreStrictly(
                current,
                service: service,
                profileID: profileID
            )
        } catch {
            failedNamespaceCount += 1
        }
        if let legacyService {
            do {
                try restoreStrictly(
                    legacy,
                    service: legacyService,
                    profileID: profileID
                )
            } catch {
                failedNamespaceCount += 1
            }
        }
        guard failedNamespaceCount == 0 else {
            throw KeychainCredentialSnapshotRestoreError(
                failedNamespaceCount: failedNamespaceCount
            )
        }
    }

    private func restoreStrictly(
        _ value: Data?,
        service: String,
        profileID: UUID
    ) throws {
        if let value {
            try backend.upsert(
                value,
                service: service,
                profileID: profileID
            )
        } else {
            try backend.delete(
                service: service,
                profileID: profileID
            )
        }
    }

}

struct KeychainCredentialPurgeError: LocalizedError {
    let failedNamespaceCount: Int

    var errorDescription: String? {
        "Не удалось полностью удалить пароль прокси из Связки ключей macOS. Очистку можно безопасно повторить позже."
    }
}

struct KeychainProfileEditRollbackError: LocalizedError {
    let operationError: any Error
    let rollbackError: any Error

    var errorDescription: String? {
        "Не удалось изменить пароль прокси и полностью восстановить прежнее состояние Связки ключей. Профиль не изменён; проверь пароль перед следующим запуском."
    }
}

/// Signals that a failed first credential write could not be compensated.
///
/// ProfileStore accepts this recovery capability only after it has proved that
/// the corresponding new profile metadata and directory were rolled back. A
/// durable cleanup marker can then remove an otherwise orphaned Keychain item
/// on the next application start.
struct KeychainNewCredentialRollbackError:
    LocalizedError,
    ProfileCredentialCleanupRecoveryProviding
{
    let profileID: UUID
    let operationError: any Error
    let rollbackError: any Error

    var profileIDsRequiringCredentialCleanup: [UUID] {
        [profileID]
    }

    var errorDescription: String? {
        "Не удалось сохранить новый пароль прокси и полностью отменить запись в Связке ключей. Профиль не создан; NeAntik безопасно повторит очистку."
    }
}

private struct KeychainCredentialSnapshotRestoreError: LocalizedError {
    let failedNamespaceCount: Int

    var errorDescription: String? {
        "Не удалось восстановить прежний пароль прокси во всех пространствах Связки ключей."
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Не удалось выполнить операцию со Связкой ключей macOS (код \(status))."
    }
}

enum KeychainCredentialValidationError: LocalizedError, Equatable {
    case tooLarge
    case unsafeCharacters
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "Пароль прокси превышает безопасный лимит Связки ключей."
        case .unsafeCharacters:
            "Пароль прокси содержит недопустимые управляющие символы."
        case .invalidEncoding:
            "Сохранённый пароль прокси повреждён и не может быть прочитан."
        }
    }
}
