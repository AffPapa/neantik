import Darwin
import Foundation

protocol FingerprintEvidenceRecoveryStoring: Sendable {
    func loadEnvelope(identifier: String) throws -> Data?
    func storeEnvelope(_ data: Data, identifier: String) throws
}

struct DiscardingFingerprintEvidenceRecoveryStore:
    FingerprintEvidenceRecoveryStoring, Sendable
{
    func loadEnvelope(identifier: String) throws -> Data? {
        nil
    }

    func storeEnvelope(_ data: Data, identifier: String) throws {}
}

struct FileFingerprintEvidenceRecoveryStore:
    FingerprintEvidenceRecoveryStoring, Sendable
{
    private let anchorDirectory: URL
    private let hierarchy: [String]

    init() {
        anchorDirectory = AppPaths().rootDirectory
        hierarchy = ["ReleaseEvidenceRecovery", "v1"]
    }

    init(rootDirectory: URL) {
        anchorDirectory = rootDirectory.deletingLastPathComponent()
        hierarchy = [rootDirectory.lastPathComponent]
    }

    func loadEnvelope(identifier: String) throws -> Data? {
        guard Self.isClaimIdentifier(identifier) else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        guard let candidate = try openCandidateDirectory(
            identifier: identifier,
            create: false
        ) else {
            return nil
        }
        defer { _ = Darwin.close(candidate) }
        return try readReceipt(parentDescriptor: candidate)
    }

    func storeEnvelope(_ data: Data, identifier: String) throws {
        guard Self.isClaimIdentifier(identifier),
              !data.isEmpty,
              data.count <=
                FingerprintEvidenceEnvelopeCodec.maximumEnvelopeBytes
        else {
            throw FingerprintEvidenceReleaseError.invalidManifest
        }
        guard let candidate = try openCandidateDirectory(
            identifier: identifier,
            create: true
        ) else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        defer { _ = Darwin.close(candidate) }
        let output = try AtomicFingerprintEvidenceReleaseOutput(
            parentDescriptor: candidate,
            basename: "envelope.schema8.json",
            allowIdenticalExisting: true
        )
        try output.commit(data)
    }

    private func openCandidateDirectory(
        identifier: String,
        create: Bool
    ) throws -> Int32? {
        guard anchorDirectory.isFileURL,
              anchorDirectory.path.hasPrefix("/"),
              anchorDirectory.path != "/",
              anchorDirectory.path ==
                anchorDirectory.standardizedFileURL.path,
              !hierarchy.isEmpty,
              hierarchy.allSatisfy(Self.isSafeComponent)
        else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        var current = anchorDirectory.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard current >= 0 else {
            if !create && errno == ENOENT {
                return nil
            }
            throw FingerprintEvidenceReleaseError
                .operationFailed(Int(errno))
        }
        do {
            try validatePrivateDirectory(descriptor: current)
            for component in hierarchy + [identifier] {
                if create {
                    let created = component.withCString {
                        Darwin.mkdirat(
                            current,
                            $0,
                            mode_t(S_IRWXU)
                        )
                    }
                    if created == 0 {
                        guard Darwin.fsync(current) == 0 else {
                            throw FingerprintEvidenceReleaseError
                                .operationFailed(Int(errno))
                        }
                    } else if errno != EEXIST {
                        throw FingerprintEvidenceReleaseError
                            .operationFailed(Int(errno))
                    }
                }
                let next = component.withCString {
                    Darwin.openat(
                        current,
                        $0,
                        O_RDONLY | O_DIRECTORY |
                            O_NOFOLLOW | O_CLOEXEC
                    )
                }
                if next < 0 {
                    if !create && errno == ENOENT {
                        _ = Darwin.close(current)
                        return nil
                    }
                    throw FingerprintEvidenceReleaseError
                        .operationFailed(Int(errno))
                }
                do {
                    try validatePrivateDirectory(descriptor: next)
                } catch {
                    _ = Darwin.close(next)
                    throw error
                }
                _ = Darwin.close(current)
                current = next
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private func readReceipt(parentDescriptor: Int32) throws -> Data? {
        let name = "envelope.schema8.json"
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw FingerprintEvidenceReleaseError
                    .operationFailed(Int(errno))
            }
            return nil
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isPrivateRegularFile(before),
              before.st_size > 0,
              before.st_size <=
                FingerprintEvidenceEnvelopeCodec.maximumEnvelopeBytes
        else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw FingerprintEvidenceReleaseError
                    .operationFailed(Int(errno))
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <=
                    FingerprintEvidenceEnvelopeCodec.maximumEnvelopeBytes
            else {
                throw FingerprintEvidenceReleaseError.unsafeManifest
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Self.sameIdentityAndContentMetadata(before, after),
              data.count == Int(after.st_size)
        else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        return data
    }

    private func validatePrivateDirectory(
        descriptor: Int32
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) ==
                mode_t(S_IFDIR),
              status.st_mode & mode_t(0o077) == 0
        else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
    }

    private static func isPrivateRegularFile(_ status: stat) -> Bool {
        status.st_uid == geteuid() &&
            status.st_nlink == 1 &&
            status.st_mode & mode_t(S_IFMT) ==
                mode_t(S_IFREG) &&
            status.st_mode & mode_t(0o077) == 0
    }

    private static func sameIdentityAndContentMetadata(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty &&
            value != "." &&
            value != ".." &&
            !value.contains("/") &&
            !value.contains("\u{0}")
    }

    private static func isClaimIdentifier(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

final class AtomicFingerprintEvidenceReleaseOutput:
    FingerprintEvidenceEnrollmentOutput
{
    private let parentDescriptor: Int32
    private let basename: String
    private let allowIdenticalExisting: Bool
    private var temporaryName: String?
    private var temporaryDevice: dev_t?
    private var temporaryInode: ino_t?
    private(set) var isCommitted = false
    private(set) var hasExistingEntry = false

    convenience init(
        url: URL,
        allowIdenticalExisting: Bool = false
    ) throws {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.path != "/",
              url.path == url.standardizedFileURL.path,
              !url.hasDirectoryPath,
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".."
        else {
            throw FingerprintEvidenceEnrollmentError.invalidOutputPath
        }
        let parentURL = url.deletingLastPathComponent()
        let descriptor = parentURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw FingerprintEvidenceEnrollmentError
                .unsafeOutputDirectory
        }
        defer { _ = Darwin.close(descriptor) }
        try self.init(
            parentDescriptor: descriptor,
            basename: url.lastPathComponent,
            allowIdenticalExisting: allowIdenticalExisting
        )
    }

    convenience init(
        parentDescriptor: Int32,
        basename: String,
        allowIdenticalExisting: Bool = false
    ) throws {
        guard !basename.isEmpty,
              basename != ".",
              basename != "..",
              !basename.contains("/")
        else {
            throw FingerprintEvidenceEnrollmentError.invalidOutputPath
        }
        let ownedDescriptor = Darwin.fcntl(
            parentDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard ownedDescriptor >= 0 else {
            throw FingerprintEvidenceEnrollmentError
                .operationFailed(errno)
        }
        try self.init(
            ownedParentDescriptor: ownedDescriptor,
            basename: basename,
            allowIdenticalExisting: allowIdenticalExisting
        )
    }

    private init(
        ownedParentDescriptor: Int32,
        basename: String,
        allowIdenticalExisting: Bool
    ) throws {
        parentDescriptor = ownedParentDescriptor
        self.basename = basename
        self.allowIdenticalExisting = allowIdenticalExisting
        var status = stat()
        guard Darwin.fstat(parentDescriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) ==
                mode_t(S_IFDIR),
              status.st_mode & mode_t(0o077) == 0
        else {
            _ = Darwin.close(parentDescriptor)
            throw FingerprintEvidenceEnrollmentError
                .unsafeOutputDirectory
        }
        var existing = stat()
        let result = basename.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &existing,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            guard allowIdenticalExisting,
                  Self.isSafeRegular(existing)
            else {
                _ = Darwin.close(parentDescriptor)
                throw FingerprintEvidenceEnrollmentError
                    .unsafeOutputEntry
            }
            hasExistingEntry = true
        } else if errno != ENOENT {
            let code = errno
            _ = Darwin.close(parentDescriptor)
            throw FingerprintEvidenceEnrollmentError
                .operationFailed(code)
        }
    }

    deinit {
        rollback()
        _ = Darwin.close(parentDescriptor)
    }

    func commit(_ data: Data) throws {
        guard !isCommitted else {
            throw FingerprintEvidenceEnrollmentError.unsafeOutputEntry
        }
        if allowIdenticalExisting,
           let existing = try existingData() {
            guard existing == data else {
                throw FingerprintEvidenceEnrollmentError
                    .unsafeOutputEntry
            }
            isCommitted = true
            return
        }

        let temporary =
            ".\(basename).\(UUID().uuidString).pending"
        let descriptor = temporary.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
                    O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw FingerprintEvidenceEnrollmentError
                .operationFailed(errno)
        }
        var created = stat()
        guard Darwin.fstat(descriptor, &created) == 0,
              Self.isSafeRegular(created)
        else {
            let code = errno == 0 ? EFTYPE : errno
            _ = Darwin.close(descriptor)
            _ = temporary.withCString {
                Darwin.unlinkat(parentDescriptor, $0, 0)
            }
            throw FingerprintEvidenceEnrollmentError
                .operationFailed(code)
        }
        temporaryName = temporary
        temporaryDevice = created.st_dev
        temporaryInode = created.st_ino
        var descriptorIsOpen = true
        do {
            try Self.writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw FingerprintEvidenceEnrollmentError
                    .operationFailed(errno)
            }
            descriptorIsOpen = false
            guard Darwin.close(descriptor) == 0 else {
                throw FingerprintEvidenceEnrollmentError
                    .operationFailed(errno)
            }
            let renamed = temporary.withCString { source in
                basename.withCString { destination in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if renamed != 0 {
                if errno == EEXIST,
                   allowIdenticalExisting,
                   try existingData() == data {
                    rollback()
                    isCommitted = true
                    return
                }
                throw FingerprintEvidenceEnrollmentError
                    .operationFailed(errno)
            }
            temporaryName = nil
            temporaryDevice = nil
            temporaryInode = nil
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw FingerprintEvidenceEnrollmentError
                    .operationFailed(errno)
            }
            isCommitted = true
            hasExistingEntry = true
        } catch {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            rollback()
            throw error
        }
    }

    func rollback() {
        guard let temporaryName,
              let temporaryDevice,
              let temporaryInode
        else {
            return
        }
        var current = stat()
        let result = temporaryName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &current,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0,
           current.st_dev == temporaryDevice,
           current.st_ino == temporaryInode {
            _ = temporaryName.withCString {
                Darwin.unlinkat(parentDescriptor, $0, 0)
            }
            _ = Darwin.fsync(parentDescriptor)
        }
        self.temporaryName = nil
        self.temporaryDevice = nil
        self.temporaryInode = nil
    }

    private func existingData() throws -> Data? {
        let descriptor = basename.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw FingerprintEvidenceEnrollmentError
                    .operationFailed(errno)
            }
            return nil
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              Self.isSafeRegular(status),
              status.st_size <=
                FingerprintEvidenceEnvelopeCodec.maximumEnvelopeBytes
        else {
            throw FingerprintEvidenceEnrollmentError
                .unsafeOutputEntry
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(
                descriptor,
                &buffer,
                buffer.count
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw FingerprintEvidenceEnrollmentError
                    .operationFailed(errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <=
                    FingerprintEvidenceEnvelopeCodec
                        .maximumEnvelopeBytes
            else {
                throw FingerprintEvidenceEnrollmentError
                    .unsafeOutputEntry
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Self.sameIdentityAndContentMetadata(status, after),
              data.count == Int(after.st_size)
        else {
            throw FingerprintEvidenceEnrollmentError
                .unsafeOutputEntry
        }
        return data
    }

    private static func sameIdentityAndContentMetadata(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isSafeRegular(_ status: stat) -> Bool {
        status.st_uid == geteuid() &&
            status.st_nlink == 1 &&
            status.st_mode & mode_t(S_IFMT) ==
                mode_t(S_IFREG) &&
            status.st_mode & mode_t(0o077) == 0
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else {
                return
            }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(
                    descriptor,
                    pointer,
                    remaining
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FingerprintEvidenceEnrollmentError
                        .operationFailed(errno)
                }
                guard written > 0 else {
                    throw FingerprintEvidenceEnrollmentError
                        .operationFailed(EIO)
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }
}
