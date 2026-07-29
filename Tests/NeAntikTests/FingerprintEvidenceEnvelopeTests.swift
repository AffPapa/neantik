import CryptoKit
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
    func producerNormalizesLowSAndVerifierRejectsHighSTwin() throws {
        let fixture = makeFixture()
        let envelope = try FingerprintEvidenceEnvelopeCodec.make(
            payload: fixture.payload,
            candidateManifest: fixture.manifest,
            signer: HighSSignatureTestSigner(base: fixture.signer)
        )
        let signatureData = Data(
            base64Encoded: envelope.authentication.signatureDER
        )!
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: signatureData
        )
        var raw = [UInt8](signature.rawRepresentation)
        let lowS = Array(raw[32..<64])
        #expect(
            compareScalar(lowS, p256HalfOrder) != .orderedDescending
        )

        let highS = subtractScalar(p256Order, lowS)
        #expect(
            compareScalar(highS, p256HalfOrder) == .orderedDescending
        )
        raw.replaceSubrange(32..<64, with: highS)
        let highSignature = try P256.Signing.ECDSASignature(
            rawRepresentation: Data(raw)
        ).derRepresentation
        let tampered = replacing(
            envelope,
            signatureDER: highSignature.base64EncodedString()
        )

        #expect(throws: FingerprintEvidenceError.invalidSignature) {
            try FingerprintEvidenceEnvelopeCodec.verify(
                encoded(tampered),
                candidateManifest: fixture.manifest
            )
        }
    }

    @Test
    func manifestRequiresSchemaThreeAndUppercaseUUIDWireFormat() throws {
        let fixture = makeFixture()
        let manifestText = try #require(
            String(data: fixture.manifest, encoding: .utf8)
        )
        #expect(
            manifestText.contains(
                "\"sessionID\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\""
            )
        )
        for schemaVersion in [2, 4] {
            #expect(throws: FingerprintEvidenceError.invalidManifestBinding) {
                try FingerprintEvidenceEnvelopeCodec.make(
                    payload: fixture.payload,
                    candidateManifest: manifest(
                        for: fixture.binding,
                        schemaVersion: schemaVersion
                    ),
                    signer: fixture.signer
                )
            }
        }
    }

    @Test
    func lowercaseUUIDsAndUnknownPayloadFieldsFailWireParity() throws {
        let fixture = makeFixture()
        let lowercaseManifest = Data(
            String(data: fixture.manifest, encoding: .utf8)!
                .replacingOccurrences(
                    of: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    with: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                )
                .utf8
        )
        #expect(throws: FingerprintEvidenceError.invalidManifestBinding) {
            try FingerprintEvidenceEnvelopeCodec.make(
                payload: fixture.payload,
                candidateManifest: lowercaseManifest,
                signer: fixture.signer
            )
        }

        let lowercasePayload = Data(
            String(data: fixture.payload, encoding: .utf8)!
                .replacingOccurrences(
                    of: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                    with: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                )
                .utf8
        )
        #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
            try FingerprintEvidenceEnvelopeCodec.make(
                payload: lowercasePayload,
                candidateManifest: fixture.manifest,
                signer: fixture.signer
            )
        }

        var report = try #require(
            JSONSerialization.jsonObject(with: fixture.payload)
                as? [String: Any]
        )
        report["unknown"] = true
        let unknownReport = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
            try FingerprintEvidenceEnvelopeCodec.make(
                payload: unknownReport,
                candidateManifest: fixture.manifest,
                signer: fixture.signer
            )
        }

        var capture = try #require(
            report["firstInitial"] as? [String: Any]
        )
        report.removeValue(forKey: "unknown")
        capture["unknown"] = true
        report["firstInitial"] = capture
        let unknownCapture = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
            try FingerprintEvidenceEnvelopeCodec.make(
                payload: unknownCapture,
                candidateManifest: fixture.manifest,
                signer: fixture.signer
            )
        }

        for invalidTimestamp in [
            "1970-01-01T00:00:03.123Z",
            "1970-01-01T07:00:03+07:00"
        ] {
            var invalidReport = try #require(
                JSONSerialization.jsonObject(with: fixture.payload)
                    as? [String: Any]
            )
            invalidReport["createdAt"] = invalidTimestamp
            let invalidReportData = try JSONSerialization.data(
                withJSONObject: invalidReport,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
                try FingerprintEvidenceEnvelopeCodec.make(
                    payload: invalidReportData,
                    candidateManifest: fixture.manifest,
                    signer: fixture.signer
                )
            }

            var invalidCapture = try #require(
                invalidReport["firstInitial"] as? [String: Any]
            )
            invalidReport["createdAt"] = "1970-01-01T00:00:03Z"
            invalidCapture["capturedAt"] = invalidTimestamp
            invalidReport["firstInitial"] = invalidCapture
            let invalidCaptureData = try JSONSerialization.data(
                withJSONObject: invalidReport,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
                try FingerprintEvidenceEnvelopeCodec.make(
                    payload: invalidCaptureData,
                    candidateManifest: fixture.manifest,
                    signer: fixture.signer
                )
            }
        }

        let envelope = try FingerprintEvidenceEnvelopeCodec.make(
            payload: fixture.payload,
            candidateManifest: fixture.manifest,
            signer: fixture.signer
        )
        let lowercaseEnvelope = Data(
            String(data: encoded(envelope), encoding: .utf8)!
                .replacingOccurrences(
                    of: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    with: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                )
                .utf8
        )
        #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
            try FingerprintEvidenceEnvelopeCodec.verify(
                lowercaseEnvelope,
                candidateManifest: fixture.manifest
            )
        }
    }

    @Test
    func opensslFixtureVerifiesInSwift() throws {
        let fixture = try schema8CrossLanguageFixture()
        let manifest = try #require(
            Data(base64Encoded: fixture.manifestBase64)
        )
        let payload = try #require(
            Data(base64Encoded: fixture.payloadBase64)
        )
        let envelopeData = try #require(
            Data(base64Encoded: fixture.envelopeBase64)
        )
        let envelope = try JSONDecoder().decode(
            FingerprintEvidenceEnvelope.self,
            from: envelopeData
        )
        let opensslEnvelope = replacing(
            envelope,
            signatureDER: fixture.opensslSignatureBase64
        )
        let opensslEnvelopeData = encoded(opensslEnvelope)

        #expect(
            try FingerprintEvidenceEnvelopeCodec.verify(
                opensslEnvelopeData,
                candidateManifest: manifest
            ) == payload
        )
        #expect(
            SHA256.hash(data: opensslEnvelopeData)
                .map { String(format: "%02x", $0) }
                .joined() == fixture.opensslTransportSHA256
        )
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
        let escapedSlashManifest = Data(
            String(
                data: fixture.manifest,
                encoding: .utf8
            )!.replacingOccurrences(
                of: "Contents/MacOS/NeAntik",
                with: "Contents\\/MacOS\\/NeAntik"
            ).utf8
        )
        for manifest in [
            duplicateBinding,
            duplicateRoot,
            escapedSlashManifest,
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

    @Test
    func verifierRejectsMalformedDERScalarEncodings() throws {
        let fixture = makeFixture()
        let envelope = try FingerprintEvidenceEnvelopeCodec.make(
            payload: fixture.payload,
            candidateManifest: fixture.manifest,
            signer: fixture.signer
        )
        let orderScalar = Data(
            [0x30, 0x26, 0x02, 0x21, 0x00] +
                p256Order +
                [0x02, 0x01, 0x01]
        )
        let malformedSignatures = [
            Data(),
            Data([0x30, 0x06, 0x02, 0x01, 0x00, 0x02, 0x01, 0x01]),
            Data([
                0x30, 0x07, 0x02, 0x02, 0x00, 0x01,
                0x02, 0x01, 0x01
            ]),
            Data([0x30, 0x06, 0x02, 0x01, 0x80, 0x02, 0x01, 0x01]),
            Data([
                0x30, 0x06, 0x02, 0x01, 0x01,
                0x02, 0x01, 0x01, 0x00
            ]),
            orderScalar
        ]
        for signature in malformedSignatures {
            let candidate = replacing(
                envelope,
                signatureDER: signature.base64EncodedString()
            )
            #expect(throws: FingerprintEvidenceError.malformedEnvelope) {
                try FingerprintEvidenceEnvelopeCodec.verify(
                    encoded(candidate),
                    candidateManifest: fixture.manifest
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
        let signer = try! SoftwareP256FingerprintEvidenceSigner(
            rawRepresentation:
                Data(repeating: 0, count: 31) + Data([1])
        )
        let challenge = Data((0..<32).map(UInt8.init))
        let binding = FingerprintEvidenceManifestBinding(
            publicKeyX963: signer.publicKeyX963,
            sessionID: UUID(
                uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
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
        for binding: FingerprintEvidenceManifestBinding,
        schemaVersion: Int = 3
    ) -> Data {
        let bindingData = try! JSONEncoder().encode(binding)
        let bindingObject = try! JSONSerialization.jsonObject(
            with: bindingData
        )
        return try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": schemaVersion,
                "releasePath": "Contents/MacOS/NeAntik",
                "fingerprintEvidence": bindingObject
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
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
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
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

    private func replacing(
        _ envelope: FingerprintEvidenceEnvelope,
        signatureDER: String
    ) -> FingerprintEvidenceEnvelope {
        FingerprintEvidenceEnvelope(
            schemaVersion: envelope.schemaVersion,
            kind: envelope.kind,
            payloadEncoding: envelope.payloadEncoding,
            payload: envelope.payload,
            authentication: FingerprintEvidenceAuthentication(
                algorithm: envelope.authentication.algorithm,
                keyID: envelope.authentication.keyID,
                candidateManifestSHA256:
                    envelope.authentication.candidateManifestSHA256,
                sessionID: envelope.authentication.sessionID,
                challengeSHA256:
                    envelope.authentication.challengeSHA256,
                signatureDER: signatureDER
            )
        )
    }

    private func encoded(
        _ envelope: FingerprintEvidenceEnvelope
    ) -> Data {
        try! FingerprintEvidenceEnvelopeCodec.encode(envelope)
    }

    private func schema8CrossLanguageFixture() throws
        -> Schema8CrossLanguageFixture
    {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = projectRoot.appendingPathComponent(
            "scripts/tests/fixtures/" +
                "fingerprint-evidence-schema8-swift.json"
        )
        return try JSONDecoder().decode(
            Schema8CrossLanguageFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
    }

    private var p256Order: [UInt8] {
        [
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
            0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51
        ]
    }

    private var p256HalfOrder: [UInt8] {
        [
            0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
            0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
            0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8
        ]
    }

    private func compareScalar(
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

    private func subtractScalar(
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
}

private struct Schema8CrossLanguageFixture: Decodable {
    let manifestBase64: String
    let envelopeBase64: String
    let payloadBase64: String
    let opensslSignatureBase64: String
    let opensslTransportSHA256: String
}

private struct HighSSignatureTestSigner: FingerprintEvidenceSigning {
    let base: SoftwareP256FingerprintEvidenceSigner

    var publicKeyX963: Data {
        base.publicKeyX963
    }

    func signatureDER(for transcript: Data) throws -> Data {
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: base.signatureDER(for: transcript)
        )
        var raw = [UInt8](signature.rawRepresentation)
        let order: [UInt8] = [
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
            0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51
        ]
        let halfOrder: [UInt8] = [
            0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
            0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
            0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8
        ]
        let currentS = Array(raw[32..<64])
        let highS = compare(currentS, halfOrder) == .orderedDescending
            ? currentS
            : subtract(order, currentS)
        raw.replaceSubrange(32..<64, with: highS)
        return try P256.Signing.ECDSASignature(
            rawRepresentation: Data(raw)
        ).derRepresentation
    }

    private func compare(
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

    private func subtract(
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
}
