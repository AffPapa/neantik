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

    init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(
            rawRepresentation: rawRepresentation
        )
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
    private static let p256Order: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
        0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51
    ]
    private static let p256HalfOrder: [UInt8] = [
        0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
        0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8
    ]
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
        let releaseChannel =
            try manifestReleaseChannel(in: candidateManifest)
        guard releasePayloadChannel(in: payload) == releaseChannel else {
            throw FingerprintEvidenceError.bindingMismatch
        }
        let validated = try binding.validated()
        guard signer.publicKeyX963 == validated.publicKey.x963Representation
        else {
            throw FingerprintEvidenceError.signingAuthorityMismatch
        }

        let manifestDigest = SHA256.hash(data: candidateManifest)
        let challengeDigest = SHA256.hash(data: validated.challenge)
        let signature = try canonicalLowSSignatureDER(
            try signer.signatureDER(
                for: transcript(
                    payload: payload,
                    candidateManifestDigest: Data(manifestDigest),
                    sessionID: binding.sessionID,
                    challenge: validated.challenge
                )
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
        let releaseChannel =
            try manifestReleaseChannel(in: candidateManifest)
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

        let signature = try validatedLowSSignature(signatureData)
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
        guard releasePayloadChannel(in: payload) == releaseChannel else {
            throw FingerprintEvidenceError.bindingMismatch
        }
        return payload
    }

    static func encode(
        _ envelope: FingerprintEvidenceEnvelope
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
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
            let container = try JSONDecoder().decode(
                CandidateManifestBindingContainer.self,
                from: candidateManifest
            )
            guard container.schemaVersion == 3 else {
                throw FingerprintEvidenceError.invalidManifestBinding
            }
            return container.fingerprintEvidence
        } catch {
            throw FingerprintEvidenceError.invalidManifestBinding
        }
    }

    static func manifestReleaseChannel(
        in candidateManifest: Data
    ) throws -> FingerprintEvidenceReleaseChannel {
        guard hasExactBindingKeys(candidateManifest) else {
            throw FingerprintEvidenceError.invalidManifestBinding
        }
        do {
            let container = try JSONDecoder().decode(
                CandidateManifestBindingContainer.self,
                from: candidateManifest
            )
            guard container.schemaVersion == 3,
                  container.kind ==
                    "neantik-direct-prepared-candidate"
            else {
                throw FingerprintEvidenceError.invalidManifestBinding
            }
            return container.releaseChannel
        } catch {
            throw FingerprintEvidenceError.invalidManifestBinding
        }
    }

    private static func hasExactEnvelopeKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
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
              ],
              isUppercaseCanonicalUUID(authentication["sessionID"])
        else {
            return false
        }
        return true
    }

    private static func hasExactBindingKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              canonical == data,
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == [
                  "boundary", "bundle", "bundleInventory",
                  "criticalFiles", "fingerprintEvidence", "kind",
                  "preparedAt", "postPreparationMutablePaths",
                  "releaseChannel", "schemaVersion"
              ],
              dictionary["schemaVersion"] as? Int == 3,
              dictionary["kind"] as? String ==
                "neantik-direct-prepared-candidate",
              let channel =
                dictionary["releaseChannel"] as? String,
              FingerprintEvidenceReleaseChannel(
                  rawValue: channel
              ) != nil,
              let binding =
                dictionary["fingerprintEvidence"] as? [String: Any],
              Set(binding.keys) == [
                  "schemaVersion",
                  "algorithm",
                  "authorityKeyID",
                  "publicKeyX963",
                  "sessionID",
                  "challenge"
              ],
              isUppercaseCanonicalUUID(binding["sessionID"])
        else {
            return false
        }
        return true
    }

    private static func isCurrentAuditPayload(_ data: Data) -> Bool {
        guard !data.isEmpty,
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == [
                  "schemaVersion", "kind", "createdAt",
                  "releaseChannel", "managerVersion", "managerBuild",
                  "runtimeName", "runtimeVersion", "runtimeFlavor",
                  "runtimeCodeSignatureValid",
                  "runtimeExecutableSHA256",
                  "runtimeFrameworkSHA256", "auditSchemaVersion",
                  "identityCatalogVersion", "executionMode",
                  "verdict", "criticalSurfaces",
                  "changedCriticalKeys", "unavailableRequiredKeys",
                  "unstableRequiredKeys", "profileSequenceValid",
                  "identitySequenceValid", "crossRealmConsistent",
                  "deviceTupleConsistent", "networkPrivacyControlled",
                  "publicAlphaQualified", "productionQualified",
                  "limitations"
              ],
              isCanonicalUTCSecondTimestamp(
                  dictionary["createdAt"]
              ),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              canonical == data
        else {
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(
            FingerprintReleaseEvidencePayload.self,
            from: data
        ),
              payload.schemaVersion ==
                FingerprintReleaseEvidencePayload
                    .currentSchemaVersion,
              payload.kind ==
                FingerprintReleaseEvidencePayload.kindName,
              payload.auditSchemaVersion ==
                FingerprintAuditReport.currentAuditSchemaVersion,
              payload.identityCatalogVersion ==
                BrowserIdentityCatalog.currentVersion,
              payload.executionMode ==
                FingerprintAuditExecutionMode.browser.rawValue,
              payload.verdict ==
                FingerprintAuditVerdict.verified.rawValue,
              payload.runtimeCodeSignatureValid,
              isLowerSHA256(payload.runtimeExecutableSHA256),
              isLowerSHA256(payload.runtimeFrameworkSHA256),
              !payload.managerVersion.isEmpty,
              !payload.managerBuild.isEmpty,
              !payload.runtimeName.isEmpty,
              !payload.runtimeVersion.isEmpty,
              payload.profileSequenceValid,
              payload.identitySequenceValid,
              payload.publicAlphaQualified,
              Set(payload.criticalSurfaces.keys) ==
                Set(FingerprintAuditReport.criticalKeys),
              payload.criticalSurfaces["webgl_pixels"] ==
                .stableDifferent,
              payload.criticalSurfaces.values.filter({
                  $0 == .stableDifferent
              }).count >= 2,
              payload.changedCriticalKeys ==
                payload.changedCriticalKeys.sorted(),
              payload.changedCriticalKeys ==
                payload.criticalSurfaces.compactMap({
                    $0.value == .stableDifferent ? $0.key : nil
                }).sorted(),
              payload.unavailableRequiredKeys ==
                payload.unavailableRequiredKeys.sorted(),
              payload.unstableRequiredKeys ==
                payload.unstableRequiredKeys.sorted(),
              Set(payload.changedCriticalKeys).isSubset(
                  of: Set(FingerprintAuditReport.criticalKeys)
              ),
              payload.releaseChannel != .production ||
                (
                    payload.productionQualified &&
                    payload.crossRealmConsistent &&
                    payload.deviceTupleConsistent &&
                    payload.networkPrivacyControlled &&
                    payload.unavailableRequiredKeys.isEmpty &&
                    payload.unstableRequiredKeys.isEmpty &&
                    payload.limitations.isEmpty
                ),
              payload.productionQualified
                ? payload.limitations.isEmpty
                : payload.limitations ==
                    ["strict-coherence-not-qualified"]
        else {
            return false
        }
        return true
    }

    private static func releasePayloadChannel(
        in data: Data
    ) -> FingerprintEvidenceReleaseChannel? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(
            FingerprintReleaseEvidencePayload.self,
            from: data
        ).releaseChannel
    }

    private static func isLowerSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func canonicalLowSSignatureDER(
        _ data: Data
    ) throws -> Data {
        let signature = try decodedCanonicalSignature(data)
        var raw = [UInt8](signature.rawRepresentation)
        guard raw.count == 64 else {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        let r = Array(raw[0..<32])
        var s = Array(raw[32..<64])
        guard isValidScalar(r), isValidScalar(s) else {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        if compareScalar(s, p256HalfOrder) == .orderedDescending {
            s = subtractScalar(p256Order, s)
            raw.replaceSubrange(32..<64, with: s)
        }
        do {
            return try P256.Signing.ECDSASignature(
                rawRepresentation: Data(raw)
            ).derRepresentation
        } catch {
            throw FingerprintEvidenceError.malformedEnvelope
        }
    }

    private static func validatedLowSSignature(
        _ data: Data
    ) throws -> P256.Signing.ECDSASignature {
        let signature = try decodedCanonicalSignature(data)
        let raw = [UInt8](signature.rawRepresentation)
        guard raw.count == 64 else {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        let r = Array(raw[0..<32])
        let s = Array(raw[32..<64])
        guard isValidScalar(r), isValidScalar(s) else {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        guard compareScalar(s, p256HalfOrder) != .orderedDescending else {
            throw FingerprintEvidenceError.invalidSignature
        }
        return signature
    }

    private static func decodedCanonicalSignature(
        _ data: Data
    ) throws -> P256.Signing.ECDSASignature {
        guard (8...72).contains(data.count) else {
            throw FingerprintEvidenceError.malformedEnvelope
        }
        do {
            let signature = try P256.Signing.ECDSASignature(
                derRepresentation: data
            )
            guard signature.derRepresentation == data else {
                throw FingerprintEvidenceError.malformedEnvelope
            }
            return signature
        } catch let error as FingerprintEvidenceError {
            throw error
        } catch {
            throw FingerprintEvidenceError.malformedEnvelope
        }
    }

    private static func isValidScalar(_ value: [UInt8]) -> Bool {
        value.count == 32 &&
            value.contains(where: { $0 != 0 }) &&
            compareScalar(value, p256Order) == .orderedAscending
    }

    private static func isUppercaseCanonicalUUID(_ value: Any?) -> Bool {
        guard let string = value as? String,
              let uuid = UUID(uuidString: string)
        else {
            return false
        }
        return uuid.uuidString == string
    }

    private static func hasUppercaseCanonicalPayloadUUIDs(
        _ report: [String: Any]
    ) -> Bool {
        let allowedKeys: Set<String> = [
            "id", "createdAt", "auditSchemaVersion",
            "identityCatalogVersion", "managerVersion", "managerBuild",
            "runtimeName", "runtimeVersion", "runtimeFlavor",
            "runtimeCodeSignatureValid", "runtimeExecutableSHA256",
            "runtimeFrameworkSHA256", "executionMode",
            "webrtcDirectControl", "firstInitial", "second",
            "firstRepeat"
        ]
        let requiredKeys: Set<String> = [
            "id", "createdAt", "auditSchemaVersion", "runtimeName",
            "runtimeFlavor", "firstInitial", "second", "firstRepeat"
        ]
        guard Set(report.keys).isSubset(of: allowedKeys),
              requiredKeys.isSubset(of: Set(report.keys)),
              isUppercaseCanonicalUUID(report["id"]),
              isCanonicalUTCSecondTimestamp(report["createdAt"])
        else {
            return false
        }
        for key in ["firstInitial", "second", "firstRepeat"] {
            guard let capture = report[key] as? [String: Any],
                  Set(capture.keys) == [
                      "profileID", "profileName", "identityCode",
                      "capturedAt", "values"
                  ],
                  isUppercaseCanonicalUUID(capture["profileID"]),
                  isCanonicalUTCSecondTimestamp(capture["capturedAt"])
            else {
                return false
            }
        }
        if let directControl = report["webrtcDirectControl"],
           !(directControl is NSNull)
        {
            guard let capture = directControl as? [String: Any],
                  Set(capture.keys) == [
                      "profileID", "profileName", "identityCode",
                      "capturedAt", "values"
                  ],
                  isUppercaseCanonicalUUID(capture["profileID"]),
                  isCanonicalUTCSecondTimestamp(capture["capturedAt"])
            else {
                return false
            }
        }
        return true
    }

    private static func isCanonicalUTCSecondTimestamp(
        _ value: Any?
    ) -> Bool {
        guard let string = value as? String,
              string.utf8.count == 20,
              string.hasSuffix("Z")
        else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime
        ]
        guard let date = formatter.date(from: string) else {
            return false
        }
        return formatter.string(from: date) == string
    }

    private static func compareScalar(
        _ left: [UInt8],
        _ right: [UInt8]
    ) -> ComparisonResult {
        for (leftByte, rightByte) in zip(left, right) {
            if leftByte < rightByte {
                return .orderedAscending
            }
            if leftByte > rightByte {
                return .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func subtractScalar(
        _ left: [UInt8],
        _ right: [UInt8]
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: left.count)
        var borrow = 0
        for index in stride(from: left.count - 1, through: 0, by: -1) {
            let minuend = Int(left[index])
            let subtrahend = Int(right[index]) + borrow
            if minuend >= subtrahend {
                result[index] = UInt8(minuend - subtrahend)
                borrow = 0
            } else {
                result[index] = UInt8(minuend + 256 - subtrahend)
                borrow = 1
            }
        }
        return result
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
    let schemaVersion: Int
    let kind: String
    let releaseChannel: FingerprintEvidenceReleaseChannel
    let fingerprintEvidence: FingerprintEvidenceManifestBinding
}
