import Darwin
import Foundation

enum WebKitSessionError: LocalizedError {
    case invalid, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: "Сохранённые вкладки не удалось прочитать. Открой стартовую страницу и сохрани вкладки заново."
        case .unavailable: "Не удалось сохранить или удалить список вкладок. Проверь доступ к папке данных NeAntik."
        }
    }
}

/// Navigation addresses only. This is deliberately separate from reusable
/// profile metadata, website data, exports and MCP responses.
struct WebKitSessionSnapshot: Codable, Equatable, Sendable {
    static let maximumBytes = 256 * 1024
    static let maximumURLBytes = 4096
    let schemaVersion: Int
    let profileID: UUID
    let urls: [String]
    let selectedIndex: Int
    let unavailableCount: Int

    static func capture(profileID: UUID, urls: [String], selectedIndex: Int) throws -> Self {
        var unavailable = 0
        let safe = urls.map { value in
            if permits(value) { return value }
            unavailable += 1
            return "about:blank"
        }
        let result = Self(schemaVersion: 1, profileID: profileID, urls: safe,
                          selectedIndex: selectedIndex, unavailableCount: unavailable)
        try result.validate(for: profileID)
        return result
    }

    static func permits(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumURLBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if value == "about:blank" { return true }
        guard let parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              let url = parts.url, url.absoluteString == value else { return false }
        // Query and fragment are part of a working address. Keep them intact
        // in this private opt-in state rather than navigating somewhere else.
        return true
    }

    func validate(for id: UUID) throws {
        guard schemaVersion == 1, profileID == id,
              id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              (1...WebKitProfilePolicy.maximumTabs).contains(urls.count),
              urls.indices.contains(selectedIndex), (0...urls.count).contains(unavailableCount),
              urls.allSatisfy(Self.permits) else { throw WebKitSessionError.invalid }
    }
}

/// Bounded descriptor-based I/O. Profile/process guards must be held by the
/// caller until save finishes; the store itself never touches website data.
struct WebKitSessionStore: Sendable {
    let paths: AppPaths
    // Local test seam only; no metadata, environment or MCP configuration.
    var beforeCommit: (@Sendable () throws -> Void)?
    private static let directory = "WebKitSessions"

    func load(for id: UUID) throws -> WebKitSessionSnapshot? {
        do {
            return try withDirectory(create: false) { directory in
                let name = filename(id)
                guard try entry(directory, name) != nil else { return nil }
                let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw WebKitSessionError.invalid }
                defer { _ = Darwin.close(fd) }
                var before = stat()
                guard fstat(fd, &before) == 0, validFile(before), before.st_size > 0 else {
                    throw WebKitSessionError.invalid
                }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else { throw WebKitSessionError.invalid }
                    if count == 0 { break }
                    guard data.count + count <= WebKitSessionSnapshot.maximumBytes else {
                        throw WebKitSessionError.invalid
                    }
                    data.append(contentsOf: buffer.prefix(count))
                }
                var after = stat()
                guard fstat(fd, &after) == 0, sameFile(before, after),
                      let named = try entry(directory, name), sameFile(after, named),
                      data.count == Int(before.st_size) else { throw WebKitSessionError.invalid }
                let snapshot = try JSONDecoder().decode(WebKitSessionSnapshot.self, from: data)
                try snapshot.validate(for: id)
                return snapshot
            } ?? nil
        } catch { throw WebKitSessionError.invalid }
    }

    func save(_ snapshot: WebKitSessionSnapshot) throws {
        do {
            try snapshot.validate(for: snapshot.profileID)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            guard data.count <= WebKitSessionSnapshot.maximumBytes else { throw WebKitSessionError.invalid }
            _ = try withDirectory(create: true) { directory in
                let name = filename(snapshot.profileID), old = try entry(directory, name)
                let temporary = ".\(UUID().uuidString).session-tmp"
                let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                guard fd >= 0 else { throw WebKitSessionError.unavailable }
                var committed = false
                defer {
                    // Delete only our own temporary inode, never a replaced
                    // name or the final destination after a successful rename.
                    var held = stat(), named = stat()
                    if !committed, fstat(fd, &held) == 0,
                       fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
                       held.st_dev == named.st_dev, held.st_ino == named.st_ino {
                        _ = unlinkat(directory, temporary, 0)
                    }
                    _ = Darwin.close(fd)
                }
                try data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { throw WebKitSessionError.unavailable }
                    var written = 0
                    while written < bytes.count {
                        let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw WebKitSessionError.unavailable }
                        written += count
                    }
                }
                guard fsync(fd) == 0 else { throw WebKitSessionError.unavailable }
                try beforeCommit?()
                let current = try entry(directory, name)
                guard sameOptionalFile(old, current) else { throw WebKitSessionError.unavailable }
                var held = stat(), named = stat()
                guard fstat(fd, &held) == 0, validFile(held),
                      fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      sameFile(held, named), renameat(directory, temporary, directory, name) == 0 else {
                    throw WebKitSessionError.unavailable
                }
                committed = true
                guard fsync(directory) == 0 else { throw WebKitSessionError.unavailable }
            }
        } catch { throw WebKitSessionError.unavailable }
    }

    func discard(for id: UUID) throws {
        do {
            _ = try withDirectory(create: false) { directory in
                let name = filename(id)
                guard try entry(directory, name) != nil else { return }
                guard unlinkat(directory, name, 0) == 0, fsync(directory) == 0 else {
                    throw WebKitSessionError.unavailable
                }
            }
        } catch { throw WebKitSessionError.unavailable }
    }

    private func filename(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }

    private func withDirectory<T>(create: Bool, _ operation: (Int32) throws -> T) throws -> T? {
        // Foundation and Darwin can spell the same macOS temporary root with
        // or without /private. Compare those two system aliases symmetrically;
        // do not normalize a user-created symlink into a different root.
        let url = paths.rootDirectory
        func comparable(_ path: String) -> String {
            path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
        }
        guard url.isFileURL, comparable(url.path) == comparable(url.resolvingSymlinksInPath().path) else {
            throw WebKitSessionError.unavailable
        }
        let root = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if root < 0, !create, errno == ENOENT { return nil }
        guard root >= 0 else { throw WebKitSessionError.unavailable }
        defer { _ = Darwin.close(root) }
        try validateDirectory(root)
        if create, mkdirat(root, Self.directory, mode_t(0o700)) != 0, errno != EEXIST {
            throw WebKitSessionError.unavailable
        }
        let directory = openat(root, Self.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, !create, errno == ENOENT { return nil }
        guard directory >= 0 else { throw WebKitSessionError.unavailable }
        defer { _ = Darwin.close(directory) }
        try validateDirectory(directory)
        func validateNames() throws {
            var heldRoot = stat(), namedRoot = stat(), heldDirectory = stat(), namedDirectory = stat()
            guard fstat(root, &heldRoot) == 0, lstat(url.path, &namedRoot) == 0,
                  heldRoot.st_dev == namedRoot.st_dev, heldRoot.st_ino == namedRoot.st_ino,
                  fstat(directory, &heldDirectory) == 0,
                  fstatat(root, Self.directory, &namedDirectory, AT_SYMLINK_NOFOLLOW) == 0,
                  heldDirectory.st_dev == namedDirectory.st_dev, heldDirectory.st_ino == namedDirectory.st_ino,
                  namedDirectory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw WebKitSessionError.unavailable
            }
            try validateDirectory(root); try validateDirectory(directory)
        }
        try validateNames()
        let result = try operation(directory)
        try validateNames()
        return result
    }

    private func validateDirectory(_ fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else { throw WebKitSessionError.unavailable }
    }

    private func entry(_ directory: Int32, _ name: String) throws -> stat? {
        var value = stat()
        if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw WebKitSessionError.unavailable
        }
        guard validFile(value) else { throw WebKitSessionError.unavailable }
        return value
    }

    private func validFile(_ value: stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && value.st_uid == geteuid() &&
        value.st_nlink == 1 && value.st_mode & 0o077 == 0 &&
        value.st_size >= 0 && value.st_size <= WebKitSessionSnapshot.maximumBytes
    }

    private func sameOptionalFile(_ a: stat?, _ b: stat?) -> Bool {
        switch (a, b) { case (nil, nil): true; case let (a?, b?): sameFile(a, b); default: false }
    }

    private func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
        a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
