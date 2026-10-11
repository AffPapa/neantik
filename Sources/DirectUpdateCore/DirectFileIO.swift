import CryptoKit
import Darwin
import Foundation

/// Fixed bounded filesystem limits, shared with backup framing through regression tests.
package enum DirectFileIOLimits {
    package static let maximumEntries = 100_000
    package static let hashChunkBytes = 1_048_576
    package static let maximumReadBytes = 1_048_613
}

package enum BrowserDataBackupStorageError: LocalizedError, Equatable {
    case unsafeEntry, changed, limitExceeded, incompatibleContext, destinationInsideSource
    package var errorDescription: String? {
        switch self {
        case .unsafeEntry:
            "Не удалось безопасно открыть файл или папку копии. Выбери новый файл в своей папке без символических ссылок. Если ошибка повторяется, сохрани данные профиля и обратись в поддержку."
        case .changed:
            "Файлы изменились во время операции. Закрой профиль и другие версии NeAntik, затем повтори."
        case .limitExceeded:
            "Размер или количество файлов превышает лимит копии. Очисти кэш закрытого профиля и повтори."
        case .incompatibleContext:
            "Копия относится к другому профилю, Mac или движку. Выбери исходную совместимую копию."
        case .destinationInsideSource:
            "Копию нельзя сохранять внутри данных этого профиля. Выбери другую папку."
        }
    }
}
package struct BackupIdentity: Equatable, Codable {
    package let device: dev_t, inode: ino_t, uid: uid_t, mode: mode_t, links: nlink_t, size: Int64
    package let mtimeSeconds: Int, mtimeNanos: Int, ctimeSeconds: Int, ctimeNanos: Int
    package init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; uid = value.st_uid; mode = value.st_mode; links = value.st_nlink; size = value.st_size
        mtimeSeconds = value.st_mtimespec.tv_sec; mtimeNanos = value.st_mtimespec.tv_nsec
        ctimeSeconds = value.st_ctimespec.tv_sec; ctimeNanos = value.st_ctimespec.tv_nsec
    }
    package var directory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    package func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode && uid == other.uid && (mode & mode_t(S_IFMT)) == (other.mode & mode_t(S_IFMT)) }
    /// App-root custody only: system metadata/relocation ctime is not content
    /// identity. Full tree custody and signed-code verification remain separate.
    package func sameBundleRoot(_ other: Self) -> Bool {
        sameObject(other) && directory && other.directory && mode == other.mode && links == other.links &&
            size == other.size && mtimeSeconds == other.mtimeSeconds && mtimeNanos == other.mtimeNanos
    }
    package func validateFile(device: dev_t?) throws {
        guard mode & mode_t(S_IFMT) == mode_t(S_IFREG), links == 1, uid == geteuid(), size >= 0,
              device == nil || self.device == device else { throw BrowserDataBackupStorageError.unsafeEntry }
    }
}

package enum BackupFS {
    package static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    package static func identity(_ fd: Int32) throws -> BackupIdentity {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw posix() }; return .init(value)
    }
    package static func entry(_ parent: Int32, _ name: String) throws -> BackupIdentity? {
        var value = stat(); if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return nil }; throw posix() }; return .init(value)
    }
    package static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw BrowserDataBackupStorageError.unsafeEntry }
    }
    package static func directory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw BrowserDataBackupStorageError.unsafeEntry }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }
        do {
            for part in url.pathComponents.dropFirst() {
                try validateName(part)
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw BrowserDataBackupStorageError.unsafeEntry }
                Darwin.close(fd); fd = next
            }
            let value = try identity(fd)
            guard value.directory, value.uid == geteuid() else { throw BrowserDataBackupStorageError.unsafeEntry }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    package static func validateDirectoryPath(_ url: URL, _ expected: BackupIdentity) throws {
        let fd = try directory(url); defer { Darwin.close(fd) }
        guard try identity(fd).sameObject(expected) else { throw BrowserDataBackupStorageError.changed }
    }
    package static func relativeParent(_ root: Int32, _ path: String) throws -> Int32 {
        try relativeDirectory(root, path.split(separator: "/").dropLast().joined(separator: "/"))
    }
    package static func relativeDirectory(_ root: Int32, _ path: String) throws -> Int32 {
        var fd = dup(root); guard fd >= 0 else { throw posix() }
        do {
            for part in path.split(separator: "/") {
                try validateName(part.description)
                let next = openat(fd, part.description, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw BrowserDataBackupStorageError.unsafeEntry }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    package static func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd); guard copy >= 0 else { throw posix() }
        guard let directory = fdopendir(copy) else { Darwin.close(copy); throw posix() }
        defer { closedir(directory) }; rewinddir(directory)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { if errno != 0 { throw posix() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) } }
            guard let name else { throw BrowserDataBackupStorageError.unsafeEntry }
            if name == "." || name == ".." { continue }
            try validateName(name)
            guard result.count < DirectFileIOLimits.maximumEntries else { throw BrowserDataBackupStorageError.limitExceeded }
            result.append(name)
        }
        return result.sorted()
    }
    package static func read(_ fd: Int32, at offset: Int64, count: Int, checksCancellation: Bool = true) throws -> Data {
        guard count >= 0, count <= DirectFileIOLimits.maximumReadBytes,
              offset >= 0 else { throw BrowserDataBackupStorageError.limitExceeded }
        var bytes = [UInt8](repeating: 0, count: count), readCount = 0
        while readCount < count {
            if checksCancellation { try Task.checkCancellation() }
            let received = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: readCount), count - readCount, offset + Int64(readCount)) }
            if received < 0, errno == EINTR { continue }
            guard received >= 0 else { throw posix() }
            if received == 0 { break }
            readCount += received
        }
        return Data(bytes.prefix(readCount))
    }
    package static func write(_ fd: Int32, _ data: Data, at offset: Int64, checksCancellation: Bool = true) throws {
        var written = 0
        while written < data.count {
            if checksCancellation { try Task.checkCancellation() }
            let count = data.withUnsafeBytes { pwrite(fd, $0.baseAddress!.advanced(by: written), data.count - written, offset + Int64(written)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posix() }; written += count
        }
    }
    package static func hash(_ fd: Int32, size: Int64, checksCancellation: Bool = true) throws -> String {
        var hash = SHA256(), offset: Int64 = 0
        while offset < size {
            let count = Int(min(Int64(DirectFileIOLimits.hashChunkBytes), size - offset))
            let bytes = try read(fd, at: offset, count: count, checksCancellation: checksCancellation)
            guard bytes.count == count else { throw BrowserDataBackupStorageError.changed }
            hash.update(data: bytes); offset += Int64(count)
        }
        return hex(hash.finalize())
    }
    package static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
