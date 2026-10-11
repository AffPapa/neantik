import CryptoKit
import Darwin
import Foundation

public enum InstallFilesystemError: Error, Equatable {
    case unsafe, changed, busy, pending, unsupported, limit, invalidAcknowledgement
}

struct InstallObject: Codable, Equatable {
    let device: Int64, inode: UInt64, owner: UInt32, mode: UInt16, links: UInt16, size: Int64
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    let flags: UInt32
    init(_ s: stat) {
        device = Int64(s.st_dev); inode = UInt64(s.st_ino); owner = s.st_uid; mode = s.st_mode
        links = s.st_nlink; size = s.st_size; flags = s.st_flags
        modifiedSeconds = Int64(s.st_mtimespec.tv_sec); modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
        changedSeconds = Int64(s.st_ctimespec.tv_sec); changedNanos = Int64(s.st_ctimespec.tv_nsec)
    }
    var directory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var file: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    var symlink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    func sameObject(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && owner == other.owner && mode == other.mode && flags == other.flags
    }
    /// Bundle relocation and macOS metadata bookkeeping can change only the
    /// root's ctime. Keep every other root field, and all descendant metadata,
    /// namespace and bytes exact. This does not authenticate extended attributes.
    func sameBundleRoot(_ other: Self) -> Bool {
        sameObject(other) && directory && other.directory && links == other.links && size == other.size &&
            modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
    }
}

enum InstallFS {
    static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    static func object(_ fd: Int32) throws -> InstallObject {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw posix() }; return InstallObject(s)
    }
    static func entry(_ fd: Int32, _ name: String) throws -> InstallObject? {
        var s = stat()
        guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }; throw posix()
        }
        return InstallObject(s)
    }
    static func name(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              name == name.precomposedStringWithCanonicalMapping,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw InstallFilesystemError.unsafe }
    }
    /// Walk all ancestors without following links. No chmod, chown or privilege escalation.
    static func directory(_ url: URL) throws -> Int32 {
        // Foundation's standardizedFileURL can collapse macOS /private aliases.
        // Validate raw components and nofollow descriptors instead.
        guard url.isFileURL, url.path.hasPrefix("/") else { throw InstallFilesystemError.unsafe }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }
        do {
            for part in url.pathComponents.dropFirst() {
                try name(part)
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw InstallFilesystemError.unsafe }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func noACL(_ fd: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // Darwin represents a missing extended ACL as ENOENT.
            guard errno == ENOENT else { throw posix() }; return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var item: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &item)
        // Darwin returns 0 for an entry and -1/EINVAL for an empty ACL;
        // Linux's 1/0 iteration convention is not applicable here.
        guard result == -1, errno == EINVAL, item == nil else { throw InstallFilesystemError.unsafe }
    }
    static func owned(_ object: InstallObject, device: Int64? = nil) throws {
        guard object.owner == geteuid(), object.flags == 0, object.mode & 0o7000 == 0,
              device == nil || object.device == device else { throw InstallFilesystemError.unsafe }
        if !object.symlink { guard object.mode & 0o022 == 0 else { throw InstallFilesystemError.unsafe } }
        if object.file || object.symlink { guard object.links == 1 else { throw InstallFilesystemError.unsafe } }
    }
    static func privateDirectory(_ fd: Int32) throws -> InstallObject {
        let identity = try object(fd); try owned(identity)
        guard identity.directory, identity.mode & 0o777 == 0o700 else { throw InstallFilesystemError.unsupported }
        try noACL(fd); return identity
    }
    /// A user-owned application folder may be readable by other users. Its
    /// write authority stays with this UID; private stages and journals retain
    /// their separate 0700 contract. Never repair permissions in place.
    static func applicationParentDirectory(_ fd: Int32) throws -> InstallObject {
        let identity = try object(fd); try owned(identity)
        let mode = identity.mode & 0o777
        guard identity.directory, mode == 0o700 || mode == 0o755 else { throw InstallFilesystemError.unsupported }
        try noACL(fd); return identity
    }
    static func names(_ fd: Int32) throws -> [String] {
        try directoryNames(fd, prefix: nil)
    }
    /// The application parent also contains unrelated user files. Select only
    /// our ASCII transaction namespace before decoding/validating names. Bad
    /// names in that namespace still refuse; app/stage/journal scans stay strict.
    static func installParentNames(_ fd: Int32) throws -> [String] {
        try directoryNames(fd, prefix: Array(".neantik-install-".utf8))
    }
    private static func directoryNames(_ fd: Int32, prefix: [UInt8]?) throws -> [String] {
        let copy = dup(fd); guard copy >= 0 else { throw posix() }
        guard let stream = fdopendir(copy) else { close(copy); throw posix() }
        defer { closedir(stream) }; rewinddir(stream)
        var result: [String] = [], visited = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw posix() }; break }
            let bytes = withUnsafePointer(to: &entry.pointee.d_name) { p in
                p.withMemoryRebound(to: UInt8.self, capacity: 256) {
                    Array(UnsafeBufferPointer(start: $0, count: 256).prefix { $0 != 0 })
                }
            }
            if bytes == [46] || bytes == [46, 46] { continue }
            visited += 1; guard visited <= 6_000 else { throw InstallFilesystemError.limit }
            if let prefix, !bytes.starts(with: prefix) { continue }
            guard let name = String(bytes: bytes, encoding: .utf8) else { throw InstallFilesystemError.unsafe }
            try self.name(name)
            result.append(name)
        }
        return result.sorted()
    }
    static func bytes(_ fd: Int32, maximum: Int) throws -> Data {
        let before = try object(fd); try owned(before)
        guard before.file, before.size >= 0, before.size <= maximum, before.mode & 0o777 == 0o600 else { throw InstallFilesystemError.unsafe }
        let length = Int(before.size)
        var data = Data(count: length), offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset), length - offset, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw InstallFilesystemError.changed }; offset += count
        }
        guard try object(fd) == before else { throw InstallFilesystemError.changed }; return data
    }
    static func write(_ fd: Int32, _ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posix() }; offset += count
        }
    }
    static func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw posix() } }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validHash(_ hash: String) -> Bool { hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

@_silgen_name("flock") private func installFlock(_ fd: Int32, _ operation: Int32) -> Int32

/// Cooperation lock for one user-owned install parent. It is not trust, process
/// authority or protection from arbitrary same-UID writers. Never unlink it.
public final class InstallFilesystemLease {
    static let lockName = ".neantik-install.lock"
    let url: URL, parent: Int32, lock: Int32, identity: InstallObject, lockIdentity: InstallObject
    public init(parentURL: URL) throws {
        let openedParent = try InstallFS.directory(parentURL)
        var held = false, opened: Int32 = -1
        defer { if !held { if opened >= 0 { close(opened) }; close(openedParent) } }
        let parentObject = try InstallFS.applicationParentDirectory(openedParent)
        opened = openat(openedParent, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw InstallFilesystemError.unsafe }
        let lockObject = try InstallFS.object(opened); try InstallFS.owned(lockObject, device: parentObject.device)
        guard lockObject.file, lockObject.size == 0, lockObject.mode & 0o777 == 0o600 else { throw InstallFilesystemError.unsafe }
        try InstallFS.noACL(opened)
        guard installFlock(opened, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw InstallFilesystemError.busy }; throw InstallFS.posix()
        }
        let fresh = try InstallFS.directory(parentURL); defer { close(fresh) }
        guard try InstallFS.applicationParentDirectory(fresh).sameObject(parentObject),
              try InstallFS.applicationParentDirectory(openedParent).sameObject(parentObject),
              try InstallFS.object(opened) == lockObject, try InstallFS.entry(openedParent, Self.lockName) == lockObject else { throw InstallFilesystemError.changed }
        url = parentURL; parent = openedParent; lock = opened; identity = parentObject; lockIdentity = lockObject
        held = true
    }
    deinit { _ = installFlock(lock, LOCK_UN); close(lock); close(parent) }
    /// Fixed installed slot derived from this retained lease, never caller argv.
    package func validatedApplicationURL() throws -> URL {
        try validate()
        return url.appendingPathComponent(InstallFilesystemTransaction.appName)
    }
    func validate() throws {
        let fresh = try InstallFS.directory(url); defer { close(fresh) }
        guard try InstallFS.applicationParentDirectory(fresh).sameObject(identity),
              try InstallFS.applicationParentDirectory(parent).sameObject(identity),
              try InstallFS.object(lock) == lockIdentity, try InstallFS.entry(parent, Self.lockName) == lockIdentity else { throw InstallFilesystemError.changed }
        try InstallFS.noACL(lock)
    }
}

/// Records content and inode custody of actual directory trees, including
/// relative framework symlinks. Links are recorded, never walked. No app launch.
struct InstallTree: Codable, Equatable {
    struct Entry: Codable, Equatable { let path: String, identity: InstallObject, sha256: String, target: String? }
    let root: InstallObject
    let entries: [Entry]
    static func capture(parent: Int32, name: String, checksCancellation: Bool = true,
                        onChanged: (String) -> Void = { _ in },
                        beforeScanRecheck: (String) throws -> Void = { _ in }) throws -> Self {
        func changed(_ phase: String) -> InstallFilesystemError { onChanged(phase); return .changed }
        try InstallFS.name(name)
        guard let observed = try InstallFS.entry(parent, name), observed.directory,
              observed.device == (try InstallFS.object(parent)).device else { throw InstallFilesystemError.unsafe }
        let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw InstallFilesystemError.unsafe }; defer { close(root) }
        guard try InstallFS.object(root).sameBundleRoot(observed) else { throw changed("root-before") }
        try InstallFS.owned(observed); try InstallFS.noACL(root)
        var entries: [Entry] = [], total: Int64 = 0
        func scan(_ fd: Int32, _ prefix: String, _ depth: Int) throws {
            if checksCancellation { try Task.checkCancellation() }; guard depth <= 32 else { throw InstallFilesystemError.limit }
            let before = try InstallFS.object(fd), names = try InstallFS.names(fd)
            for name in names {
                if checksCancellation { try Task.checkCancellation() }; guard entries.count < 6_000 else { throw InstallFilesystemError.limit }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard path.utf8.count <= 1_024, let object = try InstallFS.entry(fd, name) else { throw changed("entry-before") }
                try InstallFS.owned(object, device: observed.device)
                if object.symlink {
                    var buffer = [CChar](repeating: 0, count: 1_025)
                    let count = readlinkat(fd, name, &buffer, buffer.count)
                    guard count > 0, count <= 1_024,
                          let target = String(bytes: buffer.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8),
                          !target.hasPrefix("/"), !target.contains("\\"), !target.contains("\0") else { throw InstallFilesystemError.unsafe }
                    var components = path.split(separator: "/").dropLast().map(String.init)
                    for part in target.split(separator: "/", omittingEmptySubsequences: false) {
                        if part == "." { continue }
                        if part == ".." { guard !components.isEmpty else { throw InstallFilesystemError.unsafe }; components.removeLast() }
                        else { try InstallFS.name(String(part)); components.append(String(part)) }
                    }
                    guard !components.isEmpty else { throw InstallFilesystemError.unsafe }
                    entries.append(.init(path: path, identity: object, sha256: "", target: target))
                } else {
                    guard object.directory || object.file else { throw InstallFilesystemError.unsafe }
                    let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (object.directory ? O_DIRECTORY : 0))
                    guard child >= 0 else { throw InstallFilesystemError.unsafe }; defer { close(child) }
                    guard try InstallFS.object(child) == object else { throw changed("child-before") }
                    try InstallFS.noACL(child)
                    if object.directory {
                        entries.append(.init(path: path, identity: object, sha256: "", target: nil)); try scan(child, path, depth + 1)
                    } else {
                        guard object.size >= 0, object.size <= 1_073_741_824 - total else { throw InstallFilesystemError.limit }; total += object.size
                        var hash = SHA256(), offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 1_048_576)
                        while offset < object.size {
                            if checksCancellation { try Task.checkCancellation() }
                            let size = Int(min(Int64(buffer.count), object.size - offset))
                            let count = pread(child, &buffer, size, off_t(offset))
                            if count < 0, errno == EINTR { continue }
                            guard count > 0 else { throw changed("read-eof") }
                            hash.update(data: Data(buffer.prefix(count))); offset += Int64(count)
                        }
                        entries.append(.init(path: path, identity: object, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), target: nil))
                    }
                    guard try InstallFS.object(child) == object else { throw changed("child-after") }
                }
                guard try InstallFS.entry(fd, name) == object else { throw changed("entry-after") }
            }
            try beforeScanRecheck(prefix)
            let after = try InstallFS.object(fd)
            guard prefix.isEmpty ? after.sameBundleRoot(before) : after == before else {
                let fields = [("device", after.device != before.device), ("inode", after.inode != before.inode),
                    ("owner", after.owner != before.owner), ("mode", after.mode != before.mode),
                    ("links", after.links != before.links), ("size", after.size != before.size),
                    ("mtime", after.modifiedSeconds != before.modifiedSeconds || after.modifiedNanos != before.modifiedNanos),
                    ("ctime", after.changedSeconds != before.changedSeconds || after.changedNanos != before.changedNanos),
                    ("flags", after.flags != before.flags)].filter { $0.1 }.map { $0.0 }.joined(separator: "-")
                throw changed("scan-stat-" + fields + (prefix.isEmpty ? "-root" : "-descendant"))
            }
            guard try InstallFS.names(fd) == names else { throw changed("scan-names") }
        }
        try scan(root, "", 0)
        // Catch a late write/rename to an earlier entry while hashing a later
        // one. This is custody detection, not resistance to a hostile same UID.
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        for item in entries where item.target != nil {
            var parts = item.path.split(separator: "/").dropLast().map(String.init)
            var pending = item.target!.split(separator: "/", omittingEmptySubsequences: false).map(String.init), expanded = 0
            while !pending.isEmpty {
                let part = pending.removeFirst()
                if part == "." { continue }
                if part == ".." { guard !parts.isEmpty else { throw InstallFilesystemError.unsafe }; parts.removeLast(); continue }
                try InstallFS.name(part); parts.append(part)
                guard let destination = byPath[parts.joined(separator: "/")] else { throw InstallFilesystemError.unsafe }
                if let next = destination.target {
                    expanded += 1; guard expanded <= 32 else { throw InstallFilesystemError.unsafe }
                    parts.removeLast(); pending = next.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + pending
                } else { guard pending.isEmpty || destination.identity.directory else { throw InstallFilesystemError.unsafe } }
            }
            guard !parts.isEmpty, let target = byPath[parts.joined(separator: "/")], target.target == nil else { throw InstallFilesystemError.unsafe }
        }
        let children = Dictionary(grouping: entries, by: { $0.path.split(separator: "/").dropLast().joined(separator: "/") })
        func recheck(_ fd: Int32, _ prefix: String) throws {
            if checksCancellation { try Task.checkCancellation() }
            let expected = children[prefix] ?? []
            guard try InstallFS.names(fd) == expected.map({ $0.path.split(separator: "/").last!.description }).sorted() else { throw changed("recheck-names") }
            for item in expected {
                let name = item.path.split(separator: "/").last!.description
                guard try InstallFS.entry(fd, name) == byPath[item.path]?.identity else { throw changed("recheck-entry") }
                if item.identity.directory {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw changed("recheck-open") }; defer { close(child) }
                    guard try InstallFS.object(child) == item.identity else { throw changed("recheck-child-before") }
                    try recheck(child, item.path)
                    guard try InstallFS.object(child) == item.identity else { throw changed("recheck-child-after") }
                }
            }
        }
        try recheck(root, "")
        // An ACL change can update ctime without changing mode bits. Root
        // metadata tolerance must never admit a new extended ACL.
        try InstallFS.noACL(root)
        guard try InstallFS.object(root).sameBundleRoot(observed),
              try InstallFS.entry(parent, name)?.sameBundleRoot(observed) == true else { throw changed("root-after") }
        return .init(root: observed, entries: entries.sorted { $0.path < $1.path })
    }
    func matches(_ current: Self) -> Bool {
        root.sameBundleRoot(current.root) && entries == current.entries
    }
}
