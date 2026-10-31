import CryptoKit
import Darwin
import Foundation

/// Filesystem custody for the GUI-only control endpoint. Profile metadata and
/// BrowserData are never read here. Existing/foreign entries are not adopted.
enum MCPGUIControlEndpoint {
    typealias Failure = MCPGUIControlProtocol.Failure
    static let descriptorName = ".mcp-gui-control.json"
    private static let lockName = ".mcp-gui-control.lock"

    struct Entry: Equatable, Sendable {
        let device: Int64; let inode: UInt64; let uid: uid_t; let type: mode_t
        init(_ value: stat) { device = Int64(value.st_dev); inode = UInt64(value.st_ino); uid = value.st_uid; type = value.st_mode & mode_t(S_IFMT) }
        func matches(_ value: stat) -> Bool { self == Entry(value) }
    }
    struct FrozenFile: Sendable {
        let entry: Entry; let size: Int64; let modifiedSeconds: Int64; let modifiedNanos: Int64
        let changedSeconds: Int64; let changedNanos: Int64
        init(_ value: stat) {
            entry = Entry(value); size = Int64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
        func matches(_ value: stat) -> Bool {
            entry.matches(value) && size == value.st_size && modifiedSeconds == value.st_mtimespec.tv_sec && modifiedNanos == value.st_mtimespec.tv_nsec &&
                changedSeconds == value.st_ctimespec.tv_sec && changedNanos == value.st_ctimespec.tv_nsec && validFile(value)
        }
    }
    struct Descriptor: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let generation: UUID
        let libraryIdentitySHA256: String
        let directoryDevice: Int64
        let directoryInode: UInt64
        let socketDevice: Int64
        let socketInode: UInt64
        let managerPID: pid_t
        let managerStartSeconds: Int64
        let managerStartMicroseconds: Int32

        func validate() throws {
            guard schemaVersion == 1, generation != MCPGUIControlProtocol.Request.zero,
                  MCPGUIControlProtocol.Request.hash(libraryIdentitySHA256), directoryInode > 0, socketInode > 0,
                  managerPID > 1, managerStartSeconds > 0, (0..<1_000_000).contains(managerStartMicroseconds) else { throw Failure.malformed }
        }
        var ownerDefinitelyGone: Bool {
            if let current = ProxyRelaySocketOwnerInspector.processIdentity(managerPID) {
                return current.generation.startSeconds != managerStartSeconds || current.generation.startMicroseconds != managerStartMicroseconds
            }
            return Darwin.kill(managerPID, 0) < 0 && errno == ESRCH
        }
    }

    final class Library: @unchecked Sendable {
        let path: String
        let descriptor: Int32
        let entry: Entry
        let identitySHA256: String
        private let lockDescriptor: Int32
        private let lockEntry: Entry?

        init(root: URL, exclusive: Bool) throws {
            let path = root.standardizedFileURL.path
            let directory = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw Failure.unavailable }
            var guardFD: Int32 = -1
            do {
                var info = stat(), named = stat()
                guard fstat(directory, &info) == 0, lstat(path, &named) == 0, validDirectory(info), Entry(info).matches(named) else { throw Failure.unavailable }
                var guardEntry: Entry?
                if exclusive {
                    guardFD = openat(directory, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
                    var value = stat(), current = stat()
                    guard guardFD >= 0, fstat(guardFD, &value) == 0, validFile(value), value.st_size == 0,
                          fstatat(directory, lockName, &current, AT_SYMLINK_NOFOLLOW) == 0, Entry(value).matches(current),
                          flock(guardFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
                    guardEntry = Entry(value)
                }
                self.path = path; descriptor = directory; entry = Entry(info); lockDescriptor = guardFD; lockEntry = guardEntry
                let input = "neantik-mcp-gui-library-v1:\(info.st_dev):\(info.st_ino):\(info.st_uid)"
                identitySHA256 = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            } catch {
                if guardFD >= 0 { _ = Darwin.close(guardFD) }
                _ = Darwin.close(directory); throw error
            }
        }
        var isCurrent: Bool {
            var info = stat(), named = stat()
            guard fstat(descriptor, &info) == 0, lstat(path, &named) == 0, validDirectory(info), validDirectory(named), entry.matches(info), entry.matches(named) else { return false }
            if let lockEntry {
                var held = stat(), current = stat()
                guard fstat(lockDescriptor, &held) == 0, fstatat(descriptor, lockName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      validFile(held), validFile(current), held.st_size == 0, current.st_size == 0,
                      lockEntry.matches(held), lockEntry.matches(current) else { return false }
            }
            return true
        }
        func fileIsCurrent(_ expected: FrozenFile) -> Bool {
            var current = stat()
            return isCurrent && fstatat(descriptor, descriptorName, &current, AT_SYMLINK_NOFOLLOW) == 0 && expected.matches(current)
        }
        func read() throws -> (Descriptor, FrozenFile) {
            guard isCurrent else { throw Failure.unavailable }
            let fd = openat(descriptor, descriptorName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { _ = Darwin.close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, validFile(before), before.st_size > 0,
                  before.st_size <= MCPGUIControlProtocol.maximumMessageBytes else { throw Failure.unavailable }
            var data = Data(count: Int(before.st_size))
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            let frozen = FrozenFile(before)
            guard count == data.count, fstat(fd, &after) == 0, frozen.matches(after), fileIsCurrent(frozen) else { throw Failure.unavailable }
            try ImportJSONShape.validate(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == [
                "schemaVersion", "generation", "libraryIdentitySHA256", "directoryDevice", "directoryInode", "socketDevice", "socketInode",
                "managerPID", "managerStartSeconds", "managerStartMicroseconds"] else { throw Failure.malformed }
            let value = try JSONDecoder().decode(Descriptor.self, from: data); try value.validate()
            guard value.libraryIdentitySHA256 == identitySHA256 else { throw Failure.unavailable }
            return (value, frozen)
        }
        func publish(_ value: Descriptor) throws -> FrozenFile {
            try publish(value, beforeCommit: nil)
        }
#if DEBUG
        func publishForTesting(_ value: Descriptor, beforeCommit: @escaping () throws -> Void) throws -> FrozenFile {
            try publish(value, beforeCommit: beforeCommit)
        }
#endif
        private func publish(_ value: Descriptor, beforeCommit: (() throws -> Void)?) throws -> FrozenFile {
            guard lockEntry != nil, isCurrent, value.libraryIdentitySHA256 == identitySHA256 else { throw Failure.unavailable }
            try value.validate()
            let data = try JSONEncoder().encode(value)
            guard data.count <= MCPGUIControlProtocol.maximumMessageBytes else { throw Failure.malformed }
            let stage = ".mcp-gui-control-stage-" + UUID().uuidString.lowercased()
            let fd = openat(descriptor, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.busy }
            defer { _ = Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, validFile(info), info.st_size == 0 else { throw Failure.unavailable }
            let owned = Entry(info)
            var committed = false
            do {
                var offset = 0
                while offset < data.count {
                    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw Failure.unavailable }; offset += written
                }
                guard fsync(fd) == 0, fstat(fd, &info) == 0, owned.matches(info) else { throw Failure.unavailable }
                try beforeCommit?()
                var staged = stat()
                guard isCurrent, fstatat(descriptor, stage, &staged, AT_SYMLINK_NOFOLLOW) == 0,
                      validFile(staged), owned.matches(staged) else { throw Failure.unavailable }
                guard renameatx_np(descriptor, stage, descriptor, descriptorName, UInt32(RENAME_EXCL)) == 0
                else { throw errno == EEXIST ? Failure.busy : Failure.unavailable }
                committed = true
                guard fstat(fd, &info) == 0, owned.matches(info) else { throw Failure.unavailable }
                let result = FrozenFile(info)
                guard fileIsCurrent(result), fsync(descriptor) == 0 else { throw Failure.unavailable }
                return result
            } catch {
                var current = stat()
                let name = committed ? descriptorName : stage
                if isCurrent, fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0, owned.matches(current) { _ = unlinkat(descriptor, name, 0) }
                throw error
            }
        }
        /// Only a validated descriptor whose original process is provably gone
        /// may be retired on an explicit new GUI enable action.
        func retireStaleIfPresent() throws {
            guard lockEntry != nil, isCurrent else { throw Failure.unavailable }
            var info = stat()
            if fstatat(descriptor, descriptorName, &info, AT_SYMLINK_NOFOLLOW) < 0 {
                guard errno == ENOENT else { throw Failure.unavailable }; return
            }
            let (value, file) = try read()
            guard value.ownerDefinitelyGone, fileIsCurrent(file) else { throw Failure.busy }
            retireSocketIfCurrent(value)
            guard fileIsCurrent(file), unlinkat(descriptor, descriptorName, 0) == 0, fsync(descriptor) == 0 else { throw Failure.unavailable }
        }
        func retire(_ file: FrozenFile) {
            if lockEntry != nil, fileIsCurrent(file) { _ = unlinkat(descriptor, descriptorName, 0); _ = fsync(descriptor) }
        }
        deinit {
            if lockDescriptor >= 0 { _ = Darwin.close(lockDescriptor) }
            _ = Darwin.close(descriptor)
        }
    }

    final class Listener: @unchecked Sendable {
        let library: Library
        let value: Descriptor
        let file: FrozenFile
        let descriptor: Int32
        private let directory: Int32
        private let directoryEntry: Entry
        private let socketEntry: Entry
        private let cleanupLock = NSLock()
        private var cleaned = false

        init(library: Library, generation: UUID) throws {
            try library.retireStaleIfPresent()
            let path = rootPath(generation)
            guard mkdir(path, 0o700) == 0 else { throw Failure.unavailable }
            var directory: Int32 = -1, listener: Int32 = -1, directoryEntry: Entry?, socketEntry: Entry?
            do {
                var created = stat()
                guard lstat(path, &created) == 0, validDirectory(created) else { throw Failure.unavailable }
                directoryEntry = Entry(created)
                directory = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var info = stat(), named = stat()
                guard directory >= 0, fstat(directory, &info) == 0, lstat(path, &named) == 0,
                      validDirectory(info), directoryEntry?.matches(info) == true, Entry(info).matches(named) else { throw Failure.unavailable }
                directoryEntry = Entry(info)
                listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0); try prepareSocket(listener)
                try withAddress(path + "/socket") { address, size in
                    guard Darwin.bind(listener, address, size) == 0 else { throw Failure.unavailable }
                }
                var socket = stat()
                guard fstatat(directory, "socket", &socket, AT_SYMLINK_NOFOLLOW) == 0, socket.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), socket.st_uid == geteuid() else { throw Failure.unavailable }
                socketEntry = Entry(socket)
                guard fchmodat(directory, "socket", 0o600, AT_SYMLINK_NOFOLLOW) == 0, Darwin.listen(listener, 8) == 0,
                      let manager = ProxyRelaySocketOwnerInspector.processIdentity(getpid()), manager.userID == geteuid() else { throw Failure.unavailable }
                let value = Descriptor(schemaVersion: 1, generation: generation, libraryIdentitySHA256: library.identitySHA256,
                    directoryDevice: Int64(info.st_dev), directoryInode: info.st_ino, socketDevice: Int64(socket.st_dev), socketInode: socket.st_ino,
                    managerPID: getpid(), managerStartSeconds: manager.generation.startSeconds, managerStartMicroseconds: manager.generation.startMicroseconds)
                guard socketIsCurrent(value), library.isCurrent else { throw Failure.unavailable }
                let file = try library.publish(value)
                self.library = library; self.value = value; self.file = file; self.descriptor = listener; self.directory = directory
                self.directoryEntry = directoryEntry!; self.socketEntry = socketEntry!
            } catch {
                if listener >= 0 { _ = Darwin.close(listener) }
                if let socketEntry {
                    var current = stat()
                    if fstatat(directory, "socket", &current, AT_SYMLINK_NOFOLLOW) == 0, socketEntry.matches(current) { _ = unlinkat(directory, "socket", 0) }
                }
                var named = stat()
                if let directoryEntry, lstat(path, &named) == 0, directoryEntry.matches(named) { _ = Darwin.rmdir(path) }
                if directory >= 0 { _ = Darwin.close(directory) }
                throw error
            }
        }
        var isCurrent: Bool { library.fileIsCurrent(file) && socketIsCurrent(value) }
        func cleanup() {
            cleanupLock.lock(); defer { cleanupLock.unlock() }
            guard !cleaned else { return }; cleaned = true
            _ = Darwin.close(descriptor)
            library.retire(file)
            var named = stat(), held = stat(), socket = stat()
            let path = rootPath(value.generation)
            if fstat(directory, &held) == 0, directoryEntry.matches(held), lstat(path, &named) == 0, directoryEntry.matches(named),
               fstatat(directory, "socket", &socket, AT_SYMLINK_NOFOLLOW) == 0, socketEntry.matches(socket) { _ = unlinkat(directory, "socket", 0) }
            if lstat(path, &named) == 0, directoryEntry.matches(named) { _ = Darwin.rmdir(path) }
            _ = Darwin.close(directory)
        }
        deinit { cleanup() }
    }

    static func rootPath(_ generation: UUID) -> String { "/private/tmp/neantik-mcp-gui-" + generation.uuidString.lowercased() }
    static func socketIsCurrent(_ value: Descriptor) -> Bool {
        var directory = stat(), socket = stat()
        let root = rootPath(value.generation)
        return lstat(root, &directory) == 0 && validDirectory(directory) && Int64(directory.st_dev) == value.directoryDevice && UInt64(directory.st_ino) == value.directoryInode &&
            lstat(root + "/socket", &socket) == 0 && socket.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) && socket.st_uid == geteuid() && socket.st_mode & 0o777 == 0o600 &&
            Int64(socket.st_dev) == value.socketDevice && UInt64(socket.st_ino) == value.socketInode
    }
    private static func retireSocketIfCurrent(_ value: Descriptor) {
        guard socketIsCurrent(value) else { return }
        let path = rootPath(value.generation)
        let directory = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }; defer { _ = Darwin.close(directory) }
        var info = stat(), socket = stat()
        if fstat(directory, &info) == 0, Int64(info.st_dev) == value.directoryDevice, UInt64(info.st_ino) == value.directoryInode,
           socketIsCurrent(value), fstatat(directory, "socket", &socket, AT_SYMLINK_NOFOLLOW) == 0,
           Int64(socket.st_dev) == value.socketDevice, UInt64(socket.st_ino) == value.socketInode { _ = unlinkat(directory, "socket", 0) }
        if directoryIsCurrent(value) { _ = Darwin.rmdir(path) }
    }
    private static func directoryIsCurrent(_ value: Descriptor) -> Bool {
        var info = stat()
        return lstat(rootPath(value.generation), &info) == 0 && validDirectory(info) && Int64(info.st_dev) == value.directoryDevice && UInt64(info.st_ino) == value.directoryInode
    }
    static func prepareSocket(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard fd >= 0, flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.unavailable }
    }
    static func withAddress<T>(_ path: String, _ operation: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        let bytes = Array(path.utf8) + [UInt8(0)]
        var value = sockaddr_un(); value.sun_family = sa_family_t(AF_UNIX)
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw Failure.unavailable }
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &value) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    private static func validFile(_ value: stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && value.st_uid == geteuid() && value.st_mode & 0o777 == 0o600 && value.st_nlink == 1
    }
    private static func validDirectory(_ value: stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && value.st_uid == geteuid() && value.st_mode & 0o777 == 0o700
    }
}
