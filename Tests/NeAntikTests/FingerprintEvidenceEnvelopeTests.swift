import Foundation
import Testing
@testable import NeAntik

struct FingerprintEvidenceEnvelopeTests {
    @Test
    func signsAndVerifiesExactPayloadAgainstExternalManifest() throws {
        let fixture = makeFixture()

        let envelope = try FingerprintEvidenceEnvelopeCodec.make(
            payload: fixture.payload,
            candidateManifest: fixture.manifest,
            signer: fixture.signer
        )

        #expect(
            try FingerprintEvidenceEnvelopeCodec.verify(
                encoded(envelope),
                candidateManifest: fixture.manifest
            ) == fixture.payload
        )
        #expect(
            envelope.authentication.keyID ==
                fixture.binding.authorityKeyID
        )
    }

    @Test
    func payloadBitFlipInvalidatesSignature() throws {
        let fixture = makeFixture()
        let envelope = try FingerprintEvidenceEnvelopeCodec.make(
            payload: fixture.payload,
            candidateManifest: fixture.manifest,
            signer: fixture.signer
        )
        var payload = Data(base64Encoded: envelope.payload)!
        payload[payload.startIndex] ^= 1
        let tampered = replacing(
            envelope,
            payload: payload.base64EncodedString()
        )

        #expect(throws: FingerprintEvidenceError.invalidSignature) {
            try FingerprintEvidenceEnvelopeCodec.verify(
                encoded(tampered),
                candidateManifest: fixture.manifest
            )
        }
    }

    @Test
    func manifestSessionChallengeAndAuthorityArePinned() throws {
        let fixture = makeFixture()
        let envelope = try FingerprintEvidenceEnvelopeCodec.make(
            payload: fixture.payload,
            candidateManifest: fixture.manifest,
            signer: fixture.signer
        )
        let otherSigner = SoftwareP256FingerprintEvidenceSigner()
        let wrongBindings = [
            FingerprintEvidenceManifestBinding(
                publicKeyX963: fixture.signer.publicKeyX963,
                sessionID: UUID(),
                challenge: fixture.challenge
            ),
            FingerprintEvidenceManifestBinding(
                publicKeyX963: fixture.signer.publicKeyX963,
                sessionID: fixture.binding.sessionID,
                challenge: Data(repeating: 7, count: 32)
            ),
            FingerprintEvidenceManifestBinding(
                publicKeyX963: otherSigner.publicKeyX963,
                sessionID: fixture.binding.sessionID,
                challenge: fixture.challenge
            )
        ]

        for binding in wrongBindings {
            #expect(throws: FingerprintEvidenceError.self) {
                try FingerprintEvidenceEnvelopeCodec.verify(
                    encoded(envelope),
                    candidateManifest: manifest(for: binding)
                )
            }
        }
        #expect(throws: FingerprintEvidenceError.invalidManifestBinding) {
            try FingerprintEvidenceEnvelopeCodec.verify(
                encoded(envelope),
                candidateManifest: fixture.manifest + Data([0x20])
            )
        }
    }

    @Test
    func selfSelectedSignerCannotReplaceManifestAuthority() throws {
        let fixture = makeFixture()
        let attacker = SoftwareP256FingerprintEvidenceSigner()

        #expect(
            throws: FingerprintEvidenceError.signingAuthorityMismatch
        ) {
            try FingerprintEvidenceEnvelopeCodec.make(
                payload: fixture.payload,
                candidateManifest: fixture.manifest,
                signer: attacker
            )
        }
    }

    @Test
    func malformedBindingAndOversizedInputsFailClosed() throws {
        let fixture = makeFixture()
        let malformed = FingerprintEvidenceManifestBinding(
            publicKeyX963: fixture.signer.publicKeyX963,
            sessionID: fixture.binding.sessionID,
            challenge: Data(repeating: 1, count: 31)
        )
        #expect(throws: FingerprintEvidenceError.invalidManifestBinding) {
            try malformed.validated()
        }
        #expect(throws: FingerprintEvidenceError.payloadTooLarge) {
            try FingerprintEvidenceEnvelopeCodec.make(
                payload: Data(
                    count:
                        FingerprintEvidenceEnvelopeCodec
                            .maximumPayloadBytes + 1
                ),
                candidateManifest: fixture.manifest,
                signer: fixture.signer
            )
        }
        #expect(throws: FingerprintEvidenceError.manifestTooLarge) {
            try FingerprintEvidenceEnvelopeCodec.make(
                payload: fixture.payload,
                candidateManifest: Data(
                    count:
                        FingerprintEvidenceEnvelopeCodec
                            .maximumManifestBytes + 1
                ),
                signer: fixture.signer
            )
        }
        for payload in [
            Data(),
            Data("not-json".utf8),
            Data("[]".utf8),
            Data("{\"auditSchemaVersion\":6}".utf8)
        ] {
            #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
                try FingerprintEvidenceEnvelopeCodec.make(
                    payload: payload,
                    candidateManifest: fixture.manifest,
                    signer: fixture.signer
                )
            }
        }
    }

    @Test
    func rawEnvelopeRejectsUnknownFieldsAndOversizedInput() throws {
        let fixture = makeFixture()
        let envelope = try FingerprintEvidenceEnvelopeCodec.make(
            payload: fixture.payload,
            candidateManifest: fixture.manifest,
            signer: fixture.signer
        )
        let raw = String(data: encoded(envelope), encoding: .utf8)!
        let unknownTopLevel = Data(
            raw.replacingOccurrences(
                of: "\"schemaVersion\":8",
                with: "\"unsignedSecret\":\"no\",\"schemaVersion\":8"
            ).utf8
        )
        let unknownAuthentication = Data(
            raw.replacingOccurrences(
                of: "\"algorithm\":\"P256-SHA256\"",
                with:
                    "\"unsignedPath\":\"/private\",\"algorithm\":\"P256-SHA256\""
            ).utf8
        )
        let duplicateTopLevel = Data(
            raw.replacingOccurrences(
                of: "\"kind\":\"neantik-gui-fingerprint-evidence\"",
                with:
                    "\"kind\":\"duplicate\",\"kind\":\"neantik-gui-fingerprint-evidence\""
            ).utf8
        )
        let noncanonicalEnvelope = encoded(envelope) + Data([0x20])

        for candidate in [
            unknownTopLevel,
            unknownAuthentication,
            duplicateTopLevel,
            noncanonicalEnvelope
        ] {
            #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
                try FingerprintEvidenceEnvelopeCodec.verify(
                    candidate,
                    candidateManifest: fixture.manifest
                )
            }
        }
        #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
            try FingerprintEvidenceEnvelopeCodec.verify(
                Data(
                    count:
                        FingerprintEvidenceEnvelopeCodec
                            .maximumEnvelopeBytes + 1
                ),
                candidateManifest: fixture.manifest
            )
        }
        let bindingData = String(
            data: fixture.manifest,
            encoding: .utf8
        )!.replacingOccurrences(
            of: "\"algorithm\":\"P256-SHA256\"",
            with:
                "\"unknownBindingField\":true,\"algorithm\":\"P256-SHA256\""
        )
        #expect(throws: FingerprintEvidenceError.invalidManifestBinding) {
            try FingerprintEvidenceEnvelopeCodec.make(
                payload: fixture.payload,
                candidateManifest: Data(bindingData.utf8),
                signer: fixture.signer
            )
        }
        let duplicateBinding = Data(
            String(
                data: fixture.manifest,
                encoding: .utf8
            )!.replacingOccurrences(
                of: "\"algorithm\":\"P256-SHA256\"",
                with:
                    "\"algorithm\":\"duplicate\",\"algorithm\":\"P256-SHA256\""
            ).utf8
        )
        let duplicateRoot = Data(
            String(
                data: fixture.manifest,
                encoding: .utf8
            )!.replacingOccurrences(
                of: "\"fingerprintEvidence\":",
                with:
                    "\"fingerprintEvidence\":null,\"fingerprintEvidence\":"
            ).utf8
        )
        for manifest in [
            duplicateBinding,
            duplicateRoot,
            fixture.manifest + Data([0x20])
        ] {
            #expect(throws: FingerprintEvidenceError.invalidManifestBinding) {
                try FingerprintEvidenceEnvelopeCodec.make(
                    payload: fixture.payload,
                    candidateManifest: manifest,
                    signer: fixture.signer
                )
            }
        }
    }

    private func makeFixture() -> (
        signer: SoftwareP256FingerprintEvidenceSigner,
        binding: FingerprintEvidenceManifestBinding,
        challenge: Data,
        manifest: Data,
        payload: Data
    ) {
        let signer = SoftwareP256FingerprintEvidenceSigner()
        let challenge = Data((0..<32).map(UInt8.init))
        let binding = FingerprintEvidenceManifestBinding(
            publicKeyX963: signer.publicKeyX963,
            sessionID: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            )!,
            challenge: challenge
        )
        return (
            signer,
            binding,
            challenge,
            manifest(for: binding),
            payload()
        )
    }

    private func manifest(
        for binding: FingerprintEvidenceManifestBinding
    ) -> Data {
        let bindingData = try! JSONEncoder().encode(binding)
        let bindingObject = try! JSONSerialization.jsonObject(
            with: bindingData
        )
        return try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 3,
                "fingerprintEvidence": bindingObject
            ],
            options: [.sortedKeys]
        )
    }

    private func payload() -> Data {
        let firstID = UUID(
            uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        )!
        let secondID = UUID(
            uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        )!
        let first = FingerprintCapture(
            profileID: firstID,
            profileName: "Профиль A",
            identityCode: "NA-00000001",
            capturedAt: Date(timeIntervalSince1970: 1),
            values: ["canvas": "a"]
        )
        let second = FingerprintCapture(
            profileID: secondID,
            profileName: "Профиль B",
            identityCode: "NA-00000002",
            capturedAt: Date(timeIntervalSince1970: 2),
            values: ["canvas": "b"]
        )
        let report = FingerprintAuditReport(
            id: UUID(
                uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
            )!,
            createdAt: Date(timeIntervalSince1970: 3),
            managerVersion: "0.3.12",
            managerBuild: "15",
            runtimeName: "NeAntik Browser",
            runtimeVersion: "150.0.7871.186",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            runtimeExecutableSHA256: String(repeating: "a", count: 64),
            runtimeFrameworkSHA256: String(repeating: "b", count: 64),
            firstInitial: first,
            second: second,
            firstRepeat: first
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(report)
    }

    private func replacing(
        _ envelope: FingerprintEvidenceEnvelope,
        payload: String
    ) -> FingerprintEvidenceEnvelope {
        FingerprintEvidenceEnvelope(
            schemaVersion: envelope.schemaVersion,
            kind: envelope.kind,
            payloadEncoding: envelope.payloadEncoding,
            payload: payload,
            authentication: envelope.authentication
        )
    }

    private func encoded(
        _ envelope: FingerprintEvidenceEnvelope
    ) -> Data {
        try! FingerprintEvidenceEnvelopeCodec.encode(envelope)
    }
}
