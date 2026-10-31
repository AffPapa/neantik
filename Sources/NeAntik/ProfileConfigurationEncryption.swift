import CommonCrypto
import CryptoKit
import Foundation
import Security

struct EncryptedProfileConfigurationEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let cipher: String
    let kdf: String
    let iterations: Int
    let salt: String
    let nonce: String
    let ciphertext: String
}

enum ProfileConfigurationEncryptionError: LocalizedError, Equatable, Sendable {
    case weakPassphrase
    case invalidEnvelope
    case unsupportedEnvelope
    case fileTooLarge
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .weakPassphrase:
            "Пароль должен содержать минимум 12 байт UTF-8 без управляющих знаков."
        case .invalidEnvelope:
            "Зашифрованный файл конфигурации повреждён."
        case .unsupportedEnvelope:
            "Зашифрованный файл создан другой версией NeAntik."
        case .fileTooLarge:
            "Зашифрованный файл конфигурации слишком большой."
        case .encryptionFailed:
            "Не удалось зашифровать конфигурацию профилей."
        case .decryptionFailed:
            "Не удалось расшифровать конфигурацию. Проверь пароль и файл."
        }
    }
}

enum ProfileConfigurationEncryption {
    static let currentSchemaVersion = 1
    static let cipher = "AES-256-GCM"
    static let kdf = "PBKDF2-HMAC-SHA256"
    static let iterations = 600_000
    static let saltByteCount = 16
    static let nonceByteCount = 12
    static let keyByteCount = 32
    static let maximumPlaintextBytes = 16 * 1_024 * 1_024
    static let maximumEnvelopeBytes = 24 * 1_024 * 1_024
    private static let authenticationContext = Data(
        "NeAntik encrypted profile configuration v1".utf8
    )

    static func seal(
        document: ProfileConfigurationTransferDocument,
        passphrase: String
    ) throws -> Data {
        try validate(passphrase: passphrase)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let plaintext: Data
        do {
            plaintext = try encoder.encode(document)
        } catch {
            throw ProfileConfigurationEncryptionError.encryptionFailed
        }
        guard plaintext.count <= maximumPlaintextBytes else {
            throw ProfileConfigurationEncryptionError.fileTooLarge
        }

        do {
            let salt = try randomData(count: saltByteCount)
            let nonceData = try randomData(count: nonceByteCount)
            let keyData = try deriveKey(
                passphrase: passphrase,
                salt: salt
            )
            let key = SymmetricKey(data: keyData)
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: authenticationContext
            )
            let ciphertext = sealed.ciphertext + sealed.tag
            let envelope = EncryptedProfileConfigurationEnvelope(
                schemaVersion: currentSchemaVersion,
                cipher: cipher,
                kdf: kdf,
                iterations: iterations,
                salt: salt.base64EncodedString(),
                nonce: nonceData.base64EncodedString(),
                ciphertext: ciphertext.base64EncodedString()
            )
            let envelopeData = try encoder.encode(envelope)
            guard envelopeData.count <= maximumEnvelopeBytes else {
                throw ProfileConfigurationEncryptionError.fileTooLarge
            }
            return envelopeData
        } catch let error as ProfileConfigurationEncryptionError {
            throw error
        } catch {
            throw ProfileConfigurationEncryptionError.encryptionFailed
        }
    }

    static func open(
        _ data: Data,
        passphrase: String
    ) throws -> ProfileConfigurationTransferDocument {
        try validate(passphrase: passphrase)
        guard data.count <= maximumEnvelopeBytes else {
            throw ProfileConfigurationEncryptionError.fileTooLarge
        }

        let envelope: EncryptedProfileConfigurationEnvelope
        do {
            envelope = try JSONDecoder().decode(
                EncryptedProfileConfigurationEnvelope.self,
                from: data
            )
        } catch {
            throw ProfileConfigurationEncryptionError.invalidEnvelope
        }
        guard envelope.schemaVersion == currentSchemaVersion,
              envelope.cipher == cipher,
              envelope.kdf == kdf,
              envelope.iterations == iterations,
              let salt = Data(base64Encoded: envelope.salt),
              salt.count == saltByteCount,
              let nonceData = Data(base64Encoded: envelope.nonce),
              nonceData.count == nonceByteCount,
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              ciphertext.count >= 16,
              ciphertext.count <= maximumPlaintextBytes + 16
        else {
            throw ProfileConfigurationEncryptionError.unsupportedEnvelope
        }

        do {
            let keyData = try deriveKey(
                passphrase: passphrase,
                salt: salt
            )
            let key = SymmetricKey(data: keyData)
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext.dropLast(16),
                tag: ciphertext.suffix(16)
            )
            let plaintext = try AES.GCM.open(
                sealed,
                using: key,
                authenticating: authenticationContext
            )
            guard plaintext.count <= maximumPlaintextBytes else {
                throw ProfileConfigurationEncryptionError.fileTooLarge
            }
            return try JSONDecoder().decode(
                ProfileConfigurationTransferDocument.self,
                from: plaintext
            )
        } catch let error as ProfileConfigurationEncryptionError {
            throw error
        } catch {
            throw ProfileConfigurationEncryptionError.decryptionFailed
        }
    }

    private static func validate(passphrase: String) throws {
        let length = passphrase.utf8.count
        guard (12...512).contains(length),
              !passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty,
              passphrase.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw ProfileConfigurationEncryptionError.weakPassphrase
        }
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                bytes.baseAddress!
            )
        }
        guard status == errSecSuccess else {
            throw ProfileConfigurationEncryptionError.encryptionFailed
        }
        return data
    }

    private static func deriveKey(
        passphrase: String,
        salt: Data
    ) throws -> Data {
        let passwordData = Data(passphrase.utf8)
        let outputByteCount = keyByteCount
        var derived = Data(count: outputByteCount)
        let status = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { derivedBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self)
                            .baseAddress!,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.bindMemory(to: UInt8.self)
                            .baseAddress!,
                        outputByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw ProfileConfigurationEncryptionError.encryptionFailed
        }
        return derived
    }
}
