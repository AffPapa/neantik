import CryptoKit
import Foundation
import Security
import Testing
@testable import NeAntik

struct FingerprintEvidenceReleaseContextTests {
    @Test
    func qualifiedReportProducesOnePrivacySafeOneShotEnvelope() throws {
        let fixture = makeContext()
        let report = qualifiedReport()

        let outputURL = try fixture.context.persist(report: report)
        let envelope = try #require(fixture.output.payload)
        let payload = try FingerprintEvidenceEnvelopeCodec.verify(
            envelope,
            candidateManifest: fixture.manifest
        )
        let payloadText = try #require(
            String(data: payload, encoding: .utf8)
        )

        #expect(outputURL == fixture.outputURL)
        #expect(fixture.claimStore.claimCount == 1)
        #expect(
            fixture.abandonedSessions.values ==
                [fixture.binding.sessionID]
        )
        #expect(fixture.output.commitCount == 1)
        #expect(payloadText.contains(
            "\"kind\":\"neantik-fingerprint-release-result\""
        ))
        for privateValue in [
            "PRIVATE-PROFILE-A",
            "PRIVATE-PROFILE-B",
            "NA-DEADBEEF",
            "NA-CAFEBABE",
            report.firstInitial.profileID.uuidString,
            report.second.profileID.uuidString,
            "raw-canvas-a",
            "raw-webgl-b"
        ] {
            #expect(!payloadText.contains(privateValue))
            #expect(
                !String(data: envelope, encoding: .utf8)!
                    .contains(privateValue)
            )
        }

        #expect(throws: FingerprintEvidenceReleaseError.self) {
            try fixture.context.persist(report: report)
        }
        #expect(fixture.claimStore.claimCount == 1)
        #expect(fixture.output.commitCount == 1)
    }

    @Test
    func unqualifiedOrCandidateMismatchedReportNeverClaimsOrWrites()
        throws
    {
        let unqualified = makeContext()
        var report = qualifiedReport()
        let brokenSecond = FingerprintCapture(
            profileID: report.second.profileID,
            profileName: report.second.profileName,
            identityCode: report.second.identityCode,
            capturedAt: report.second.capturedAt,
            values: report.firstInitial.values
        )
        report = replacing(report, second: brokenSecond)

        #expect(
            throws: FingerprintEvidenceReleaseError.reportNotQualified
        ) {
            try unqualified.context.persist(report: report)
        }
        #expect(unqualified.claimStore.claimCount == 0)
        #expect(unqualified.output.commitCount == 0)
        #expect(unqualified.abandonedSessions.values.isEmpty)

        let mismatched = makeContext()
        let wrongBuild = replacing(
            qualifiedReport(),
            managerBuild: "999"
        )
        #expect(
            throws:
                FingerprintEvidenceReleaseError
                    .candidateMetadataMismatch
        ) {
            try mismatched.context.persist(report: wrongBuild)
        }
        #expect(mismatched.claimStore.claimCount == 0)
        #expect(mismatched.output.commitCount == 0)
        #expect(mismatched.abandonedSessions.values.isEmpty)
    }

    @Test
    func duplicateChallengeBurnsCandidateBeforeSignerOrOutput() throws {
        let fixture = makeContext(claimError: .challengeAlreadyConsumed)

        #expect(
            throws:
                FingerprintEvidenceReleaseError
                    .challengeAlreadyConsumed
        ) {
            try fixture.context.persist(report: qualifiedReport())
        }
        #expect(fixture.claimStore.claimCount == 1)
        #expect(fixture.output.commitCount == 0)
        #expect(fixture.abandonedSessions.values.isEmpty)
    }

    @Test
    func challengeCannotBeReplayedAcrossReleaseContexts() throws {
        let claimStore = RecordingChallengeClaimStore(error: nil)
        let first = makeContext(claimStore: claimStore)
        let replay = makeContext(claimStore: claimStore)

        try first.context.persist(report: qualifiedReport())
        #expect(
            throws:
                FingerprintEvidenceReleaseError
                    .challengeAlreadyConsumed
        ) {
            try replay.context.persist(report: qualifiedReport())
        }

        #expect(claimStore.claimCount == 2)
        #expect(first.output.commitCount == 1)
        #expect(replay.output.commitCount == 0)
        #expect(replay.abandonedSessions.values.isEmpty)
    }

    @Test
    func keychainClaimIsThisDeviceOnlyAndMapsDuplicateStrictly()
        throws
    {
        var captured: [String: Any] = [:]
        let digest = Data(repeating: 7, count: 32)
        let store = KeychainFingerprintEvidenceChallengeClaimStore {
            captured = $0
            return errSecSuccess
        }

        try store.claim(identifier: "claim-id", requestDigest: digest)
        #expect(
            captured[kSecClass as String] as? String ==
                kSecClassGenericPassword as String
        )
        #expect(
            captured[kSecAttrService as String] as? String ==
                "app.neantik.fingerprint-evidence.consumed-challenge.v1"
        )
        #expect(
            captured[kSecAttrAccount as String] as? String ==
                "claim-id"
        )
        #expect(
            captured[kSecAttrAccessible as String] as? String ==
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        #expect(
            captured[kSecUseDataProtectionKeychain as String] as? Bool ==
                true
        )
        #expect(
            captured[kSecValueData as String] as? Data == digest
        )

        let duplicate =
            KeychainFingerprintEvidenceChallengeClaimStore {
                _ in errSecDuplicateItem
            }
        #expect(
            throws:
                FingerprintEvidenceReleaseError
                    .challengeAlreadyConsumed
        ) {
            try duplicate.claim(
                identifier: "claim-id",
                requestDigest: digest
            )
        }

        let denied =
            KeychainFingerprintEvidenceChallengeClaimStore {
                _ in errSecAuthFailed
            }
        #expect(
            throws:
                FingerprintEvidenceReleaseError
                    .operationFailed(Int(errSecAuthFailed))
        ) {
            try denied.claim(
                identifier: "claim-id",
                requestDigest: digest
            )
        }
    }

    private func makeContext(
        claimError: FingerprintEvidenceReleaseError? = nil,
        claimStore providedClaimStore:
            RecordingChallengeClaimStore? = nil
    ) -> (
        context: FingerprintEvidenceReleaseContext,
        binding: FingerprintEvidenceManifestBinding,
        manifest: Data,
        outputURL: URL,
        claimStore: RecordingChallengeClaimStore,
        output: RecordingEnrollmentOutput,
        abandonedSessions: LockedSessions
    ) {
        let signer = try! SoftwareP256FingerprintEvidenceSigner(
            rawRepresentation:
                Data(repeating: 0, count: 31) + Data([1])
        )
        let binding = FingerprintEvidenceManifestBinding(
            publicKeyX963: signer.publicKeyX963,
            sessionID: UUID(
                uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            )!,
            challenge: Data((0..<32).map(UInt8.init))
        )
        let manifest = candidateManifest(binding: binding)
        let outputURL = URL(
            fileURLWithPath:
                "/private/tmp/neantik-release/evidence-schema8.json"
        )
        let claimStore = providedClaimStore
            ?? RecordingChallengeClaimStore(error: claimError)
        let output = RecordingEnrollmentOutput()
        let sessions = LockedSessions()
        let context = FingerprintEvidenceReleaseContext(
            request: FingerprintEvidenceReleaseRequest(
                candidateManifestURL: URL(
                    fileURLWithPath:
                        "/private/tmp/neantik-release/manifest.json"
                ),
                evidenceOutputURL: outputURL
            ),
            candidateManifest: manifest,
            metadata: FingerprintEvidenceCandidateMetadata(
                releaseChannel: .publicAlpha,
                managerVersion: "0.3.13",
                managerBuild: "16",
                runtimeExecutableSHA256:
                    String(repeating: "a", count: 64),
                runtimeFrameworkSHA256:
                    String(repeating: "b", count: 64)
            ),
            binding: binding,
            signer: signer,
            abandonAuthority: { sessions.append($0) },
            claimStore: claimStore,
            output: output
        )
        return (
            context,
            binding,
            manifest,
            outputURL,
            claimStore,
            output,
            sessions
        )
    }

    private func candidateManifest(
        binding: FingerprintEvidenceManifestBinding
    ) -> Data {
        let bindingData = try! JSONEncoder().encode(binding)
        let bindingObject = try! JSONSerialization.jsonObject(
            with: bindingData
        )
        return try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 3,
                "kind": "neantik-direct-prepared-candidate",
                "releaseChannel": "public-alpha",
                "preparedAt": "2026-07-30T00:00:00Z",
                "bundle": [
                    "name": "NeAntik.app",
                    "identifier": "app.neantik.desktop",
                    "version": "0.3.13",
                    "build": "16"
                ],
                "criticalFiles": [
                    "managerInfoPlist": [
                        "bundlePath": "Contents/Info.plist",
                        "sha256": String(repeating: "d", count: 64)
                    ],
                    "managerExecutable": [
                        "bundlePath": "Contents/MacOS/NeAntik",
                        "sha256": String(repeating: "c", count: 64)
                    ],
                    "runtimeInfoPlist": [
                        "bundlePath":
                            "Contents/Resources/NeAntik Browser.app/Contents/Info.plist",
                        "sha256": String(repeating: "e", count: 64)
                    ],
                    "runtimeExecutable": [
                        "bundlePath":
                            "Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser",
                        "sha256": String(repeating: "a", count: 64)
                    ],
                    "runtimeFramework": [
                        "bundlePath":
                            "Contents/Resources/NeAntik Browser.app/Contents/Frameworks/NeVision Browser Framework.framework/Versions/150.0.7871.186/NeVision Browser Framework",
                        "sha256": String(repeating: "b", count: 64)
                    ],
                    "runtimeVerification": [
                        "bundlePath":
                            "Contents/Resources/NeAntikRuntimeEvidence/runtime-verification.json",
                        "sha256": String(repeating: "f", count: 64)
                    ],
                    "runtimeCandidateLock": [
                        "bundlePath":
                            "Contents/Resources/NeAntikRuntimeEvidence/fingerprint-chromium.lock.json",
                        "sha256": String(repeating: "1", count: 64)
                    ],
                    "sourceContract": [
                        "bundlePath":
                            "Contents/Resources/NeAntikRuntimeEvidence/chromium-150-source-contract.json",
                        "sha256": String(repeating: "2", count: 64)
                    ],
                    "sourceProvenance": [
                        "bundlePath":
                            "Contents/Resources/NeAntikRuntimeEvidence/source-provenance.json",
                        "sha256": String(repeating: "3", count: 64)
                    ],
                    "buildArguments": [
                        "bundlePath":
                            "Contents/Resources/NeAntikRuntimeEvidence/args.gn",
                        "sha256": String(repeating: "4", count: 64)
                    ]
                ],
                "bundleInventory": [],
                "postPreparationMutablePaths": [
                    "Contents/CodeResources"
                ],
                "fingerprintEvidence": bindingObject,
                "boundary": "test candidate boundary"
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func qualifiedReport() -> FingerprintAuditReport {
        let firstID = UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!
        let first = FingerprintCapture(
            profileID: firstID,
            profileName: "PRIVATE-PROFILE-A",
            identityCode: "NA-DEADBEEF",
            capturedAt: Date(timeIntervalSince1970: 1),
            values: publicAlphaValues(
                canvas: "raw-canvas-a",
                webGL: "raw-webgl-a"
            )
        )
        let second = FingerprintCapture(
            profileID: UUID(
                uuidString:
                    "22222222-2222-2222-2222-222222222222"
            )!,
            profileName: "PRIVATE-PROFILE-B",
            identityCode: "NA-CAFEBABE",
            capturedAt: Date(timeIntervalSince1970: 2),
            values: publicAlphaValues(
                canvas: "raw-canvas-b",
                webGL: "raw-webgl-b"
            )
        )
        return FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 3),
            managerVersion: "0.3.13",
            managerBuild: "16",
            runtimeName: "NeAntik Browser",
            runtimeVersion: "150.0.7871.186",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            runtimeExecutableSHA256:
                String(repeating: "a", count: 64),
            runtimeFrameworkSHA256:
                String(repeating: "b", count: 64),
            executionMode: .browser,
            firstInitial: first,
            second: second,
            firstRepeat: FingerprintCapture(
                profileID: firstID,
                profileName: first.profileName,
                identityCode: first.identityCode,
                capturedAt: Date(timeIntervalSince1970: 3),
                values: first.values
            )
        )
    }

    private func publicAlphaValues(
        canvas: String,
        webGL: String
    ) -> [String: String] {
        [
            "canvas": canvas,
            "webgl_pixels": webGL,
            "audio": "audio",
            "client_rects": "rects",
            "webgl_vendor": "Google Inc. (Apple)",
            "webgl_renderer": "Apple M2",
            "webgl_extensions": "extensions",
            "webgpu_policy": "disabled",
            "user_agent": "Mozilla/5.0",
            "platform": "MacIntel",
            "client_hints": "{\"platform\":\"macOS\"}",
            "screen": "1512x982x1512x944x24x2",
            "hardware_concurrency": "8",
            "device_memory": "8",
            "touch_points": "0",
            "fonts": "Arial,Menlo",
            "languages": "en-US,en",
            "timezone": "Europe/Berlin"
        ]
    }

    private func replacing(
        _ report: FingerprintAuditReport,
        second: FingerprintCapture? = nil,
        managerBuild: String? = nil
    ) -> FingerprintAuditReport {
        FingerprintAuditReport(
            id: report.id,
            createdAt: report.createdAt,
            managerVersion: report.managerVersion,
            managerBuild: managerBuild ?? report.managerBuild,
            runtimeName: report.runtimeName,
            runtimeVersion: report.runtimeVersion,
            runtimeFlavor: report.runtimeFlavor,
            runtimeCodeSignatureValid:
                report.runtimeCodeSignatureValid,
            runtimeExecutableSHA256:
                report.runtimeExecutableSHA256,
            runtimeFrameworkSHA256:
                report.runtimeFrameworkSHA256,
            executionMode: report.effectiveExecutionMode,
            webrtcDirectControl: report.webrtcDirectControl,
            firstInitial: report.firstInitial,
            second: second ?? report.second,
            firstRepeat: report.firstRepeat
        )
    }
}

private final class RecordingChallengeClaimStore:
    FingerprintEvidenceChallengeClaiming, @unchecked Sendable
{
    private let lock = NSLock()
    private(set) var claimCount = 0
    private var identifiers: Set<String> = []
    let error: FingerprintEvidenceReleaseError?

    init(error: FingerprintEvidenceReleaseError?) {
        self.error = error
    }

    func claim(identifier: String, requestDigest: Data) throws {
        lock.lock()
        claimCount += 1
        let inserted = identifiers.insert(identifier).inserted
        lock.unlock()
        if let error {
            throw error
        }
        if !inserted {
            throw FingerprintEvidenceReleaseError
                .challengeAlreadyConsumed
        }
    }
}

private final class RecordingEnrollmentOutput:
    FingerprintEvidenceEnrollmentOutput
{
    private(set) var isCommitted = false
    private(set) var commitCount = 0
    private(set) var payload: Data?

    func commit(_ data: Data) throws {
        commitCount += 1
        payload = data
        isCommitted = true
    }

    func rollback() {}
}

private final class LockedSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID] = []

    var values: [UUID] {
        lock.withLock { storage }
    }

    func append(_ value: UUID) {
        lock.withLock {
            storage.append(value)
        }
    }
}
