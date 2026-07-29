import CryptoKit
import Foundation

struct FingerprintEvidenceManifestBinding: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let algorithmName = "P256-SHA256"

    let schemaVersion: Int
    let algorithm: String
    let authorityKeyID: String
    let publicKeyX963: String
    let sessionID: UUID
    let challenge: String

    init(
        publicKeyX963: Data,
        sessionID: UUID,
        challenge: Data
    ) {
        schemaVersion = Self.currentSchemaVersion
        algorithm = Self.algorithmName
        authorityKeyID = Self.keyID(for: publicKeyX963)
        self.publicKeyX963 = publicKeyX963.base64EncodedString()
        self.sessionID = sessionID
        self.challenge = challenge.base64EncodedString()
    }

    func validated() throws -> (
        publicKey: P256.Signing.PublicKey,
        challenge: Data
    ) {
        guard schemaVersion == Self.currentSchemaVersion,
              algorithm == Self.algorithmName,
              authorityKeyID.utf8.count == 64,
              authorityKeyID.allSatisfy({
                  $0.isASCII &&
                      ($0.isNumber || ("a"..."f").contains($0))
              }),
              publicKeyX963.utf8.count <= 128,
              challenge.utf8.count <= 64,
              let publicKeyData = Data(base64Encoded: publicKeyX963),
              publicKeyData.count == 65,
              publicKeyX963 == publicKeyData.base64EncodedString(),
              let challengeData = Data(base64Encoded: challenge),
              challengeData.count == 32,
              challenge == challengeData.base64EncodedString(),
              authorityKeyID == Self.keyID(for: publicKeyData)
        else {
            throw FingerprintEvidenceError.invalidManifestBinding
        }
        do {
            return (
                try P256.Signing.PublicKey(
                    x963Representation: publicKeyData
                ),
                challengeData
            )
        } catch {
            throw FingerprintEvidenceError.invalidManifestBinding
        }
    }

    static func keyID(for publicKeyX963: Data) -> String {
        SHA256.hash(data: publicKeyX963)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct FingerprintEvidenceAuthentication: Codable, Equatable, Sendable {
    let algorithm: String
    let keyID: String
    let candidateManifestSHA256: String
    let sessionID: UUID
    let challengeSHA256: String
    let signatureDER: String
}

struct FingerprintEvidenceEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 8
    static let kindName = "neantik-gui-fingerprint-evidence"
    static let payloadEncodingName = "base64-json-utf8"

    let schemaVersion: Int
    let kind: String
    let payloadEncoding: String
    let payload: String
    let authentication: FingerprintEvidenceAuthentication
}

protocol FingerprintEvidenceSigning: Sendable {
    var publicKeyX963: Data { get }
    func signatureDER(for transcript: Data) throws -> Data
}

#if DEBUG
struct SoftwareP256FingerprintEvidenceSigner: FingerprintEvidenceSigning {
    private let privateKey: P256.Signing.PrivateKey

    init() {
        privateKey = P256.Signing.PrivateKey()
    }

    var publicKeyX963: Data {
        privateKey.publicKey.x963Representation
    }

    func signatureDER(for transcript: Data) throws -> Data {
        try privateKey.signature(for: transcript).derRepresentation
    }
}
#endif

enum FingerprintEvidenceError: LocalizedError, Equatable {
    case invalidManifestBinding
    case signingAuthorityMismatch
    case payloadTooLarge
    case manifestTooLarge
    case malformedEnvelope
    case bindingMismatch
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .invalidManifestBinding:
            "Данные проверки отпечатка в манифесте повреждены."
        case .signingAuthorityMismatch:
            "Ключ проверки не совпадает с подготовленным приложением."
        case .payloadTooLarge:
            "Отчёт проверки отпечатка слишком большой."
        case .manifestTooLarge:
            "Манифест подготовленного приложения слишком большой."
        case .malformedEnvelope:
            "Подписанный отчёт проверки отпечатка повреждён."
        case .bindingMismatch:
            "Отчёт относится к другому подготовленному приложению."
        case .invalidSignature:
            "Подпись отчёта проверки отпечатка недействительна."
        }
    }
}

enum FingerprintEvidenceEnvelopeCodec {
    static let maximumPayloadBytes = 4 * 1_024 * 1_024
    static let maximumManifestBytes = 1 * 1_024 * 1_024
    static let maximumEnvelopeBytes =
        ((maximumPayloadBytes + 2) / 3) * 4 + 4_096
    private static let transcriptDomain =
        Data("NeAntik GUI fingerprint evidence v8\u{0}".utf8)

    static func make(
        payload: Data,
        candidateManifest: Data,
        signer: FingerprintEvidenceSigning
    ) throws -> FingerprintEvidenceEnvelope {
        guard payload.count <= maximumPayloadBytes else {
            throw FingerprintEvidenceError.payloadTooLarge
        }
        guard isCurrentAuditPayload(payload) else {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        guard candidateManifest.count <= maximumManifestBytes else {
            throw FingerprintEvidenceError.manifestTooLarge
        }
        let binding = try manifestBinding(in: candidateManifest)
        let validated = try binding.validated()
        guard signer.publicKeyX963 == validated.publicKey.x963Representation
        else {
            throw FingerprintEvidenceError.signingAuthorityMismatch
        }

        let manifestDigest = SHA256.hash(data: candidateManifest)
        let challengeDigest = SHA256.hash(data: validated.challenge)
        let signature = try signer.signatureDER(
            for: transcript(
                payload: payload,
                candidateManifestDigest: Data(manifestDigest),
                sessionID: binding.sessionID,
                challenge: validated.challenge
            )
        )
        return FingerprintEvidenceEnvelope(
            schemaVersion: FingerprintEvidenceEnvelope.currentSchemaVersion,
            kind: FingerprintEvidenceEnvelope.kindName,
            payloadEncoding:
                FingerprintEvidenceEnvelope.payloadEncodingName,
            payload: payload.base64EncodedString(),
            authentication: FingerprintEvidenceAuthentication(
                algorithm:
                    FingerprintEvidenceManifestBinding.algorithmName,
                keyID: binding.authorityKeyID,
                candidateManifestSHA256: hex(manifestDigest),
                sessionID: binding.sessionID,
                challengeSHA256: hex(challengeDigest),
                signatureDER: signature.base64EncodedString()
            )
        )
    }

    static func verify(
        _ envelopeData: Data,
        candidateManifest: Data
    ) throws -> Data {
        guard envelopeData.count <= maximumEnvelopeBytes,
              hasExactEnvelopeKeys(envelopeData)
        else {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        let envelope: FingerprintEvidenceEnvelope
        do {
            envelope = try JSONDecoder().decode(
                FingerprintEvidenceEnvelope.self,
                from: envelopeData
            )
        } catch {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        guard candidateManifest.count <= maximumManifestBytes else {
            throw FingerprintEvidenceError.manifestTooLarge
        }
        let binding = try manifestBinding(in: candidateManifest)
        let validated = try binding.validated()
        guard envelope.schemaVersion ==
                FingerprintEvidenceEnvelope.currentSchemaVersion,
              envelope.kind == FingerprintEvidenceEnvelope.kindName,
              envelope.payloadEncoding ==
                FingerprintEvidenceEnvelope.payloadEncodingName,
              envelope.payload.utf8.count <=
                ((maximumPayloadBytes + 2) / 3) * 4,
              let payload = Data(base64Encoded: envelope.payload),
              payload.count <= maximumPayloadBytes,
              envelope.payload == payload.base64EncodedString(),
              envelope.authentication.signatureDER.utf8.count <= 128,
              let signatureData = Data(
                  base64Encoded: envelope.authentication.signatureDER
              ),
              envelope.authentication.signatureDER ==
                signatureData.base64EncodedString()
        else {
            throw FingerprintEvidenceError.malformedEnvelope
        }

        let manifestDigest = SHA256.hash(data: candidateManifest)
        let challengeDigest = SHA256.hash(data: validated.challenge)
        guard envelope.authentication.algorithm ==
                FingerprintEvidenceManifestBinding.algorithmName,
              envelope.authentication.keyID == binding.authorityKeyID,
              envelope.authentication.candidateManifestSHA256 ==
                hex(manifestDigest),
              envelope.authentication.sessionID == binding.sessionID,
              envelope.authentication.challengeSHA256 ==
                hex(challengeDigest)
        else {
            throw FingerprintEvidenceError.bindingMismatch
        }

        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(
                derRepresentation: signatureData
            )
        } catch {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        let signedTranscript = transcript(
            payload: payload,
            candidateManifestDigest: Data(manifestDigest),
            sessionID: binding.sessionID,
            challenge: validated.challenge
        )
        guard validated.publicKey.isValidSignature(
            signature,
            for: signedTranscript
        ) else {
            throw FingerprintEvidenceError.invalidSignature
        }
        guard isCurrentAuditPayload(payload) else {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        return payload
    }

    static func encode(
        _ envelope: FingerprintEvidenceEnvelope
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    static func manifestBinding(
        in candidateManifest: Data
    ) throws -> FingerprintEvidenceManifestBinding {
        guard candidateManifest.count <= maximumManifestBytes else {
            throw FingerprintEvidenceError.manifestTooLarge
        }
        guard hasExactBindingKeys(candidateManifest) else {
            throw FingerprintEvidenceError.invalidManifestBinding
        }
        do {
            return try JSONDecoder().decode(
                CandidateManifestBindingContainer.self,
                from: candidateManifest
            ).fingerprintEvidence
        } catch {
            throw FingerprintEvidenceError.invalidManifestBinding
        }
    }

    private static func hasExactEnvelopeKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              canonical == data,
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == [
                  "schemaVersion",
                  "kind",
                  "payloadEncoding",
                  "payload",
                  "authentication"
              ],
              let authentication =
                dictionary["authentication"] as? [String: Any],
              Set(authentication.keys) == [
                  "algorithm",
                  "keyID",
                  "candidateManifestSHA256",
                  "sessionID",
                  "challengeSHA256",
                  "signatureDER"
              ]
        else {
            return false
        }
        return true
    }

    private static func hasExactBindingKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              canonical == data,
              let dictionary = object as? [String: Any],
              let binding =
                dictionary["fingerprintEvidence"] as? [String: Any],
              Set(binding.keys) == [
                  "schemaVersion",
                  "algorithm",
                  "authorityKeyID",
                  "publicKeyX963",
                  "sessionID",
                  "challenge"
              ]
        else {
            return false
        }
        return true
    }

    private static func isCurrentAuditPayload(_ data: Data) -> Bool {
        guard !data.isEmpty,
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any],
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              canonical == data
        else {
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let report = try? decoder.decode(
            FingerprintAuditReport.self,
            from: data
        ) else {
            return false
        }
        return report.auditSchemaVersion ==
            FingerprintAuditReport.currentAuditSchemaVersion
    }

    private static func transcript(
        payload: Data,
        candidateManifestDigest: Data,
        sessionID: UUID,
        challenge: Data
    ) -> Data {
        var result = transcriptDomain
        result.append(candidateManifestDigest)
        result.append(Data(sessionID.uuidString.lowercased().utf8))
        result.append(challenge)
        result.append(Data(SHA256.hash(data: payload)))
        return result
    }

    private static func hex<H: Sequence>(_ digest: H) -> String
    where H.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct CandidateManifestBindingContainer: Decodable {
    let fingerprintEvidence: FingerprintEvidenceManifestBinding
}
