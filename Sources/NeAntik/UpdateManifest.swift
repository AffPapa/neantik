import CryptoKit
import Foundation

struct UpdateChannelConfiguration: Equatable, Sendable {
    static let enabledKey = "NeAntikUpdateChannelEnabled"
    static let manifestURLKey = "NeAntikUpdateManifestURL"
    static let publicKeyIDKey = "NeAntikUpdatePublicKeyID"
    static let publicKeyKey = "NeAntikUpdatePublicKeyBase64"

    let isEnabled: Bool
    let manifestURL: URL?
    let publicKeyID: String?
    let publicKey: Data?

    static func fromBundle(_ bundle: Bundle = .main) -> Self {
        fromInfoDictionary(bundle.infoDictionary ?? [:])
    }

    static func fromInfoDictionary(_ dictionary: [String: Any]) -> Self {
        let enabled = dictionary[enabledKey] as? Bool ?? false
        let manifestURL = (dictionary[manifestURLKey] as? String)
            .flatMap(validatedManifestURL)
        let keyID = (dictionary[publicKeyIDKey] as? String)
            .flatMap(validatedKeyID)
        let publicKey = (dictionary[publicKeyKey] as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { $0.count == 32 ? $0 : nil }

        guard enabled,
              manifestURL != nil,
              keyID != nil,
              publicKey != nil
        else {
            return Self(
                isEnabled: false,
                manifestURL: nil,
                publicKeyID: nil,
                publicKey: nil
            )
        }
        return Self(
            isEnabled: true,
            manifestURL: manifestURL,
            publicKeyID: keyID,
            publicKey: publicKey
        )
    }

    private static func validatedManifestURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              isPublicManifestHost(host),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.query == nil,
              components.path.hasSuffix(".json")
        else {
            return nil
        }
        return components.url
    }

    private static func isPublicManifestHost(_ value: String) -> Bool {
        let host = value.lowercased()
        return host != "localhost" &&
            host != "::1" &&
            !host.hasPrefix("127.") &&
            !host.hasSuffix(".local") &&
            !host.hasSuffix(".test") &&
            !host.hasSuffix(".invalid") &&
            !host.hasSuffix(".example")
    }

    private static func validatedKeyID(_ value: String) -> String? {
        guard (1...64).contains(value.count),
              value.allSatisfy({
                  $0.isASCII &&
                      ($0.isLetter || $0.isNumber || "._-".contains($0))
              })
        else {
            return nil
        }
        return value
    }
}

struct SignedUpdateEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let algorithm: String
    let keyID: String
    let payload: String
    let signature: String
}

struct UpdateManifestPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let product: String
    let edition: String
    let version: String
    let build: Int
    let issuedAt: Date
    let expiresAt: Date
    let archiveName: String
    let downloadURL: String
    let sha256: String
    let minimumOS: String
    let architecture: String
    let artifactKind: String
    let publicReleaseState: String
    let chromiumVersion: String
}

struct VerifiedUpdateManifest: Equatable, Sendable {
    let payload: UpdateManifestPayload
    let isNewerThanInstalled: Bool
}

enum UpdateManifestError: LocalizedError, Equatable {
    case channelDisabled
    case malformedEnvelope
    case unsupportedEnvelope
    case invalidSignature
    case malformedPayload
    case expired
    case invalidReleaseContract

    var errorDescription: String? {
        switch self {
        case .channelDisabled:
            "Подписанный канал обновлений не настроен."
        case .malformedEnvelope:
            "Манифест обновления повреждён."
        case .unsupportedEnvelope:
            "Манифест подписан неизвестным ключом или алгоритмом."
        case .invalidSignature:
            "Подпись обновления недействительна."
        case .malformedPayload:
            "Подписанные данные обновления повреждены."
        case .expired:
            "Манифест обновления устарел."
        case .invalidReleaseContract:
            "Обновление не прошло проверку версии, архива или платформы."
        }
    }
}

enum UpdateManifestVerifier {
    private static let maximumLifetime: TimeInterval = 14 * 24 * 60 * 60
    private static let clockSkew: TimeInterval = 5 * 60

    static func verify(
        _ data: Data,
        configuration: UpdateChannelConfiguration,
        installedVersion: String,
        installedBuild: Int,
        now: Date = Date()
    ) throws -> VerifiedUpdateManifest {
        guard data.count <= 128 * 1_024 else {
            throw UpdateManifestError.malformedEnvelope
        }
        guard configuration.isEnabled,
              let expectedKeyID = configuration.publicKeyID,
              let publicKeyData = configuration.publicKey
        else {
            throw UpdateManifestError.channelDisabled
        }

        let envelope: SignedUpdateEnvelope
        do {
            envelope = try JSONDecoder().decode(
                SignedUpdateEnvelope.self,
                from: data
            )
        } catch {
            throw UpdateManifestError.malformedEnvelope
        }
        guard envelope.schemaVersion == 1,
              envelope.algorithm == "Ed25519",
              envelope.keyID == expectedKeyID
        else {
            throw UpdateManifestError.unsupportedEnvelope
        }
        guard envelope.payload.utf8.count <= 96 * 1_024,
              envelope.signature.utf8.count <= 128,
              let payloadData = Data(base64Encoded: envelope.payload),
              payloadData.count <= 64 * 1_024,
              let signature = Data(base64Encoded: envelope.signature),
              signature.count == 64
        else {
            throw UpdateManifestError.malformedEnvelope
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
            )
        } catch {
            throw UpdateManifestError.unsupportedEnvelope
        }
        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw UpdateManifestError.invalidSignature
        }

        let payload: UpdateManifestPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(
                UpdateManifestPayload.self,
                from: payloadData
            )
        } catch {
            throw UpdateManifestError.malformedPayload
        }

        let lifetime = payload.expiresAt.timeIntervalSince(payload.issuedAt)
        guard payload.issuedAt <= now.addingTimeInterval(clockSkew),
              payload.expiresAt >= now.addingTimeInterval(-clockSkew),
              lifetime > 0,
              lifetime <= maximumLifetime
        else {
            throw UpdateManifestError.expired
        }
        guard validReleaseContract(payload) else {
            throw UpdateManifestError.invalidReleaseContract
        }

        return VerifiedUpdateManifest(
            payload: payload,
            isNewerThanInstalled: compare(
                version: payload.version,
                build: payload.build,
                installedVersion: installedVersion,
                installedBuild: installedBuild
            ) == .orderedDescending
        )
    }

    private static func validReleaseContract(
        _ payload: UpdateManifestPayload
    ) -> Bool {
        guard payload.schemaVersion == 1,
              payload.product == "NeAntik",
              payload.edition == "Direct",
              payload.version.utf8.count <= 32,
              payload.chromiumVersion.utf8.count <= 32,
              payload.archiveName.utf8.count <= 200,
              payload.downloadURL.utf8.count <= 2_048,
              payload.minimumOS.utf8.count <= 16,
              payload.build > 0,
              semanticVersion(payload.version) != nil,
              semanticVersion(payload.chromiumVersion) != nil,
              let minimumOS = operatingSystemVersion(payload.minimumOS),
              versionComponents(minimumOS, areAtLeast: [14, 0, 0]),
              payload.architecture == "arm64",
              payload.artifactKind == "public-notarized",
              payload.publicReleaseState == "public-ready",
              payload.sha256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              payload.archiveName ==
                "NeAntik-\(payload.version)-arm64-notarized.zip",
              let components = URLComponents(string: payload.downloadURL),
              components.scheme == "https",
              let host = components.host,
              isPublicReleaseHost(host),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.query == nil,
              components.url?.lastPathComponent == payload.archiveName
        else {
            return false
        }
        return true
    }

    private static func isPublicReleaseHost(_ value: String) -> Bool {
        let host = value.lowercased()
        return host != "localhost" &&
            host != "::1" &&
            !host.hasPrefix("127.") &&
            !host.hasSuffix(".local") &&
            !host.hasSuffix(".test") &&
            !host.hasSuffix(".invalid") &&
            !host.hasSuffix(".example")
    }

    private static func versionComponents(
        _ value: [Int],
        areAtLeast minimum: [Int]
    ) -> Bool {
        let width = max(value.count, minimum.count)
        let left = value + Array(repeating: 0, count: width - value.count)
        let right = minimum +
            Array(repeating: 0, count: width - minimum.count)
        for (candidate, required) in zip(left, right)
            where candidate != required {
            return candidate > required
        }
        return true
    }

    private static func compare(
        version: String,
        build: Int,
        installedVersion: String,
        installedBuild: Int
    ) -> ComparisonResult {
        guard let candidate = semanticVersion(version),
              let installed = semanticVersion(installedVersion)
        else {
            return .orderedAscending
        }
        for (left, right) in zip(candidate, installed) where left != right {
            return left > right ? .orderedDescending : .orderedAscending
        }
        if build == installedBuild {
            return .orderedSame
        }
        return build > installedBuild ? .orderedDescending : .orderedAscending
    }

    private static func semanticVersion(_ value: String) -> [Int]? {
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (3...4).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  (part.count == 1 || part.first != "0")
            else {
                return nil
            }
            return Int(part)
        }
        guard numbers.count == parts.count else { return nil }
        return numbers + Array(repeating: 0, count: 4 - numbers.count)
    }

    private static func operatingSystemVersion(_ value: String) -> [Int]? {
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }
}
