import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

struct FingerprintEvidenceEnrollmentTests {
    @Test
    func enrollmentWritesCanonicalPrivateBindingAndSelfTestsKey() throws {
        try withPrivateTemporaryDirectory { root in
            let output = root.appendingPathComponent("binding.json")
            let backend = EnrollmentTestKeyBackend()
            let sessionID = try #require(
                UUID(
                    uuidString:
                        "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
                )
            )
            let challenge = Data((0..<32).map(UInt8.init))
            let runner = FingerprintEvidenceEnrollmentRunner(
                authority: SecureEnclaveFingerprintEvidenceAuthority(
                    backend: backend
                ),
                sessionIDProvider: { sessionID },
                challengeProvider: { challenge }
            )

            let binding = try runner.run(outputURL: output)
            let raw = try Data(contentsOf: output)
            let object = try #require(
                JSONSerialization.jsonObject(with: raw)
                    as? [String: Any]
            )
            let canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            var status = stat()
            #expect(lstat(output.path, &status) == 0)

            #expect(raw == canonical)
            #expect(raw.last != 0x0a)
            #expect(
                Set(object.keys) == [
                    "schemaVersion",
                    "algorithm",
                    "authorityKeyID",
                    "publicKeyX963",
                    "sessionID",
                    "challenge"
                ]
            )
            #expect(object["sessionID"] as? String == sessionID.uuidString)
            #expect(
                object["challenge"] as? String ==
                    challenge.base64EncodedString()
            )
            #expect(binding.sessionID == sessionID)
            #expect(status.st_mode & mode_t(0o777) == mode_t(0o600))
            #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
            #expect(status.st_nlink == 1)
            #expect(backend.reserveCallCount == 1)
            #expect(backend.createCallCount == 1)
            #expect(backend.publicKeyCallCount == 2)
            #expect(backend.signatureCallCount == 1)
            #expect(backend.deleteCallCount == 0)
            #expect(backend.releaseCallCount == 0)
        }
    }

    @Test
    func existingOrSymlinkOutputFailsBeforeEnrollment() throws {
        try withPrivateTemporaryDirectory { root in
            let target = root.appendingPathComponent("target.json")
            try Data("sentinel".utf8).write(to: target)
            let existing = root.appendingPathComponent("existing.json")
            try Data("existing".utf8).write(to: existing)
            let symlink = root.appendingPathComponent("binding.json")
            #expect(target.path.withCString { targetPath in
                symlink.path.withCString { symlinkPath in
                    Darwin.symlink(targetPath, symlinkPath)
                }
            } == 0)

            for output in [existing, symlink] {
                let backend = EnrollmentTestKeyBackend()
                let runner = FingerprintEvidenceEnrollmentRunner(
                    authority: SecureEnclaveFingerprintEvidenceAuthority(
                        backend: backend
                    )
                )
                #expect(
                    throws:
                        FingerprintEvidenceEnrollmentError
                            .unsafeOutputEntry
                ) {
                    try runner.run(outputURL: output)
                }
                #expect(backend.reserveCallCount == 0)
                #expect(backend.createCallCount == 0)
            }
            #expect(
                try String(contentsOf: target, encoding: .utf8) ==
                    "sentinel"
            )
            #expect(
                try String(contentsOf: existing, encoding: .utf8) ==
                    "existing"
            )
        }
    }

    @Test
    func invalidEntropyRollsBackReservedOutputBeforeCreatingKey() throws {
        try withPrivateTemporaryDirectory { root in
            let output = root.appendingPathComponent("binding.json")
            let backend = EnrollmentTestKeyBackend()
            let runner = FingerprintEvidenceEnrollmentRunner(
                authority: SecureEnclaveFingerprintEvidenceAuthority(
                    backend: backend
                ),
                challengeProvider: { Data(repeating: 0, count: 31) }
            )

            #expect(
                throws:
                    FingerprintEvidenceEnrollmentError.invalidEntropy
            ) {
                try runner.run(outputURL: output)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(backend.reserveCallCount == 0)
            #expect(backend.createCallCount == 0)
        }
    }

    @Test
    func persistenceFailureAbandonsEnrolledAuthority() throws {
        let backend = EnrollmentTestKeyBackend()
        let output = FailingEnrollmentOutput()
        let runner = FingerprintEvidenceEnrollmentRunner(
            authority: SecureEnclaveFingerprintEvidenceAuthority(
                backend: backend
            ),
            sessionIDProvider: {
                UUID(
                    uuidString:
                        "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
                )!
            },
            challengeProvider: { Data(repeating: 7, count: 32) },
            outputFactory: { _ in output }
        )

        #expect(throws: FingerprintEvidenceEnrollmentTestError.failed) {
            try runner.run(
                outputURL: URL(fileURLWithPath: "/private/tmp/binding.json")
            )
        }
        #expect(output.rollbackCallCount == 1)
        #expect(backend.createCallCount == 1)
        #expect(backend.signatureCallCount == 1)
        #expect(backend.deleteCallCount == 1)
        #expect(backend.releaseCallCount == 1)
        #expect(backend.keyCount == 0)
    }

    @Test
    func unsafeParentPermissionsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = EnrollmentTestKeyBackend()
        let runner = FingerprintEvidenceEnrollmentRunner(
            authority: SecureEnclaveFingerprintEvidenceAuthority(
                backend: backend
            )
        )

        #expect(
            throws:
                FingerprintEvidenceEnrollmentError
                    .unsafeOutputDirectory
        ) {
            try runner.run(
                outputURL: root.appendingPathComponent("binding.json")
            )
        }
        #expect(backend.createCallCount == 0)
    }

    @Test
    func concurrentEnrollmentOutputHasExactlyOneWinner() throws {
        try withPrivateTemporaryDirectory { root in
            let output = root.appendingPathComponent("binding.json")
            let backend = EnrollmentTestKeyBackend()
            let outcomes = EnrollmentOutcomeCounter()

            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                let runner = FingerprintEvidenceEnrollmentRunner(
                    authority: SecureEnclaveFingerprintEvidenceAuthority(
                        backend: backend
                    ),
                    challengeProvider: {
                        Data(repeating: 9, count: 32)
                    }
                )
                do {
                    try runner.run(outputURL: output)
                    outcomes.recordSuccess()
                } catch FingerprintEvidenceEnrollmentError
                    .unsafeOutputEntry
                {
                    outcomes.recordRefusal()
                } catch {
                    outcomes.recordUnexpected()
                }
            }

            #expect(outcomes.successCount == 1)
            #expect(outcomes.refusalCount == 7)
            #expect(outcomes.unexpectedCount == 0)
            #expect(backend.reserveCallCount == 1)
            #expect(backend.createCallCount == 1)
            #expect(FileManager.default.fileExists(atPath: output.path))
        }
    }

    private func withPrivateTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}

private enum FingerprintEvidenceEnrollmentTestError: Error {
    case failed
}

private final class EnrollmentOutcomeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    private var refusals = 0
    private var unexpected = 0

    var successCount: Int { locked { successes } }
    var refusalCount: Int { locked { refusals } }
    var unexpectedCount: Int { locked { unexpected } }

    func recordSuccess() {
        locked { successes += 1 }
    }

    func recordRefusal() {
        locked { refusals += 1 }
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

private final class FailingEnrollmentOutput:
    FingerprintEvidenceEnrollmentOutput
{
    var isCommitted = false
    private(set) var rollbackCallCount = 0

    func commit(_ data: Data) throws {
        throw FingerprintEvidenceEnrollmentTestError.failed
    }

    func rollback() {
        rollbackCallCount += 1
    }
}

private final class EnrollmentTestKeyBackend:
    SecureEnclaveFingerprintEvidenceKeyBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var reservations: Set<Data> = []
    private var keys: [Data: P256.Signing.PrivateKey] = [:]
    private var reserveCalls = 0
    private var publicKeyCalls = 0
    private var createCalls = 0
    private var signatureCalls = 0
    private var deleteCalls = 0
    private var releaseCalls = 0

    var reserveCallCount: Int { locked { reserveCalls } }
    var publicKeyCallCount: Int { locked { publicKeyCalls } }
    var createCallCount: Int { locked { createCalls } }
    var signatureCallCount: Int { locked { signatureCalls } }
    var deleteCallCount: Int { locked { deleteCalls } }
    var releaseCallCount: Int { locked { releaseCalls } }
    var keyCount: Int { locked { keys.count } }

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
                throw SecureEnclaveFingerprintEvidenceAuthorityError
                    .alreadyEnrolled
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
                signatureDER: try key.signature(for: message)
                    .derRepresentation
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

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
