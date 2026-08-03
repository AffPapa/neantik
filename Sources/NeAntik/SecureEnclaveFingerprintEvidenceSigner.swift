import CryptoKit
import Foundation
import Security

struct SecureEnclaveFingerprintEvidenceSignature: Sendable {
    let publicKeyX963: Data
    let signatureDER: Data
}

protocol SecureEnclaveFingerprintEvidenceKeyBackend: Sendable {
    func reserveEnrollment(applicationTag: Data) throws
    func publicKeyX963(applicationTag: Data) throws -> Data?
    func createPrivateKey(applicationTag: Data) throws -> Data
    func signature(
        for message: Data,
        applicationTag: Data
    ) throws -> SecureEnclaveFingerprintEvidenceSignature
    func deletePrivateKey(applicationTag: Data) throws
    func releaseEnrollment(applicationTag: Data) throws
}

enum SecureEnclaveFingerprintEvidenceAuthorityError:
    LocalizedError, Equatable
{
    case alreadyEnrolled
    case notEnrolled
    case authorityMismatch
    case ambiguousAuthority
    case invalidPublicKey
    case operationFailed(Int)

    var errorDescription: String? {
        switch self {
        case .alreadyEnrolled:
            "Ключ этой проверки уже создан. Подготовь новый сеанс выпуска."
        case .notEnrolled:
            "Защищённый ключ проверки не найден. Подготовь кандидата заново."
        case .authorityMismatch:
            "Защищённый ключ не совпадает с манифестом кандидата."
        case .ambiguousAuthority:
            "Найдено несколько защищённых ключей проверки. Подготовь новый сеанс выпуска."
        case .invalidPublicKey:
            "Открытый ключ проверки повреждён."
        case let .operationFailed(code):
            "Secure Enclave не выполнил операцию проверки (код \(code))."
        }
    }
}

struct SecureEnclaveFingerprintEvidenceAuthority: Sendable {
    static let applicationTagDomain =
        "app.neantik.fingerprint-evidence.p256.v1."

    private let backend: any SecureEnclaveFingerprintEvidenceKeyBackend

    init(
        backend: any SecureEnclaveFingerprintEvidenceKeyBackend =
            SecuritySecureEnclaveFingerprintEvidenceKeyBackend()
    ) {
        self.backend = backend
    }

    func enroll(sessionID: UUID) throws -> Data {
        let tag = Self.applicationTag(for: sessionID)
        try backend.reserveEnrollment(applicationTag: tag)
        guard try backend.publicKeyX963(applicationTag: tag) == nil else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .alreadyEnrolled
        }
        return try Self.validatedPublicKey(
            backend.createPrivateKey(applicationTag: tag)
        )
    }

    func existingSigner(
        sessionID: UUID,
        expectedPublicKeyX963: Data
    ) throws -> SecureEnclaveFingerprintEvidenceSigner {
        let expected = try Self.validatedPublicKey(
            expectedPublicKeyX963
        )
        let tag = Self.applicationTag(for: sessionID)
        guard let stored = try backend.publicKeyX963(
            applicationTag: tag
        ) else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError.notEnrolled
        }
        guard try Self.validatedPublicKey(stored) == expected else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .authorityMismatch
        }
        return SecureEnclaveFingerprintEvidenceSigner(
            applicationTag: tag,
            publicKeyX963: expected,
            backend: backend
        )
    }

    func abandon(sessionID: UUID) throws {
        let tag = Self.applicationTag(for: sessionID)
        try backend.deletePrivateKey(applicationTag: tag)
        try backend.releaseEnrollment(applicationTag: tag)
    }

    static func applicationTag(for sessionID: UUID) -> Data {
        Data(
            (applicationTagDomain + sessionID.uuidString).utf8
        )
    }

    private static func validatedPublicKey(_ data: Data) throws -> Data {
        guard data.count == 65, data.first == 0x04 else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .invalidPublicKey
        }
        do {
            _ = try P256.Signing.PublicKey(
                x963Representation: data
            )
        } catch {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .invalidPublicKey
        }
        return data
    }
}

struct SecureEnclaveFingerprintEvidenceSigner:
    FingerprintEvidenceSigning, Sendable
{
    let applicationTag: Data
    let publicKeyX963: Data
    private let backend: any SecureEnclaveFingerprintEvidenceKeyBackend

    init(
        applicationTag: Data,
        publicKeyX963: Data,
        backend: any SecureEnclaveFingerprintEvidenceKeyBackend
    ) {
        self.applicationTag = applicationTag
        self.publicKeyX963 = publicKeyX963
        self.backend = backend
    }

    func signatureDER(for transcript: Data) throws -> Data {
        let result = try backend.signature(
            for: transcript,
            applicationTag: applicationTag
        )
        guard result.publicKeyX963 == publicKeyX963 else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .authorityMismatch
        }
        return result.signatureDER
    }
}

struct SecuritySecureEnclaveFingerprintEvidenceKeyBackend:
    SecureEnclaveFingerprintEvidenceKeyBackend
{
    private static let reservationService =
        "app.neantik.fingerprint-evidence.enrollment.v1"
    private static let fallbackKeyService =
        "app.neantik.fingerprint-evidence.keychain-p256.v1"

    func reserveEnrollment(applicationTag: Data) throws {
        var query = enrollmentReservationQuery(
            applicationTag: applicationTag
        )
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = Data([1])
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .alreadyEnrolled
        }
        guard status == errSecSuccess else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .operationFailed(Int(status))
        }
    }

    func publicKeyX963(applicationTag: Data) throws -> Data? {
        if let fallback = try fallbackPrivateKey(
            applicationTag: applicationTag
        ) {
            return fallback.publicKey.x963Representation
        }
        guard let privateKey = try secureEnclavePrivateKey(
            applicationTag: applicationTag
        ) else {
            return nil
        }
        return try publicKeyX963(privateKey: privateKey)
    }

    func createPrivateKey(applicationTag: Data) throws -> Data {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &accessError
        ) else {
            throw operationError(accessError?.takeRetainedValue())
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String:
                kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: applicationTag,
                kSecAttrAccessControl as String: accessControl
            ]
        ]
        var createError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &createError
        ) else {
            let error = operationError(createError?.takeRetainedValue())
            if case let .operationFailed(code) = error,
               code == Int(errSecMissingEntitlement) {
                return try createFallbackPrivateKey(
                    applicationTag: applicationTag
                )
            }
            throw error
        }
        do {
            return try publicKeyX963(privateKey: privateKey)
        } catch {
            let cleanupStatus = SecItemDelete(
                [
                    kSecClass as String: kSecClassKey,
                    kSecMatchItemList as String: [privateKey]
                ] as CFDictionary
            )
            guard cleanupStatus == errSecSuccess ||
                    cleanupStatus == errSecItemNotFound
            else {
                throw SecureEnclaveFingerprintEvidenceAuthorityError
                    .operationFailed(Int(cleanupStatus))
            }
            throw error
        }
    }

    func signature(
        for message: Data,
        applicationTag: Data
    ) throws -> SecureEnclaveFingerprintEvidenceSignature {
        if let fallback = try fallbackPrivateKey(
            applicationTag: applicationTag
        ) {
            let signature = try fallback.signature(for: message)
            return SecureEnclaveFingerprintEvidenceSignature(
                publicKeyX963: fallback.publicKey.x963Representation,
                signatureDER: signature.derRepresentation
            )
        }
        guard let privateKey = try secureEnclavePrivateKey(
            applicationTag: applicationTag
        ) else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError.notEnrolled
        }
        guard SecKeyIsAlgorithmSupported(
            privateKey,
            .sign,
            .ecdsaSignatureMessageX962SHA256
        ) else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .operationFailed(Int(errSecUnimplemented))
        }
        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &signatureError
        ) as Data? else {
            throw operationError(signatureError?.takeRetainedValue())
        }
        return SecureEnclaveFingerprintEvidenceSignature(
            publicKeyX963: try publicKeyX963(privateKey: privateKey),
            signatureDER: signature
        )
    }

    func deletePrivateKey(applicationTag: Data) throws {
        let fallbackStatus = SecItemDelete(
            fallbackPrivateKeyQuery(applicationTag: applicationTag)
                as CFDictionary
        )
        guard fallbackStatus == errSecSuccess ||
                fallbackStatus == errSecItemNotFound
        else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .operationFailed(Int(fallbackStatus))
        }
        let status = SecItemDelete(
            privateKeyQuery(applicationTag: applicationTag)
                as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .operationFailed(Int(status))
        }
    }

    func releaseEnrollment(applicationTag: Data) throws {
        let status = SecItemDelete(
            enrollmentReservationQuery(
                applicationTag: applicationTag
            ) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .operationFailed(Int(status))
        }
    }

    private func secureEnclavePrivateKey(applicationTag: Data) throws -> SecKey? {
        var query = privateKeyQuery(applicationTag: applicationTag)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .operationFailed(Int(status))
        }
        guard let result,
              let items = result as? [Any],
              items.count == 1,
              let item = items.first
        else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .ambiguousAuthority
        }
        let reference = item as CFTypeRef
        guard CFGetTypeID(reference) == SecKeyGetTypeID() else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .invalidPublicKey
        }
        return (reference as! SecKey)
    }

    private func privateKeyQuery(
        applicationTag: Data
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String:
                kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: applicationTag
        ]
    }

    private func enrollmentReservationQuery(
        applicationTag: Data
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.reservationService,
            kSecAttrAccount as String:
                applicationTag.base64EncodedString()
        ]
    }

    private func createFallbackPrivateKey(
        applicationTag: Data
    ) throws -> Data {
        let privateKey = P256.Signing.PrivateKey()
        var query = fallbackPrivateKeyQuery(applicationTag: applicationTag)
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = privateKey.rawRepresentation
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .alreadyEnrolled
        }
        guard status == errSecSuccess else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .operationFailed(Int(status))
        }
        return privateKey.publicKey.x963Representation
    }

    private func fallbackPrivateKey(
        applicationTag: Data
    ) throws -> P256.Signing.PrivateKey? {
        var query = fallbackPrivateKeyQuery(applicationTag: applicationTag)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .operationFailed(Int(status))
        }
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .invalidPublicKey
        }
    }

    private func fallbackPrivateKeyQuery(
        applicationTag: Data
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.fallbackKeyService,
            kSecAttrAccount as String:
                applicationTag.base64EncodedString()
        ]
    }

    private func publicKeyX963(privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .invalidPublicKey
        }
        var publicError: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(
            publicKey,
            &publicError
        ) as Data?, data.count == 65, data.first == 0x04 else {
            if let error = publicError?.takeRetainedValue() {
                throw operationError(error)
            }
            throw SecureEnclaveFingerprintEvidenceAuthorityError
                .invalidPublicKey
        }
        return data
    }

    private func operationError(
        _ error: CFError?
    ) -> SecureEnclaveFingerprintEvidenceAuthorityError {
        let code = error.map { Int(CFErrorGetCode($0)) } ?? -1
        if code == Int(errSecDuplicateItem) {
            return .alreadyEnrolled
        }
        return .operationFailed(code)
    }
}
