import CryptoKit
import Foundation
import Testing
@testable import NeAntik

struct UpdateManifestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func disabledBundleConfigurationDoesNotRetainPartialTrustMaterial() {
        let configuration = UpdateChannelConfiguration.fromInfoDictionary([
            UpdateChannelConfiguration.enabledKey: false,
            UpdateChannelConfiguration.manifestURLKey:
                "https://affpapa.org/neantik/update.json",
            UpdateChannelConfiguration.publicKeyIDKey: "release-2026",
            UpdateChannelConfiguration.publicKeyKey:
                Data(repeating: 7, count: 32).base64EncodedString()
        ])

        #expect(!configuration.isEnabled)
        #expect(configuration.manifestURL == nil)
        #expect(configuration.publicKeyID == nil)
        #expect(configuration.publicKey == nil)
    }

    @Test
    func rejectsInvalidConfiguredURLAndPublicKey() {
        let configuration = UpdateChannelConfiguration.fromInfoDictionary([
            UpdateChannelConfiguration.enabledKey: true,
            UpdateChannelConfiguration.manifestURLKey:
                "https://user:password@example.com/update.json",
            UpdateChannelConfiguration.publicKeyIDKey: "bad key id",
            UpdateChannelConfiguration.publicKeyKey:
                Data(repeating: 1, count: 31).base64EncodedString()
        ])

        #expect(!configuration.isEnabled)
    }

    @Test
    func verifiesSignedPublicNotarizedArm64Update() throws {
        let key = Curve25519.Signing.PrivateKey()
        let configuration = configuredChannel(publicKey: key.publicKey)
        let payload = validPayload()
        let envelope = try signedEnvelope(payload: payload, key: key)

        let verified = try UpdateManifestVerifier.verify(
            envelope,
            configuration: configuration,
            installedVersion: "0.3.12",
            installedBuild: 15,
            now: now
        )

        #expect(verified.payload == payload)
        #expect(verified.isNewerThanInstalled)
    }

    @Test
    func rejectsPayloadChangedAfterSigning() throws {
        let key = Curve25519.Signing.PrivateKey()
        let configuration = configuredChannel(publicKey: key.publicKey)
        var envelope = try JSONDecoder().decode(
            SignedUpdateEnvelope.self,
            from: signedEnvelope(payload: validPayload(), key: key)
        )
        let payloadData = try #require(Data(base64Encoded: envelope.payload))
        var changed = payloadData
        changed[changed.startIndex] ^= 1
        envelope = SignedUpdateEnvelope(
            schemaVersion: envelope.schemaVersion,
            algorithm: envelope.algorithm,
            keyID: envelope.keyID,
            payload: changed.base64EncodedString(),
            signature: envelope.signature
        )

        #expect(throws: UpdateManifestError.invalidSignature) {
            try UpdateManifestVerifier.verify(
                JSONEncoder().encode(envelope),
                configuration: configuration,
                installedVersion: "0.3.12",
                installedBuild: 15,
                now: now
            )
        }
    }

    @Test
    func rejectsSignedButExpiredManifest() throws {
        let key = Curve25519.Signing.PrivateKey()
        let configuration = configuredChannel(publicKey: key.publicKey)
        let payload = validPayload(
            issuedAt: now.addingTimeInterval(-20 * 24 * 60 * 60),
            expiresAt: now.addingTimeInterval(-6 * 24 * 60 * 60)
        )

        #expect(throws: UpdateManifestError.expired) {
            try UpdateManifestVerifier.verify(
                signedEnvelope(payload: payload, key: key),
                configuration: configuration,
                installedVersion: "0.3.12",
                installedBuild: 15,
                now: now
            )
        }
    }

    @Test
    func rejectsSignedArchiveWithWrongPlatformContract() throws {
        let key = Curve25519.Signing.PrivateKey()
        let configuration = configuredChannel(publicKey: key.publicKey)
        let source = validPayload()
        let payload = UpdateManifestPayload(
            schemaVersion: source.schemaVersion,
            product: source.product,
            edition: source.edition,
            version: source.version,
            build: source.build,
            issuedAt: source.issuedAt,
            expiresAt: source.expiresAt,
            archiveName: source.archiveName,
            downloadURL: source.downloadURL,
            sha256: source.sha256,
            minimumOS: source.minimumOS,
            architecture: "x86_64",
            artifactKind: source.artifactKind,
            publicReleaseState: source.publicReleaseState,
            chromiumVersion: source.chromiumVersion
        )

        #expect(throws: UpdateManifestError.invalidReleaseContract) {
            try UpdateManifestVerifier.verify(
                signedEnvelope(payload: payload, key: key),
                configuration: configuration,
                installedVersion: "0.3.12",
                installedBuild: 15,
                now: now
            )
        }
    }

    @Test
    func currentReleaseCanBeVerifiedWithoutBeingReportedAsNewer() throws {
        let key = Curve25519.Signing.PrivateKey()
        let configuration = configuredChannel(publicKey: key.publicKey)
        let source = validPayload()
        let payload = UpdateManifestPayload(
            schemaVersion: source.schemaVersion,
            product: source.product,
            edition: source.edition,
            version: "0.3.12",
            build: 15,
            issuedAt: source.issuedAt,
            expiresAt: source.expiresAt,
            archiveName: "NeAntik-0.3.12-arm64-notarized.zip",
            downloadURL:
                "https://affpapa.org/neantik/downloads/NeAntik-0.3.12-arm64-notarized.zip",
            sha256: source.sha256,
            minimumOS: source.minimumOS,
            architecture: source.architecture,
            artifactKind: source.artifactKind,
            publicReleaseState: source.publicReleaseState,
            chromiumVersion: source.chromiumVersion
        )

        let verified = try UpdateManifestVerifier.verify(
            signedEnvelope(payload: payload, key: key),
            configuration: configuration,
            installedVersion: "0.3.12",
            installedBuild: 15,
            now: now
        )

        #expect(!verified.isNewerThanInstalled)
    }

    private func configuredChannel(
        publicKey: Curve25519.Signing.PublicKey
    ) -> UpdateChannelConfiguration {
        UpdateChannelConfiguration(
            isEnabled: true,
            manifestURL: URL(
                string: "https://affpapa.org/neantik/update.json"
            ),
            publicKeyID: "release-2026",
            publicKey: publicKey.rawRepresentation
        )
    }

    private func validPayload(
        issuedAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> UpdateManifestPayload {
        UpdateManifestPayload(
            schemaVersion: 1,
            product: "NeAntik",
            edition: "Direct",
            version: "0.3.13",
            build: 16,
            issuedAt: issuedAt ?? now.addingTimeInterval(-60),
            expiresAt: expiresAt ?? now.addingTimeInterval(7 * 24 * 60 * 60),
            archiveName: "NeAntik-0.3.13-arm64-notarized.zip",
            downloadURL:
                "https://affpapa.org/neantik/downloads/NeAntik-0.3.13-arm64-notarized.zip",
            sha256: String(repeating: "a", count: 64),
            minimumOS: "14.0",
            architecture: "arm64",
            artifactKind: "public-notarized",
            publicReleaseState: "public-ready",
            chromiumVersion: "150.0.7871.186"
        )
    }

    private func signedEnvelope(
        payload: UpdateManifestPayload,
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        payloadEncoder.dateEncodingStrategy = .iso8601
        let payloadData = try payloadEncoder.encode(payload)
        let signature = try key.signature(for: payloadData)
        let envelope = SignedUpdateEnvelope(
            schemaVersion: 1,
            algorithm: "Ed25519",
            keyID: "release-2026",
            payload: payloadData.base64EncodedString(),
            signature: signature.base64EncodedString()
        )
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try envelopeEncoder.encode(envelope)
    }
}
