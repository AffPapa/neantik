import Darwin
import Foundation

/// Descriptor mechanics only. Callers retain directory policy and error vocabulary.
enum SecureFile {
    enum GuardPolicy {
        case appPaths, proxyHealth

        func failure(_ code: Int32, fallback: POSIXErrorCode, unsafe: Bool = false) -> Error {
            if self == .proxyHealth && unsafe { return ProxyHealthStoreError.unsafePath }
            return POSIXError(POSIXErrorCode(rawValue: code) ?? fallback)
        }
    }

    static func withExclusiveGuard<T>(
        at url: URL, policy: GuardPolicy, _ operation: () throws -> T
    ) throws -> T {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw policy.failure(errno, fallback: .EIO, unsafe: true)
        }
        defer { _ = Darwin.close(descriptor) }
        while neantikFlock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw policy.failure(errno, fallback: .EIO) }
        }
        defer { _ = neantikFlock(descriptor, LOCK_UN) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else {
            throw policy.failure(errno, fallback: .EIO, unsafe: true)
        }
        var entry = stat()
        guard url.path.withCString({ Darwin.lstat($0, &entry) }) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_dev == entry.st_dev, opened.st_ino == entry.st_ino,
              opened.st_nlink == 1
        else { throw policy.failure(ELOOP, fallback: .ELOOP, unsafe: true) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw policy.failure(errno, fallback: policy == .appPaths ? .EACCES : .EIO)
        }
        return try operation()
    }

    static func isPrivateRegular(_ status: stat) -> Bool {
        status.st_uid == geteuid() && status.st_nlink == 1 &&
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) &&
            status.st_mode & mode_t(0o077) == 0
    }

    static func sameIdentityAndContentMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
            lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// Reads an already-open, parent-anchored descriptor; never reopens by path.
    static func readPrivateDescriptor(
        _ descriptor: Int32, minimumBytes: Int, maximumBytes: Int,
        unsafe: () -> Error, failed: (Int32) -> Error
    ) throws -> Data {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              isPrivateRegular(before), before.st_size >= minimumBytes,
              before.st_size <= maximumBytes
        else { throw unsafe() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw failed(errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else { throw unsafe() }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameIdentityAndContentMetadata(before, after),
              data.count == Int(after.st_size)
        else { throw unsafe() }
        return data
    }
}
