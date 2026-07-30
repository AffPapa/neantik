import CryptoKit
import Darwin
import Foundation
import Security

enum FingerprintEvidenceEnrollmentError: LocalizedError, Equatable {
    case invalidOutputPath
    case unsafeOutputDirectory
    case unsafeOutputEntry
    case invalidEntropy
    case selfTestFailed
    case operationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidOutputPath:
            "Путь для данных проверки выпуска недопустим."
        case .unsafeOutputDirectory:
            "Каталог данных проверки выпуска небезопасен."
        case .unsafeOutputEntry:
            "Файл данных проверки выпуска уже существует или небезопасен."
        case .invalidEntropy:
            "Не удалось создать одноразовые данные проверки выпуска."
        case .selfTestFailed:
            "Защищённый ключ не прошёл локальную самопроверку."
        case let .operationFailed(code):
            "Не удалось сохранить данные проверки выпуска (код \(code))."
        }
    }
}

protocol FingerprintEvidenceEnrollmentOutput: AnyObject {
    var isCommitted: Bool { get }
    func commit(_ data: Data) throws
    func rollback()
}

struct FingerprintEvidenceEnrollmentRunner {
    private static let selfTestDomain =
        Data("NeAntik fingerprint enrollment self-test v1\u{0}".utf8)

    private let authority: SecureEnclaveFingerprintEvidenceAuthority
    private let sessionIDProvider: () -> UUID
    private let challengeProvider: () throws -> Data
    private let outputFactory:
        (URL) throws -> any FingerprintEvidenceEnrollmentOutput

    init(
        authority: SecureEnclaveFingerprintEvidenceAuthority =
            SecureEnclaveFingerprintEvidenceAuthority(),
        sessionIDProvider: @escaping () -> UUID = { UUID() },
        challengeProvider: @escaping () throws -> Data = {
            try Self.secureRandomChallenge()
        },
        outputFactory: @escaping (URL) throws ->
            any FingerprintEvidenceEnrollmentOutput = {
                try ReservedFingerprintEvidenceEnrollmentOutput(url: $0)
            }
    ) {
        self.authority = authority
        self.sessionIDProvider = sessionIDProvider
        self.challengeProvider = challengeProvider
        self.outputFactory = outputFactory
    }

    @discardableResult
    func run(outputURL: URL) throws -> FingerprintEvidenceManifestBinding {
        let output = try outputFactory(outputURL)
        var enrolledSessionID: UUID?
        var succeeded = false
        defer {
            if !succeeded && !output.isCommitted {
                if let enrolledSessionID {
                    try? authority.abandon(sessionID: enrolledSessionID)
                }
                output.rollback()
            }
        }

        let sessionID = sessionIDProvider()
        let challenge = try challengeProvider()
        guard challenge.count == 32 else {
            throw FingerprintEvidenceEnrollmentError.invalidEntropy
        }
        let publicKeyX963 = try authority.enroll(sessionID: sessionID)
        enrolledSessionID = sessionID
        let binding = FingerprintEvidenceManifestBinding(
            publicKeyX963: publicKeyX963,
            sessionID: sessionID,
            challenge: challenge
        )
        let validated = try binding.validated()
        let signer = try authority.existingSigner(
            sessionID: sessionID,
            expectedPublicKeyX963: publicKeyX963
        )
        var selfTestTranscript = Self.selfTestDomain
        selfTestTranscript.append(Data(sessionID.uuidString.utf8))
        selfTestTranscript.append(challenge)
        do {
            let signature = try P256.Signing.ECDSASignature(
                derRepresentation: signer.signatureDER(
                    for: selfTestTranscript
                )
            )
            guard validated.publicKey.isValidSignature(
                signature,
                for: selfTestTranscript
            ) else {
                throw FingerprintEvidenceEnrollmentError.selfTestFailed
            }
        } catch let error as FingerprintEvidenceEnrollmentError {
            throw error
        } catch {
            throw FingerprintEvidenceEnrollmentError.selfTestFailed
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(binding)
        try output.commit(data)
        succeeded = true
        return binding
    }

    private static func secureRandomChallenge() throws -> Data {
        var challenge = Data(repeating: 0, count: 32)
        let status = challenge.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return Int32(errSecParam)
            }
            return SecRandomCopyBytes(
                kSecRandomDefault,
                bytes.count,
                baseAddress
            )
        }
        guard status == errSecSuccess else {
            throw FingerprintEvidenceEnrollmentError
                .operationFailed(Int32(status))
        }
        return challenge
    }
}

final class ReservedFingerprintEvidenceEnrollmentOutput:
    FingerprintEvidenceEnrollmentOutput
{
    private let parentDescriptor: Int32
    private let basename: String
    private let createdDevice: dev_t
    private let createdInode: ino_t
    private var fileDescriptor: Int32
    private(set) var isCommitted = false
    private var rolledBack = false

    init(url: URL) throws {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.path != "/",
              url.path == url.standardizedFileURL.path,
              !url.hasDirectoryPath
        else {
            throw FingerprintEvidenceEnrollmentError.invalidOutputPath
        }
        let basename = url.lastPathComponent
        guard !basename.isEmpty,
              basename != ".",
              basename != "..",
              !basename.contains("/")
        else {
            throw FingerprintEvidenceEnrollmentError.invalidOutputPath
        }
        let parentURL = url.deletingLastPathComponent()
        let parentDescriptor = parentURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard parentDescriptor >= 0 else {
            throw FingerprintEvidenceEnrollmentError
                .unsafeOutputDirectory
        }
        var parentStatus = stat()
        var pathStatus = stat()
        let parentFstat = Darwin.fstat(parentDescriptor, &parentStatus)
        let parentLstat = parentURL.path.withCString {
            Darwin.lstat($0, &pathStatus)
        }
        guard parentFstat == 0,
              parentLstat == 0,
              parentStatus.st_dev == pathStatus.st_dev,
              parentStatus.st_ino == pathStatus.st_ino,
              parentStatus.st_uid == geteuid(),
              parentStatus.st_mode & mode_t(S_IFMT) ==
                mode_t(S_IFDIR),
              parentStatus.st_mode & mode_t(0o077) == 0
        else {
            _ = Darwin.close(parentDescriptor)
            throw FingerprintEvidenceEnrollmentError
                .unsafeOutputDirectory
        }

        let descriptor = basename.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            let code = errno
            _ = Darwin.close(parentDescriptor)
            if code == EEXIST || code == ELOOP {
                throw FingerprintEvidenceEnrollmentError
                    .unsafeOutputEntry
            }
            throw FingerprintEvidenceEnrollmentError
                .operationFailed(code)
        }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_uid == geteuid(),
              fileStatus.st_nlink == 1,
              fileStatus.st_mode & mode_t(S_IFMT) ==
                mode_t(S_IFREG)
        else {
            let code = errno == 0 ? EFTYPE : errno
            _ = Darwin.close(descriptor)
            _ = basename.withCString {
                Darwin.unlinkat(parentDescriptor, $0, 0)
            }
            _ = Darwin.fsync(parentDescriptor)
            _ = Darwin.close(parentDescriptor)
            throw FingerprintEvidenceEnrollmentError
                .operationFailed(code)
        }

        self.parentDescriptor = parentDescriptor
        self.basename = basename
        createdDevice = fileStatus.st_dev
        createdInode = fileStatus.st_ino
        fileDescriptor = descriptor
    }

    deinit {
        rollback()
        if fileDescriptor >= 0 {
            _ = Darwin.close(fileDescriptor)
        }
        _ = Darwin.close(parentDescriptor)
    }

    func commit(_ data: Data) throws {
        guard !isCommitted,
              !rolledBack,
              fileDescriptor >= 0
        else {
            throw FingerprintEvidenceEnrollmentError.unsafeOutputEntry
        }
        guard Darwin.fchmod(
            fileDescriptor,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0 else {
            throw operationError()
        }
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else {
                return
            }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(
                    fileDescriptor,
                    pointer,
                    remaining
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw operationError()
                }
                guard written > 0 else {
                    throw FingerprintEvidenceEnrollmentError
                        .operationFailed(EIO)
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw operationError()
        }
        let descriptor = fileDescriptor
        fileDescriptor = -1
        guard Darwin.close(descriptor) == 0 else {
            throw operationError()
        }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw operationError()
        }
        isCommitted = true
    }

    func rollback() {
        guard !isCommitted, !rolledBack else {
            return
        }
        rolledBack = true
        if fileDescriptor >= 0 {
            _ = Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        var currentStatus = stat()
        let status = basename.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &currentStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard status == 0,
              currentStatus.st_dev == createdDevice,
              currentStatus.st_ino == createdInode
        else {
            return
        }
        _ = basename.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
        _ = Darwin.fsync(parentDescriptor)
    }

    private func operationError() -> FingerprintEvidenceEnrollmentError {
        .operationFailed(errno == 0 ? EIO : errno)
    }
}
