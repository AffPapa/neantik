import CryptoKit
import Darwin
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
    func thirtyTwoConcurrentContextsConsumeChallengeExactlyOnce() {
        let claimStore = RecordingChallengeClaimStore(error: nil)
        let fixtures = (0..<32).map { _ in
            makeContext(claimStore: claimStore)
        }
        let results = LockedReleaseResults()

        DispatchQueue.concurrentPerform(
            iterations: fixtures.count
        ) { index in
            do {
                _ = try fixtures[index].context.persist(
                    report: qualifiedReport()
                )
                results.recordSuccess()
            } catch let error as FingerprintEvidenceReleaseError {
                results.record(error)
            } catch {
                results.recordUnexpected()
            }
        }

        #expect(claimStore.claimCount == 32)
        #expect(claimStore.claimWins == 1)
        #expect(results.successes == 1)
        #expect(results.replays == 31)
        #expect(results.unexpected == 0)
        #expect(
            fixtures.reduce(0) {
                $0 + $1.output.commitCount
            } == 1
        )
        #expect(
            fixtures.reduce(0) {
                $0 + $1.abandonedSessions.values.count
            } == 1
        )
    }

    @Test
    func outputFailureRecoversExactEnvelopeWithoutSigningAgain() throws {
        let template = makeContext()
        let claimStore = RecordingChallengeClaimStore(error: nil)
        let recoveryStore = RecordingRecoveryStore()
        let signatureCount = LockedCounter()
        let softwareSigner =
            try SoftwareP256FingerprintEvidenceSigner(
                rawRepresentation:
                    Data(repeating: 0, count: 31) + Data([1])
            )
        let signer = CountingFingerprintEvidenceSigner(
            base: softwareSigner,
            count: signatureCount
        )
        let failedOutput = ThrowingEnrollmentOutput()
        let firstAbandon = LockedSessions()
        let first = FingerprintEvidenceReleaseContext(
            request: template.context.request,
            candidateManifest: template.manifest,
            metadata: template.context.metadata,
            binding: template.binding,
            signer: signer,
            abandonAuthority: { firstAbandon.append($0) },
            claimStore: claimStore,
            recoveryStore: recoveryStore,
            output: failedOutput
        )

        #expect(throws: FingerprintEvidenceEnrollmentError.self) {
            try first.persist(report: qualifiedReport())
        }
        let receipt = try #require(recoveryStore.onlyEnvelope)
        #expect(signatureCount.value == 1)
        #expect(firstAbandon.values.count == 1)
        #expect(failedOutput.commitCount == 1)

        let recoveredOutput = PreexistingEnrollmentOutput(
            existing: receipt
        )
        let recoveredAbandon = LockedSessions()
        let recovered = FingerprintEvidenceReleaseContext(
            request: template.context.request,
            candidateManifest: template.manifest,
            metadata: template.context.metadata,
            binding: template.binding,
            signer: signer,
            abandonAuthority: { recoveredAbandon.append($0) },
            claimStore: claimStore,
            recoveryStore: recoveryStore,
            output: recoveredOutput
        )
        #expect(
            try recovered.recoverPersistedEnvelope() ==
                template.context.request.evidenceOutputURL
        )

        #expect(signatureCount.value == 1)
        #expect(recoveredOutput.payload == receipt)
        #expect(recoveredOutput.commitCount == 1)
        #expect(recoveredAbandon.values.count == 1)
        #expect(claimStore.claimCount == 1)
        #expect(claimStore.claimWins == 1)
    }

    @Test
    func preexistingOutputWithoutReceiptDoesNotConsumeChallenge()
        throws
    {
        let template = makeContext()
        let claimStore = RecordingChallengeClaimStore(error: nil)
        let signatureCount = LockedCounter()
        let signer = CountingFingerprintEvidenceSigner(
            base: try SoftwareP256FingerprintEvidenceSigner(
                rawRepresentation:
                    Data(repeating: 0, count: 31) + Data([1])
            ),
            count: signatureCount
        )
        let context = FingerprintEvidenceReleaseContext(
            request: template.context.request,
            candidateManifest: template.manifest,
            metadata: template.context.metadata,
            binding: template.binding,
            signer: signer,
            abandonAuthority: { _ in },
            claimStore: claimStore,
            recoveryStore: RecordingRecoveryStore(),
            output: PreexistingEnrollmentOutput(
                existing: Data("sentinel".utf8)
            )
        )

        #expect(
            throws: FingerprintEvidenceReleaseError.outputUnavailable
        ) {
            try context.persist(report: qualifiedReport())
        }
        #expect(claimStore.claimCount == 0)
        #expect(signatureCount.value == 0)
    }

    @Test
    func recoveryStoreFailureBurnsAuthorityAndNeverWritesOutput()
        throws
    {
        let template = makeContext()
        let claimStore = RecordingChallengeClaimStore(error: nil)
        let signatureCount = LockedCounter()
        let abandoned = LockedSessions()
        let output = RecordingEnrollmentOutput()
        let context = FingerprintEvidenceReleaseContext(
            request: template.context.request,
            candidateManifest: template.manifest,
            metadata: template.context.metadata,
            binding: template.binding,
            signer: CountingFingerprintEvidenceSigner(
                base: try SoftwareP256FingerprintEvidenceSigner(
                    rawRepresentation:
                        Data(repeating: 0, count: 31) + Data([1])
                ),
                count: signatureCount
            ),
            abandonAuthority: { abandoned.append($0) },
            claimStore: claimStore,
            recoveryStore: ThrowingRecoveryStore(),
            output: output
        )

        #expect(throws: FingerprintEvidenceReleaseError.self) {
            try context.persist(report: qualifiedReport())
        }
        #expect(claimStore.claimCount == 1)
        #expect(signatureCount.value == 1)
        #expect(abandoned.values.count == 1)
        #expect(output.commitCount == 0)
    }

    @Test
    func recoveryRejectsClaimDigestMismatchWithoutSigningOrWriting()
        throws
    {
        let template = makeContext()
        let claimStore = RecordingChallengeClaimStore(error: nil)
        let recoveryStore = RecordingRecoveryStore()
        let signatureCount = LockedCounter()
        let signer = CountingFingerprintEvidenceSigner(
            base: try SoftwareP256FingerprintEvidenceSigner(
                rawRepresentation:
                    Data(repeating: 0, count: 31) + Data([1])
            ),
            count: signatureCount
        )
        let first = FingerprintEvidenceReleaseContext(
            request: template.context.request,
            candidateManifest: template.manifest,
            metadata: template.context.metadata,
            binding: template.binding,
            signer: signer,
            abandonAuthority: { _ in },
            claimStore: claimStore,
            recoveryStore: recoveryStore,
            output: ThrowingEnrollmentOutput()
        )
        #expect(throws: FingerprintEvidenceEnrollmentError.self) {
            try first.persist(report: qualifiedReport())
        }
        #expect(signatureCount.value == 1)
        claimStore.replaceOnlyClaimDigest(
            Data(repeating: 0xA5, count: 32)
        )

        let recoveredOutput = RecordingEnrollmentOutput()
        let recovered = FingerprintEvidenceReleaseContext(
            request: template.context.request,
            candidateManifest: template.manifest,
            metadata: template.context.metadata,
            binding: template.binding,
            signer: signer,
            abandonAuthority: { _ in },
            claimStore: claimStore,
            recoveryStore: recoveryStore,
            output: recoveredOutput
        )
        #expect(throws: FingerprintEvidenceError.bindingMismatch) {
            try recovered.recoverPersistedEnvelope()
        }
        #expect(signatureCount.value == 1)
        #expect(recoveredOutput.commitCount == 0)
    }

    @Test
    func fileRecoveryReceiptIsPrivateAndByteIdentical() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileFingerprintEvidenceRecoveryStore(
            rootDirectory: root.appendingPathComponent(
                "v1",
                isDirectory: true
            )
        )
        let identifier = String(repeating: "a", count: 64)
        let envelope = Data("{\"schemaVersion\":8}".utf8)

        try store.storeEnvelope(envelope, identifier: identifier)
        #expect(
            try store.loadEnvelope(identifier: identifier) ==
                envelope
        )
        let receipt = root
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("envelope.schema8.json")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: receipt.path
        )
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        try store.storeEnvelope(envelope, identifier: identifier)
        #expect(
            throws: FingerprintEvidenceEnrollmentError.self
        ) {
            try store.storeEnvelope(
                Data("{\"schemaVersion\":9}".utf8),
                identifier: identifier
            )
        }

        let target = root.appendingPathComponent(
            "target-v1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let linked = root.appendingPathComponent(
            "linked-v1",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: target
        )
        let redirected = FileFingerprintEvidenceRecoveryStore(
            rootDirectory: linked
        )
        #expect(throws: FingerprintEvidenceReleaseError.self) {
            try redirected.storeEnvelope(
                envelope,
                identifier: identifier
            )
        }
    }

    @Test
    func stableReaderRejectsSymlinkHardlinkAndOversizedManifest()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: manifest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifest.path
        )
        let symlink = root.appendingPathComponent("manifest-link.json")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: manifest
        )
        #expect(throws: FingerprintEvidenceReleaseError.self) {
            try FingerprintEvidenceReleaseContext
                .readStableRegularFile(
                    symlink,
                    maximumBytes: 1024
                )
        }

        let hardlink = root.appendingPathComponent("manifest-hard.json")
        #expect(Darwin.link(manifest.path, hardlink.path) == 0)
        #expect(throws: FingerprintEvidenceReleaseError.self) {
            try FingerprintEvidenceReleaseContext
                .readStableRegularFile(
                    hardlink,
                    maximumBytes: 1024
                )
        }
        try FileManager.default.removeItem(at: hardlink)
        try FileManager.default.removeItem(at: manifest)

        let oversized = root.appendingPathComponent("oversized.json")
        let descriptor = Darwin.open(
            oversized.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        #expect(descriptor >= 0)
        #expect(Darwin.ftruncate(descriptor, 1025) == 0)
        _ = Darwin.close(descriptor)
        #expect(throws: FingerprintEvidenceReleaseError.self) {
            try FingerprintEvidenceReleaseContext
                .readStableRegularFile(
                    oversized,
                    maximumBytes: 1024
                )
        }
    }

    @Test
    func atomicReleaseOutputNeverOverwritesExistingOrSymlinkTarget()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("evidence.json")
        try Data("sentinel".utf8).write(to: existing)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: existing.path
        )
        #expect(throws: FingerprintEvidenceEnrollmentError.self) {
            try AtomicFingerprintEvidenceReleaseOutput(url: existing)
        }
        #expect(try Data(contentsOf: existing) == Data("sentinel".utf8))

        try FileManager.default.removeItem(at: existing)
        let target = root.appendingPathComponent("target.json")
        try Data("private-target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: existing,
            withDestinationURL: target
        )
        #expect(throws: FingerprintEvidenceEnrollmentError.self) {
            try AtomicFingerprintEvidenceReleaseOutput(url: existing)
        }
        #expect(
            try Data(contentsOf: target) ==
                Data("private-target".utf8)
        )

        try FileManager.default.removeItem(at: existing)
        let exact = Data("exact-envelope".utf8)
        try exact.write(to: existing)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: existing.path
        )
        let idempotent = try AtomicFingerprintEvidenceReleaseOutput(
            url: existing,
            allowIdenticalExisting: true
        )
        #expect(idempotent.hasExistingEntry)
        try idempotent.commit(exact)
        #expect(idempotent.isCommitted)
        #expect(try Data(contentsOf: existing) == exact)
    }

    @Test
    func keychainClaimIsThisDeviceOnlyWithoutDataProtectionEntitlementAndMapsDuplicateStrictly()
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
            captured[kSecUseDataProtectionKeychain as String] == nil
        )
        #expect(
            captured[kSecValueData as String] as? Data == digest
        )

        var readQuery: [String: Any] = [:]
        let readable =
            KeychainFingerprintEvidenceChallengeClaimStore(
                addItem: { _ in errSecSuccess },
                copyItem: {
                    readQuery = $0
                    return (errSecSuccess, digest)
                }
            )
        #expect(
            try readable.claimedDigest(identifier: "claim-id") ==
                digest
        )
        #expect(
            readQuery[kSecClass as String] as? String ==
                kSecClassGenericPassword as String
        )
        #expect(
            readQuery[kSecAttrService as String] as? String ==
                "app.neantik.fingerprint-evidence.consumed-challenge.v1"
        )
        #expect(
            readQuery[kSecAttrAccount as String] as? String ==
                "claim-id"
        )
        #expect(
            readQuery[kSecUseDataProtectionKeychain as String] == nil
        )
        #expect(
            readQuery[kSecReturnData as String] as? Bool == true
        )
        #expect(
            readQuery[kSecMatchLimit as String] as? String ==
                kSecMatchLimitOne as String
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
    private var claimAttempts = 0
    private var successfulClaims = 0
    private var claims: [String: Data] = [:]
    let error: FingerprintEvidenceReleaseError?

    var claimCount: Int {
        lock.withLock { claimAttempts }
    }

    var claimWins: Int {
        lock.withLock { successfulClaims }
    }

    init(error: FingerprintEvidenceReleaseError?) {
        self.error = error
    }

    func claim(identifier: String, requestDigest: Data) throws {
        let inserted = lock.withLock {
            claimAttempts += 1
            let inserted = claims[identifier] == nil
            if inserted {
                claims[identifier] = requestDigest
                successfulClaims += 1
            }
            return inserted
        }
        if let error {
            throw error
        }
        if !inserted {
            throw FingerprintEvidenceReleaseError
                .challengeAlreadyConsumed
        }
    }

    func claimedDigest(identifier: String) throws -> Data? {
        lock.withLock { claims[identifier] }
    }

    func replaceOnlyClaimDigest(_ digest: Data) {
        lock.withLock {
            guard let identifier = claims.keys.first else {
                return
            }
            claims[identifier] = digest
        }
    }
}

private final class LockedReleaseResults: @unchecked Sendable {
    private let lock = NSLock()
    private var successCount = 0
    private var replayCount = 0
    private var unexpectedCount = 0

    var successes: Int {
        lock.withLock { successCount }
    }

    var replays: Int {
        lock.withLock { replayCount }
    }

    var unexpected: Int {
        lock.withLock { unexpectedCount }
    }

    func recordSuccess() {
        lock.withLock {
            successCount += 1
        }
    }

    func record(_ error: FingerprintEvidenceReleaseError) {
        lock.withLock {
            if error == .challengeAlreadyConsumed {
                replayCount += 1
            } else {
                unexpectedCount += 1
            }
        }
    }

    func recordUnexpected() {
        lock.withLock {
            unexpectedCount += 1
        }
    }
}

private final class RecordingRecoveryStore:
    FingerprintEvidenceRecoveryStoring, @unchecked Sendable
{
    private let lock = NSLock()
    private var envelopes: [String: Data] = [:]

    var onlyEnvelope: Data? {
        lock.withLock { envelopes.values.first }
    }

    func loadEnvelope(identifier: String) throws -> Data? {
        lock.withLock { envelopes[identifier] }
    }

    func storeEnvelope(_ data: Data, identifier: String) throws {
        try lock.withLock {
            if let existing = envelopes[identifier] {
                guard existing == data else {
                    throw FingerprintEvidenceError.bindingMismatch
                }
                return
            }
            envelopes[identifier] = data
        }
    }
}

private struct ThrowingRecoveryStore:
    FingerprintEvidenceRecoveryStoring
{
    func loadEnvelope(identifier: String) throws -> Data? {
        nil
    }

    func storeEnvelope(_ data: Data, identifier: String) throws {
        throw FingerprintEvidenceReleaseError.operationFailed(Int(EIO))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}

private struct CountingFingerprintEvidenceSigner:
    FingerprintEvidenceSigning, Sendable
{
    let base: SoftwareP256FingerprintEvidenceSigner
    let count: LockedCounter

    var publicKeyX963: Data {
        base.publicKeyX963
    }

    func signatureDER(for transcript: Data) throws -> Data {
        count.increment()
        return try base.signatureDER(for: transcript)
    }
}

private final class ThrowingEnrollmentOutput:
    FingerprintEvidenceEnrollmentOutput
{
    private(set) var isCommitted = false
    private(set) var commitCount = 0

    func commit(_ data: Data) throws {
        commitCount += 1
        throw FingerprintEvidenceEnrollmentError
            .operationFailed(EIO)
    }

    func rollback() {}
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

private final class PreexistingEnrollmentOutput:
    FingerprintEvidenceEnrollmentOutput
{
    private let existing: Data
    private(set) var isCommitted = false
    private(set) var commitCount = 0
    private(set) var payload: Data?
    let hasExistingEntry = true

    init(existing: Data) {
        self.existing = existing
    }

    func commit(_ data: Data) throws {
        commitCount += 1
        guard data == existing else {
            throw FingerprintEvidenceEnrollmentError.unsafeOutputEntry
        }
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
