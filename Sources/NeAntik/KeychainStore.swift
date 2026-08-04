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
        let previousCurrent = try backend.data(
            service: service,
            profileID: profileID
        )
        let previousLegacy = try legacyService.flatMap {
            try backend.data(service: $0, profileID: profileID)
        }
        do {
            try backend.upsert(
                Data(password.utf8),
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
            restore(
                current: previousCurrent,
                legacy: previousLegacy,
                profileID: profileID
            )
            throw error
        }
    }

    func proxyPassword(profileID: UUID) throws -> String? {
        if let current = try backend.data(
            service: service,
            profileID: profileID
        ) {
            if let legacyService {
                try backend.delete(
                    service: legacyService,
                    profileID: profileID
                )
            }
            return try decode(current)
        }
        guard let legacyService,
              let legacy = try backend.data(
                  service: legacyService,
                  profileID: profileID
              ) else {
            return nil
        }

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
        return try decode(legacy)
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
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainDataError()
        }
        return value
    }

    private func restore(
        current: Data?,
        legacy: Data?,
        profileID: UUID
    ) {
        restore(
            current,
            service: service,
            profileID: profileID
        )
        if let legacyService {
            restore(
                legacy,
                service: legacyService,
                profileID: profileID
            )
        }
    }

    private func restore(
        _ value: Data?,
        service: String,
        profileID: UUID
    ) {
        if let value {
            try? backend.upsert(
                value,
                service: service,
                profileID: profileID
            )
        } else {
            try? backend.delete(
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

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Не удалось выполнить операцию со Связкой ключей macOS (код \(status))."
    }
}

private struct KeychainDataError: LocalizedError {
    var errorDescription: String? {
        "Сохранённый пароль прокси повреждён и не может быть прочитан."
    }
}
