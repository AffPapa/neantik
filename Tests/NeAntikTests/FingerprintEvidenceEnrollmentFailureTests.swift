import CryptoKit
import Foundation
import Testing
@testable import NeAntik

struct FingerprintEvidenceEnrollmentFailureTests {
    @Test(arguments: EnrollmentCreationMode.allCases.filter { $0 != .normal })
    func creationFailurePreservesOwnership(mode: EnrollmentCreationMode) throws {
        let backend = FaultEnrollmentBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(backend: backend)
        let sibling = UUID()
        let siblingKey = try authority.enroll(sessionID: sibling)
        backend.mode = mode
        let failed = UUID()
        let tag = SecureEnclaveFingerprintEvidenceAuthority.applicationTag(for: failed)
        do {
            _ = try authority.enroll(sessionID: failed)
            Issue.record("Fault-injected creation unexpectedly succeeded")
        } catch let failure as FingerprintEvidenceEnrollmentFailure {
            let clean = mode == .notCreated || mode == .createdAndRemoved
            #expect(failure.cleanup == (clean ? .released : .retained))
            #expect(failure.stage == (mode == .invalidPoint ? .keyValidation : .keyCreation))
            #expect(backend.reservations.contains(tag) == !clean)
            #expect(backend.releases == (clean ? 1 : 0))
            #expect(backend.deletes == 0)
            if mode == .cleanupFailed {
                #expect(failure.primaryCode == "invalid-public-key")
                #expect(failure.cleanupCode == "security--25308")
            }
            if mode == .unknown {
                #expect(failure.primaryCode == "unclassified")
                #expect(!failure.localizedDescription.contains("PRIVATE-SENTINEL"))
            }
        }
        backend.mode = .normal
        _ = try authority.existingSigner(sessionID: sibling, expectedPublicKeyX963: siblingKey)
    }

    @Test func preflightCleanupFailureRetainsFenceAndBothCauses() {
        let backend = FaultEnrollmentBackend()
        backend.lookupFails = true
        backend.releaseFails = true
        let session = UUID()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(backend: backend)
        #expect(throws: FingerprintEvidenceEnrollmentFailure(
            stage: .existingKeyCheck, primaryCode: "security--25308",
            cleanup: .retained, cleanupCode: "security--25293"
        )) { try authority.enroll(sessionID: session) }
        #expect(backend.reservations.count == 1)
        #expect(backend.creates == 0)
        #expect(backend.deletes == 0)
    }

    @Test func reservationLoserNeverCleansWinner() throws {
        let backend = FaultEnrollmentBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(backend: backend)
        let session = UUID()
        let key = try authority.enroll(sessionID: session)
        #expect(throws: SecureEnclaveFingerprintEvidenceAuthorityError.alreadyEnrolled) {
            try authority.enroll(sessionID: session)
        }
        _ = try authority.existingSigner(sessionID: session, expectedPublicKeyX963: key)
        #expect(backend.releases == 0)
        #expect(backend.deletes == 0)
    }

    @Test(arguments: ["signature", "output", "delete", "release", "committed"])
    func runnerRollbackIsExplicitAndRespectsCommit(control: String) throws {
        let backend = FaultEnrollmentBackend()
        backend.signatureFails = control == "signature"
        backend.deleteFails = control == "delete"
        backend.releaseFails = control == "release"
        let output = FaultEnrollmentOutput(commitBeforeThrow: control == "committed")
        let session = UUID()
        let runner = FingerprintEvidenceEnrollmentRunner(
            authority: SecureEnclaveFingerprintEvidenceAuthority(backend: backend),
            sessionIDProvider: { session },
            challengeProvider: { Data(repeating: 7, count: 32) },
            outputFactory: { _ in output }
        )
        do {
            _ = try runner.run(outputURL: URL(fileURLWithPath: "/private/tmp/not-opened.json"))
            Issue.record("Fault-injected runner unexpectedly succeeded")
        } catch {
            if control == "committed" {
                #expect(error is FaultEnrollmentError)
                #expect(backend.deletes == 0 && backend.releases == 0)
                #expect(backend.keys.count == 1 && backend.reservations.count == 1)
                #expect(output.rollbacks == 0)
            } else {
                let failure = try #require(error as? FingerprintEvidenceEnrollmentFailure)
                #expect(failure.stage == (control == "signature" ? .selfTest : .outputCommit))
                #expect(failure.cleanup == (["delete", "release"].contains(control) ? .retained : .released))
                #expect(output.rollbacks == 1)
                #expect(backend.keys.count == (control == "delete" ? 1 : 0))
                #expect(backend.reservations.count == (["delete", "release"].contains(control) ? 1 : 0))
                #expect(backend.releases == (control == "delete" ? 0 : 1))
                #expect(!failure.localizedDescription.contains("PRIVATE-SENTINEL"))
            }
        }
    }
}

enum EnrollmentCreationMode: CaseIterable, Sendable {
    case normal, notCreated, createdAndRemoved, cleanupFailed, unknown, invalidPoint
}

private struct FaultEnrollmentError: LocalizedError {
    var errorDescription: String? { "PRIVATE-SENTINEL backend diagnostic" }
}

/// Only a synchronous injected backend; no Security API or filesystem access.
private final class FaultEnrollmentBackend: SecureEnclaveFingerprintEvidenceKeyBackend, @unchecked Sendable {
    var mode = EnrollmentCreationMode.normal
    var lookupFails = false, signatureFails = false, deleteFails = false, releaseFails = false
    var reservations: Set<Data> = []
    var keys: [Data: P256.Signing.PrivateKey] = [:]
    var creates = 0, deletes = 0, releases = 0

    func reserveEnrollment(applicationTag: Data) throws {
        guard reservations.insert(applicationTag).inserted else {
            throw SecureEnclaveFingerprintEvidenceAuthorityError.alreadyEnrolled
        }
    }
    func publicKeyX963(applicationTag: Data) throws -> Data? {
        if lookupFails { throw SecureEnclaveFingerprintEvidenceAuthorityError.operationFailed(-25308) }
        return keys[applicationTag]?.publicKey.x963Representation
    }
    func createPrivateKey(applicationTag: Data) throws -> Data {
        creates += 1
        if mode == .notCreated {
            throw SecureEnclaveFingerprintKeyCreationFailure(primaryCode: "security--25293", outcome: .notCreated, cleanupCode: nil)
        }
        let key = P256.Signing.PrivateKey()
        keys[applicationTag] = key
        switch mode {
        case .createdAndRemoved:
            keys.removeValue(forKey: applicationTag)
            throw SecureEnclaveFingerprintKeyCreationFailure(primaryCode: "invalid-public-key", outcome: .createdAndRemoved, cleanupCode: nil)
        case .cleanupFailed:
            throw SecureEnclaveFingerprintKeyCreationFailure(primaryCode: "invalid-public-key", outcome: .unconfirmed, cleanupCode: "security--25308")
        case .unknown: throw FaultEnrollmentError()
        case .invalidPoint: return Data([4] + Array(repeating: UInt8(0), count: 64))
        default: return key.publicKey.x963Representation
        }
    }
    func signature(for message: Data, applicationTag: Data) throws -> SecureEnclaveFingerprintEvidenceSignature {
        if signatureFails { throw FaultEnrollmentError() }
        guard let key = keys[applicationTag] else { throw SecureEnclaveFingerprintEvidenceAuthorityError.notEnrolled }
        return .init(publicKeyX963: key.publicKey.x963Representation, signatureDER: try key.signature(for: message).derRepresentation)
    }
    func deletePrivateKey(applicationTag: Data) throws {
        deletes += 1
        if deleteFails { throw SecureEnclaveFingerprintEvidenceAuthorityError.operationFailed(-25308) }
        keys.removeValue(forKey: applicationTag)
    }
    func releaseEnrollment(applicationTag: Data) throws {
        releases += 1
        if releaseFails { throw SecureEnclaveFingerprintEvidenceAuthorityError.operationFailed(-25293) }
        reservations.remove(applicationTag)
    }
    func hasEnrollment(applicationTag: Data) throws -> Bool { reservations.contains(applicationTag) }
}

private final class FaultEnrollmentOutput: FingerprintEvidenceEnrollmentOutput {
    let commitBeforeThrow: Bool
    var isCommitted = false
    var rollbacks = 0
    init(commitBeforeThrow: Bool) { self.commitBeforeThrow = commitBeforeThrow }
    func commit(_ data: Data) throws {
        isCommitted = commitBeforeThrow
        throw FaultEnrollmentError()
    }
    func rollback() { rollbacks += 1 }
}
