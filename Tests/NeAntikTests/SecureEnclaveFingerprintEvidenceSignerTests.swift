import CryptoKit
import Foundation
import Testing
@testable import NeAntik

struct SecureEnclaveFingerprintEvidenceSignerTests {
    @Test
    func secureEnclaveAuditDoesNotCreateMissingAuthority() throws {
        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        let sessionID = UUID()
        let expectedPublicKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation

        #expect(
            throws:
                SecureEnclaveFingerprintEvidenceAuthorityError.notEnrolled
        ) {
            try authority.existingSigner(
                sessionID: sessionID,
                expectedPublicKeyX963: expectedPublicKey
            )
        }
        #expect(backend.publicKeyCallCount == 1)
        #expect(backend.reserveCallCount == 0)
        #expect(backend.createCallCount == 0)
        #expect(backend.signatureCallCount == 0)
        #expect(backend.deleteCallCount == 0)
        #expect(backend.keyCount == 0)
    }

    @Test
    func secureEnclaveEnrollmentIsOneTimePerSession() throws {
        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        let sessionID = UUID()

        let enrolledPublicKey = try authority.enroll(sessionID: sessionID)

        #expect(enrolledPublicKey.count == 65)
        #expect(enrolledPublicKey.first == 0x04)
        #expect(
            throws:
                SecureEnclaveFingerprintEvidenceAuthorityError.alreadyEnrolled
        ) {
            try authority.enroll(sessionID: sessionID)
        }
        #expect(backend.createCallCount == 1)
        #expect(backend.reserveCallCount == 2)
        #expect(backend.reservationCount == 1)
        #expect(backend.keyCount == 1)
    }

    @Test
    func concurrentSecureEnclaveEnrollmentHasOneWinner() {
        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        let sessionID = UUID()
        let outcomes = EnrollmentOutcomeRecorder()

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                _ = try authority.enroll(sessionID: sessionID)
                outcomes.recordSuccess()
            } catch let error
                as SecureEnclaveFingerprintEvidenceAuthorityError
            {
                if error == .alreadyEnrolled {
                    outcomes.recordAlreadyEnrolled()
                } else {
                    outcomes.recordUnexpected()
                }
            } catch {
                outcomes.recordUnexpected()
            }
        }

        #expect(outcomes.successCount == 1)
        #expect(outcomes.alreadyEnrolledCount == 1)
        #expect(outcomes.unexpectedCount == 0)
        #expect(backend.reserveCallCount == 2)
        #expect(backend.createCallCount == 1)
        #expect(backend.reservationCount == 1)
        #expect(backend.keyCount == 1)
    }

    @Test
    func secureEnclaveSignerProducesVerifiableP256Signature() throws {
        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        let sessionID = UUID()
        let publicKeyData = try authority.enroll(sessionID: sessionID)
        let signer = try authority.existingSigner(
            sessionID: sessionID,
            expectedPublicKeyX963: publicKeyData
        )
        let transcript = Data(
            "authenticated fingerprint evidence transcript".utf8
        )

        let signatureData = try signer.signatureDER(for: transcript)
        let publicKey = try P256.Signing.PublicKey(
            x963Representation: publicKeyData
        )
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: signatureData
        )

        #expect(publicKey.isValidSignature(signature, for: transcript))
        #expect(signer.publicKeyX963 == publicKeyData)
        #expect(
            signer.applicationTag ==
                SecureEnclaveFingerprintEvidenceAuthority.applicationTag(
                    for: sessionID
                )
        )
        #expect(backend.signatureCallCount == 1)
    }

    @Test
    func secureEnclaveAuthorityRejectsManifestKeyMismatch() throws {
        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        let sessionID = UUID()
        _ = try authority.enroll(sessionID: sessionID)
        let unrelatedPublicKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation

        #expect(
            throws:
                SecureEnclaveFingerprintEvidenceAuthorityError
                    .authorityMismatch
        ) {
            try authority.existingSigner(
                sessionID: sessionID,
                expectedPublicKeyX963: unrelatedPublicKey
            )
        }
        #expect(backend.signatureCallCount == 0)
    }

    @Test
    func secureEnclaveAuthorityRejectsInvalidCurvePoint() {
        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        var invalidPoint = Data(repeating: 0, count: 65)
        invalidPoint[0] = 0x04

        #expect(
            throws:
                SecureEnclaveFingerprintEvidenceAuthorityError
                    .invalidPublicKey
        ) {
            try authority.existingSigner(
                sessionID: UUID(),
                expectedPublicKeyX963: invalidPoint
            )
        }
        #expect(backend.publicKeyCallCount == 0)
        #expect(backend.createCallCount == 0)
    }

    @Test
    func secureEnclaveSignerRejectsKeySwapDuringSigning() throws {
        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        let sessionID = UUID()
        let enrolledPublicKey = try authority.enroll(sessionID: sessionID)
        let signer = try authority.existingSigner(
            sessionID: sessionID,
            expectedPublicKeyX963: enrolledPublicKey
        )

        backend.replaceKey(
            applicationTag:
                SecureEnclaveFingerprintEvidenceAuthority.applicationTag(
                    for: sessionID
                )
        )

        #expect(
            throws:
                SecureEnclaveFingerprintEvidenceAuthorityError
                    .authorityMismatch
        ) {
            try signer.signatureDER(for: Data("transcript".utf8))
        }
        #expect(backend.signatureCallCount == 1)
    }

    @Test
    func secureEnclaveAbandonRemovesOnlyRequestedSession() throws {
        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        let abandonedSessionID = UUID()
        let retainedSessionID = UUID()
        let abandonedPublicKey = try authority.enroll(
            sessionID: abandonedSessionID
        )
        let retainedPublicKey = try authority.enroll(
            sessionID: retainedSessionID
        )

        try authority.abandon(sessionID: abandonedSessionID)
        try authority.abandon(sessionID: abandonedSessionID)

        #expect(
            throws:
                SecureEnclaveFingerprintEvidenceAuthorityError.notEnrolled
        ) {
            try authority.existingSigner(
                sessionID: abandonedSessionID,
                expectedPublicKeyX963: abandonedPublicKey
            )
        }
        _ = try authority.existingSigner(
            sessionID: retainedSessionID,
            expectedPublicKeyX963: retainedPublicKey
        )
        #expect(backend.deleteCallCount == 2)
        #expect(backend.releaseCallCount == 2)
        #expect(backend.reservationCount == 1)
        #expect(backend.keyCount == 1)
    }

    @Test
    func secureEnclaveSessionTagsAreCanonicalAndUnique() throws {
        let firstSession = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let secondSession = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEF")
        )
        let firstTag =
            SecureEnclaveFingerprintEvidenceAuthority.applicationTag(
                for: firstSession
            )
        let secondTag =
            SecureEnclaveFingerprintEvidenceAuthority.applicationTag(
                for: secondSession
            )

        #expect(firstTag != secondTag)
        #expect(
            String(data: firstTag, encoding: .utf8) ==
                SecureEnclaveFingerprintEvidenceAuthority
                    .applicationTagDomain
                + "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        #expect(
            String(data: secondTag, encoding: .utf8) ==
                SecureEnclaveFingerprintEvidenceAuthority
                    .applicationTagDomain
                + "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEF"
        )

        let backend = InMemoryFingerprintEvidenceKeyBackend()
        let authority = SecureEnclaveFingerprintEvidenceAuthority(
            backend: backend
        )
        let firstPublicKey = try authority.enroll(sessionID: firstSession)
        let secondPublicKey = try authority.enroll(sessionID: secondSession)
        #expect(firstPublicKey != secondPublicKey)
        #expect(backend.keyCount == 2)
    }
}

private final class InMemoryFingerprintEvidenceKeyBackend:
    SecureEnclaveFingerprintEvidenceKeyBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var keys: [Data: P256.Signing.PrivateKey] = [:]
    private var reservations: Set<Data> = []
    private var publicKeyCalls = 0
    private var reserveCalls = 0
    private var createCalls = 0
    private var signatureCalls = 0
    private var deleteCalls = 0
    private var releaseCalls = 0

    var publicKeyCallCount: Int {
        locked { publicKeyCalls }
    }

    var reserveCallCount: Int {
        locked { reserveCalls }
    }

    var createCallCount: Int {
        locked { createCalls }
    }

    var signatureCallCount: Int {
        locked { signatureCalls }
    }

    var deleteCallCount: Int {
        locked { deleteCalls }
    }

    var releaseCallCount: Int {
        locked { releaseCalls }
    }

    var reservationCount: Int {
        locked { reservations.count }
    }

    var keyCount: Int {
        locked { keys.count }
    }

    func reserveEnrollment(applicationTag: Data) throws {
        try locked {
            reserveCalls += 1
            guard reservations.insert(applicationTag).inserted else {
                throw SecureEnclaveFingerprintEvidenceAuthorityError
                    .alreadyEnrolled
            }
        }
    }

    func publicKeyX963(applicationTag: Data) throws -> Data? {
        locked {
            publicKeyCalls += 1
            return keys[applicationTag]?.publicKey.x963Representation
        }
    }

    func createPrivateKey(applicationTag: Data) throws -> Data {
        try locked {
            createCalls += 1
            guard keys[applicationTag] == nil else {
                throw InMemoryFingerprintEvidenceKeyBackendError
                    .duplicateKey
            }
            let key = P256.Signing.PrivateKey()
            keys[applicationTag] = key
            return key.publicKey.x963Representation
        }
    }

    func signature(
        for message: Data,
        applicationTag: Data
    ) throws -> SecureEnclaveFingerprintEvidenceSignature {
        try locked {
            signatureCalls += 1
            guard let key = keys[applicationTag] else {
                throw SecureEnclaveFingerprintEvidenceAuthorityError
                    .notEnrolled
            }
            return SecureEnclaveFingerprintEvidenceSignature(
                publicKeyX963: key.publicKey.x963Representation,
                signatureDER:
                    try key.signature(for: message).derRepresentation
            )
        }
    }

    func deletePrivateKey(applicationTag: Data) throws {
        locked {
            deleteCalls += 1
            keys.removeValue(forKey: applicationTag)
        }
    }

    func releaseEnrollment(applicationTag: Data) throws {
        locked {
            releaseCalls += 1
            reservations.remove(applicationTag)
        }
    }

    func replaceKey(applicationTag: Data) {
        locked {
            keys[applicationTag] = P256.Signing.PrivateKey()
        }
    }

    private func locked<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private enum InMemoryFingerprintEvidenceKeyBackendError: Error {
    case duplicateKey
}

private final class EnrollmentOutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    private var alreadyEnrolled = 0
    private var unexpected = 0

    var successCount: Int {
        locked { successes }
    }

    var alreadyEnrolledCount: Int {
        locked { alreadyEnrolled }
    }

    var unexpectedCount: Int {
        locked { unexpected }
    }

    func recordSuccess() {
        locked { successes += 1 }
    }

    func recordAlreadyEnrolled() {
        locked { alreadyEnrolled += 1 }
    }

    func recordUnexpected() {
        locked { unexpected += 1 }
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
