import CryptoKit
import Darwin
import Foundation

enum ProfileCacheError: LocalizedError, Equatable {
    case unsafeEntry, changed, unsupportedLocation, limitExceeded, rollbackRequired, partiallyRemoved
    var errorDescription: String? {
        switch self {
        case .unsafeEntry: "Кэш содержит небезопасный объект. Ничего не удалено; проверь папку профиля."
        case .changed: "Кэш изменился во время проверки. Повтори после закрытия браузера."
        case .unsupportedLocation: "У профиля нестандартная папка кэша. Автоматическая очистка для неё недоступна."
        case .limitExceeded: "Кэш превышает безопасный лимит проверки. Используй очистку в самом браузере."
        case .rollbackRequired: "Очистка остановлена; оставшийся кэш сохранён отдельно. Закрой браузер и выбери «Вернуть оставшийся кэш». Если восстановление не проходит, сохрани папку профиля и обратись в поддержку."
        case .partiallyRemoved: "Часть кэша удалена, но очистка не завершена. Данные сайтов не затронуты. Не удаляй оставшиеся папки вручную: сохрани папку профиля и обратись в поддержку."
        }
    }
}

struct ProfileCacheEstimate: Equatable, Sendable {
    let bytes: Int64
    let files: Int
    let directories: Int
}

enum ProfileCacheCommitPoint: Sendable { case journalCreated, beforeStage(Int), staged(Int), beforeRemoval, removalRecorded, removingRoot(Int), recoveryObserved(Int), recoveryBeforeRename(Int), recoveryRenamed(Int) }

struct ProfileCacheRecoveryResult: Equatable, Sendable {
    let restoredRoots: Int
    let cacheMayAlreadyBeRemoved: Bool
}

/// The allowlist follows Chromium macOS GetUserCacheDirectory. HTTP Cache and
/// Code Cache only: Service Worker, CacheStorage, cookies, databases, Sessions
/// and Extensions are deliberately outside the operation.
struct ProfileCacheMaintenance: Sendable {
    let browserData: URL
    var applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    var libraryCaches: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
    var maximumEntries = 100_000
    var maximumBytes: Int64 = 64 * 1_024 * 1_024 * 1_024
    var fault: (@Sendable (ProfileCacheCommitPoint) throws -> Void)?
    var authority: StoppedProfileMaintenanceAuthority?

    var cacheParent: URL {
        let profile = browserData.appendingPathComponent("Default", isDirectory: true)
        let base = applicationSupport.pathComponents
        let components = profile.pathComponents
        if components.count > base.count, Array(components.prefix(base.count)) == base {
            return components.dropFirst(base.count).reduce(libraryCaches) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
        }
        return profile
    }

    func estimate() throws -> ProfileCacheEstimate {
        let scan = try capture()
        defer { scan.close() }
        return scan.estimate
    }

    /// Re-scan at commit, never trust the preview. All roots are validated
    /// before staging. Pre-removal faults/cancellation roll back owned inodes.
    /// After unlink begins finish the finite deletion; errors report partial
    /// removal rather than promising that cache bytes can be recovered.
    func clear() throws -> ProfileCacheEstimate {
        try authority?.validate(browserData: browserData)
        let scan = try capture()
        defer { scan.close() }
        guard !scan.roots.isEmpty else { return scan.estimate }
        let journal = try CacheJournal.create(parent: scan.parent, browserData: browserData, roots: scan.roots)
        defer { journal.close() }
        var staged: [(String, String, CacheNode)] = []
        var removalStarted = false
        do {
            try fault?(.journalCreated)
            for (index, root) in scan.roots.enumerated() {
                try Task.checkCancellation()
                try fault?(.beforeStage(index))
                try authority?.validate(browserData: browserData)
                try journal.validateLocation(parent: scan.parent, browserData: browserData, cacheParent: cacheParent)
                try journal.validateEntry(parent: scan.parent)
                try root.validate(parent: scan.parent, name: root.name)
                let name = journal.manifest.roots[index].stage
                guard renameatx_np(scan.parent, root.name, scan.parent, name, UInt32(RENAME_EXCL)) == 0 else { throw currentPOSIXError() }
                staged.append((root.name, name, root))
                try root.validate(parent: scan.parent, name: name)
                try fault?(.staged(index))
            }
            try Task.checkCancellation()
            try fault?(.beforeRemoval)
            try Task.checkCancellation()
            // A fault or observed replacement of any later root must refuse
            // before the first root is unlinked.
            for (_, name, root) in staged { try root.validate(parent: scan.parent, name: name) }
            try authority?.validate(browserData: browserData)
            try journal.validateLocation(parent: scan.parent, browserData: browserData, cacheParent: cacheParent)
            // No cancellation or fault injection between finite unlink calls:
            // a cancelled request cannot leave a half-removed staged tree.
            try journal.markRemoving(parent: scan.parent)
            try fault?(.removalRecorded)
            try authority?.validate(browserData: browserData)
            try journal.validateLocation(parent: scan.parent, browserData: browserData, cacheParent: cacheParent)
            removalStarted = !staged.isEmpty
            for (index, entry) in staged.enumerated() {
                try fault?(.removingRoot(index))
                try authority?.validate(browserData: browserData)
                try journal.validateLocation(parent: scan.parent, browserData: browserData, cacheParent: cacheParent)
                try journal.validateEntry(parent: scan.parent)
                try entry.2.remove(parent: scan.parent, name: entry.1)
            }
            if scan.parent >= 0, fsync(scan.parent) != 0 { throw currentPOSIXError() }
            try journal.remove(parent: scan.parent)
            return scan.estimate
        } catch {
            if removalStarted { throw ProfileCacheError.partiallyRemoved }
            // A replaced process guard or live browser invalidates permission
            // to rename too. Preserve staged bytes and durable intent; recovery
            // must reacquire fresh stopped-profile authority.
            do {
                try authority?.validate(browserData: browserData)
                try journal.validateLocation(parent: scan.parent, browserData: browserData, cacheParent: cacheParent)
            } catch { throw ProfileCacheError.rollbackRequired }
            var rollbackFailed = false
            for (original, temporary, root) in staged.reversed() {
                do {
                    try authority?.validate(browserData: browserData)
                    try journal.validateLocation(parent: scan.parent, browserData: browserData, cacheParent: cacheParent)
                    try root.validate(parent: scan.parent, name: temporary)
                    guard renameatx_np(scan.parent, temporary, scan.parent, original, UInt32(RENAME_EXCL)) == 0 else { throw currentPOSIXError() }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw ProfileCacheError.rollbackRequired }
            do { try journal.remove(parent: scan.parent) } catch { throw ProfileCacheError.rollbackRequired }
            throw error
        }
    }

    /// Explicitly restore only journal-bound remaining roots. This never
    /// re-deletes a stage and never claims to recover already unlinked bytes.
    /// The caller must hold the same stopped-profile authority used by clear.
    func recover() throws -> ProfileCacheRecoveryResult {
        try Task.checkCancellation()
        try authority?.validate(browserData: browserData)
        let parent = try openDirectory(cacheParent, allowMissing: false)
        defer { _ = Darwin.close(parent) }
        let journal = try CacheJournal.read(parent: parent, browserData: browserData)
        defer { journal.close() }
        let allowed = Set(journal.manifest.roots.map(\.stage))
        guard !(try names(in: parent)).contains(where: { $0.hasPrefix(".neantik-cache-clearing-") && !allowed.contains($0) }) else { throw ProfileCacheError.rollbackRequired }
        var remaining: [(String, String, CacheNode)] = []
        var budget = CacheBudget(maximumEntries: maximumEntries, maximumBytes: maximumBytes)
        for (index, reference) in journal.manifest.roots.enumerated() {
            let original = try CacheRootIdentity.observe(parent: parent, name: reference.original)
            let staged = try CacheRootIdentity.observe(parent: parent, name: reference.stage)
            try fault?(.recoveryObserved(index))
            guard original == nil || staged == nil else { throw ProfileCacheError.rollbackRequired }
            if let staged {
                guard staged == reference.identity,
                      let node = try CacheNode.capture(parent: parent, name: reference.stage, depth: 0, device: dev_t(journal.manifest.parent.device), budget: &budget), node.isDirectory,
                      CacheRootIdentity(device: Int64(node.identity.device), inode: UInt64(node.identity.inode), uid: UInt32(node.identity.uid)) == reference.identity else { throw ProfileCacheError.rollbackRequired }
                remaining.append((reference.original, reference.stage, node))
            } else if let original {
                guard original == reference.identity else { throw ProfileCacheError.rollbackRequired }
            } else {
                guard journal.removing else { throw ProfileCacheError.rollbackRequired }
            }
        }
        // Validate every tree before changing any name. After this point finish
        // the bounded renames, retaining the journal on failure for retry.
        try Task.checkCancellation()
        for (_, stage, node) in remaining { try node.validate(parent: parent, name: stage) }
        for (index, entry) in remaining.enumerated() {
            try fault?(.recoveryBeforeRename(index))
            try authority?.validate(browserData: browserData)
            try journal.validateLocation(parent: parent, browserData: browserData, cacheParent: cacheParent)
            try journal.validateEntry(parent: parent)
            try entry.2.validate(parent: parent, name: entry.1)
            guard renameatx_np(parent, entry.1, parent, entry.0, UInt32(RENAME_EXCL)) == 0 else { throw ProfileCacheError.rollbackRequired }
            try fault?(.recoveryRenamed(index))
        }
        guard fsync(parent) == 0 else { throw currentPOSIXError() }
        try authority?.validate(browserData: browserData)
        try journal.validateLocation(parent: parent, browserData: browserData, cacheParent: cacheParent)
        try journal.remove(parent: parent)
        return .init(restoredRoots: remaining.count, cacheMayAlreadyBeRemoved: journal.removing)
    }

    private func capture() throws -> CacheScan {
        try Task.checkCancellation()
        // Preferences control the actual cache location. A configured override
        // is unsupported, never silently interpreted as an allowlisted path.
        for preference in [browserData.appendingPathComponent("Local State"), browserData.appendingPathComponent("Default/Preferences")] {
            try rejectCacheOverride(preference)
        }
        let parent = try openDirectory(cacheParent, allowMissing: true)
        guard parent >= 0 else { return CacheScan(parent: -1, roots: [], estimate: .init(bytes: 0, files: 0, directories: 0)) }
        do {
            guard !(try names(in: parent)).contains(where: { $0 == CacheJournal.fileName || $0.hasPrefix(".neantik-cache-clearing-") }) else {
                // Crash/partial-removal stages need explicit recovery. Never
                // delete an object simply because its name looks like ours.
                throw ProfileCacheError.rollbackRequired
            }
            var budget = CacheBudget(maximumEntries: maximumEntries, maximumBytes: maximumBytes)
            var roots: [CacheNode] = []
            var parentStat = stat()
            guard fstat(parent, &parentStat) == 0 else { throw currentPOSIXError() }
            for name in ["Cache", "Code Cache"] {
                if let root = try CacheNode.capture(parent: parent, name: name, depth: 0, device: parentStat.st_dev, budget: &budget) {
                    guard root.isDirectory else { throw ProfileCacheError.unsafeEntry }
                    roots.append(root)
                }
            }
            return CacheScan(parent: parent, roots: roots, estimate: .init(bytes: budget.bytes, files: budget.files, directories: budget.directories))
        } catch { _ = Darwin.close(parent); throw error }
    }

    private func rejectCacheOverride(_ url: URL) throws {
        let parent = try openDirectory(url.deletingLastPathComponent(), allowMissing: true)
        guard parent >= 0 else { return }
        defer { _ = Darwin.close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 { if errno == ENOENT { return }; throw ProfileCacheError.unsafeEntry }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1, before.st_uid == geteuid(), before.st_size >= 0, before.st_size <= 16 * 1_024 * 1_024 else { throw ProfileCacheError.unsafeEntry }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ProfileCacheError.changed }
            offset += count
        }
        var after = stat(), entry = stat()
        guard fstat(descriptor, &after) == 0, fstatat(parent, url.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              CacheIdentity(before) == CacheIdentity(after), CacheIdentity(after) == CacheIdentity(entry) else { throw ProfileCacheError.changed }
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { throw ProfileCacheError.unsupportedLocation }
        if object["browser.disk_cache_dir"] != nil || (object["browser"] as? [String: Any])?["disk_cache_dir"] != nil {
            throw ProfileCacheError.unsupportedLocation
        }
    }
}

private struct CacheRootIdentity: Codable, Equatable {
    let device: Int64, inode: UInt64, uid: UInt32
    init(device: Int64, inode: UInt64, uid: UInt32) { self.device = device; self.inode = inode; self.uid = uid }
    init(_ value: stat) { device = Int64(value.st_dev); inode = UInt64(value.st_ino); uid = UInt32(value.st_uid) }
    static func observe(parent: Int32, name: String) throws -> Self? {
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw currentPOSIXError()
        }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), value.st_uid == geteuid() else { throw ProfileCacheError.rollbackRequired }
        return Self(value)
    }
    static func descriptor(_ descriptor: Int32) throws -> Self {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), value.st_uid == geteuid() else { throw ProfileCacheError.rollbackRequired }
        return Self(value)
    }
    static func directory(_ url: URL) throws -> Self {
        let fd = try openDirectory(url, allowMissing: false)
        defer { _ = Darwin.close(fd) }
        return try descriptor(fd)
    }
}

private struct CacheRecoveryManifest: Codable {
    struct Root: Codable {
        let original: String, stage: String
        let identity: CacheRootIdentity
    }
    let schema: Int
    let operation: UUID
    let parent: CacheRootIdentity
    let browserData: CacheRootIdentity
    let browserPathDigest: String
    let roots: [Root]
}

/// Durable intent precedes every rename. A one-byte phase update is fsynced
/// before the first unlink, so recovery distinguishes untouched and removed
/// roots without inferring ownership from a filename prefix.
private final class CacheJournal {
    static let fileName = ".neantik-cache-maintenance.json"
    let manifest: CacheRecoveryManifest
    let descriptor: Int32
    private(set) var removing: Bool
    private var closed = false
    private var expectedIdentity: CacheIdentity?
    private var expectedContent: Data
    private init(manifest: CacheRecoveryManifest, descriptor: Int32, removing: Bool, content: Data) {
        self.manifest = manifest; self.descriptor = descriptor; self.removing = removing; self.expectedContent = content
    }
    func close() { if !closed { closed = true; _ = Darwin.close(descriptor) } }
    deinit { close() }
    static func pathDigest(_ url: URL) -> String { SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func create(parent: Int32, browserData: URL, roots: [CacheNode]) throws -> CacheJournal {
        let operation = UUID()
        let manifest = CacheRecoveryManifest(schema: 1, operation: operation,
            parent: try CacheRootIdentity.descriptor(parent), browserData: try CacheRootIdentity.directory(browserData), browserPathDigest: pathDigest(browserData),
            roots: roots.enumerated().map { index, root in
                .init(original: root.name, stage: ".neantik-cache-clearing-" + operation.uuidString + "-" + String(index),
                      identity: .init(device: Int64(root.identity.device), inode: UInt64(root.identity.inode), uid: UInt32(root.identity.uid)))
            })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = Data("NCACHE1\n0\n".utf8); bytes.append(try encoder.encode(manifest))
        guard bytes.count <= 16_384 else { throw ProfileCacheError.limitExceeded }
        let fd = openat(parent, fileName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProfileCacheError.rollbackRequired }
        let journal = CacheJournal(manifest: manifest, descriptor: fd, removing: false, content: bytes)
        do {
            var offset = 0
            while offset < bytes.count {
                let size = bytes.count - offset
                let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress!.advanced(by: offset), size, off_t(offset)) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw currentPOSIXError() }; offset += written
            }
            guard fsync(fd) == 0, fsync(parent) == 0 else { throw currentPOSIXError() }
            try journal.validateEntry(parent: parent)
            return journal
        } catch {
            // No roots have been moved. Retain an unreadable/torn journal for
            // inspection rather than unlinking a possibly replaced entry.
            journal.close(); throw error
        }
    }

    static func read(parent: Int32, browserData: URL) throws -> CacheJournal {
        let fd = openat(parent, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ProfileCacheError.rollbackRequired }
        var transferred = false
        do {
            var before = stat(), entry = stat()
            guard fstat(fd, &before) == 0, fstatat(parent, fileName, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  CacheIdentity(before) == CacheIdentity(entry), before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_uid == geteuid(), before.st_nlink == 1,
                  before.st_mode & 0o077 == 0, before.st_size >= 10, before.st_size <= 16_384 else { throw ProfileCacheError.rollbackRequired }
            var bytes = [UInt8](repeating: 0, count: Int(before.st_size)), offset = 0
            while offset < bytes.count {
                let size = bytes.count - offset
                let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset), size, off_t(offset)) }
                if count < 0, errno == EINTR { continue }; guard count > 0 else { throw ProfileCacheError.rollbackRequired }; offset += count
            }
            var after = stat()
            guard fstat(fd, &after) == 0, CacheIdentity(before) == CacheIdentity(after),
                  Data(bytes.prefix(8)) == Data("NCACHE1\n".utf8), (bytes[8] == 48 || bytes[8] == 49), bytes[9] == 10,
                  let manifest = try? JSONDecoder().decode(CacheRecoveryManifest.self, from: Data(bytes.dropFirst(10))), manifest.schema == 1,
                  manifest.parent == (try CacheRootIdentity.descriptor(parent)), manifest.browserData == (try CacheRootIdentity.directory(browserData)), manifest.browserPathDigest == pathDigest(browserData),
                  (1...2).contains(manifest.roots.count), Set(manifest.roots.map(\.original)).count == manifest.roots.count else { throw ProfileCacheError.rollbackRequired }
            for (index, root) in manifest.roots.enumerated() {
                guard ["Cache", "Code Cache"].contains(root.original), root.stage == ".neantik-cache-clearing-" + manifest.operation.uuidString + "-" + String(index), root.identity.device == manifest.parent.device, root.identity.uid == manifest.parent.uid else { throw ProfileCacheError.rollbackRequired }
            }
            let journal = CacheJournal(manifest: manifest, descriptor: fd, removing: bytes[8] == 49, content: Data(bytes))
            transferred = true
            try journal.validateEntry(parent: parent)
            return journal
        } catch { if !transferred { _ = Darwin.close(fd) }; throw error }
    }

    func validateEntry(parent: Int32) throws {
        var held = stat(), entry = stat()
        guard fstat(descriptor, &held) == 0, fstatat(parent, Self.fileName, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              (expectedIdentity == nil || CacheIdentity(held) == expectedIdentity), CacheIdentity(held) == CacheIdentity(entry), held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_nlink == 1, held.st_uid == geteuid(), held.st_mode & 0o077 == 0 else { throw ProfileCacheError.rollbackRequired }
        guard held.st_size == expectedContent.count, expectedContent.count <= 16_384 else { throw ProfileCacheError.rollbackRequired }
        var bytes = [UInt8](repeating: 0, count: expectedContent.count), offset = 0
        while offset < bytes.count {
            let size = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!.advanced(by: offset), size, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ProfileCacheError.rollbackRequired }; offset += count
        }
        var after = stat(), currentEntry = stat()
        guard Data(bytes) == expectedContent, fstat(descriptor, &after) == 0, fstatat(parent, Self.fileName, &currentEntry, AT_SYMLINK_NOFOLLOW) == 0,
              CacheIdentity(held) == CacheIdentity(after), CacheIdentity(after) == CacheIdentity(currentEntry) else { throw ProfileCacheError.rollbackRequired }
        if expectedIdentity == nil { expectedIdentity = CacheIdentity(held) }
    }
    func validateLocation(parent: Int32, browserData: URL, cacheParent: URL) throws {
        guard try CacheRootIdentity.descriptor(parent) == manifest.parent,
              try CacheRootIdentity.directory(cacheParent) == manifest.parent,
              try CacheRootIdentity.directory(browserData) == manifest.browserData,
              Self.pathDigest(browserData) == manifest.browserPathDigest else { throw ProfileCacheError.rollbackRequired }
    }
    func markRemoving(parent: Int32) throws {
        try validateEntry(parent: parent)
        guard fsync(parent) == 0 else { throw currentPOSIXError() }
        var phase: UInt8 = 49
        guard pwrite(descriptor, &phase, 1, 8) == 1, fsync(descriptor) == 0 else { throw currentPOSIXError() }
        removing = true
        expectedContent[8] = phase
        var updated = stat()
        guard fstat(descriptor, &updated) == 0 else { throw currentPOSIXError() }
        expectedIdentity = CacheIdentity(updated)
        try validateEntry(parent: parent)
    }
    func remove(parent: Int32) throws {
        try validateEntry(parent: parent)
        guard unlinkat(parent, Self.fileName, 0) == 0, fsync(parent) == 0 else { throw currentPOSIXError() }
    }
}

private struct CacheBudget {
    let maximumEntries: Int
    let maximumBytes: Int64
    var bytes: Int64 = 0, files = 0, directories = 0
    mutating func consume(size: Int64, directory: Bool) throws {
        guard size >= 0, files + directories < maximumEntries, bytes <= maximumBytes, size <= maximumBytes - bytes else { throw ProfileCacheError.limitExceeded }
        bytes += size
        if directory { directories += 1 } else { files += 1 }
    }
}

private struct CacheIdentity: Equatable {
    let device: dev_t, inode: ino_t, mode: mode_t, uid: uid_t, links: nlink_t, size: off_t
    let modifiedSeconds: Int, modifiedNanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; uid = value.st_uid; links = value.st_nlink; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
    }
}

private struct CacheScan {
    let parent: Int32
    let roots: [CacheNode]
    let estimate: ProfileCacheEstimate
    func close() { if parent >= 0 { _ = Darwin.close(parent) } }
}

private struct CacheNode {
    let name: String
    let identity: CacheIdentity
    let children: [CacheNode]
    var isDirectory: Bool { identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    static func capture(parent: Int32, name: String, depth: Int, device: dev_t, budget: inout CacheBudget) throws -> CacheNode? {
        try Task.checkCancellation()
        guard depth <= 32 else { throw ProfileCacheError.limitExceeded }
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw currentPOSIXError()
        }
        let kind = value.st_mode & mode_t(S_IFMT)
        guard value.st_uid == geteuid(), value.st_dev == device,
              kind == mode_t(S_IFDIR) || (kind == mode_t(S_IFREG) && value.st_nlink == 1) else { throw ProfileCacheError.unsafeEntry }
        let before = CacheIdentity(value)
        let directory = kind == mode_t(S_IFDIR)
        try budget.consume(size: directory ? 0 : Int64(value.st_size), directory: directory)
        var children: [CacheNode] = []
        if directory {
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ProfileCacheError.unsafeEntry }
            defer { _ = Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, CacheIdentity(opened) == before else { throw ProfileCacheError.changed }
            for child in try names(in: descriptor) {
                guard let node = try capture(parent: descriptor, name: child, depth: depth + 1, device: device, budget: &budget) else { throw ProfileCacheError.changed }
                children.append(node)
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, CacheIdentity(after) == before else { throw ProfileCacheError.changed }
        }
        var after = stat()
        guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0, CacheIdentity(after) == before else { throw ProfileCacheError.changed }
        return .init(name: name, identity: before, children: children)
    }

    func validate(parent: Int32, name: String) throws {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0, CacheIdentity(value) == identity else { throw ProfileCacheError.changed }
        if isDirectory {
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ProfileCacheError.changed }
            defer { _ = Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, CacheIdentity(opened) == identity,
                  Set(try names(in: descriptor)) == Set(children.map(\.name)) else { throw ProfileCacheError.changed }
            for child in children { try child.validate(parent: descriptor, name: child.name) }
        }
    }

    func remove(parent: Int32, name: String) throws {
        try validate(parent: parent, name: name)
        if isDirectory {
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ProfileCacheError.changed }
            defer { _ = Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, CacheIdentity(opened) == identity else { throw ProfileCacheError.changed }
            for child in children { try child.remove(parent: descriptor, name: child.name) }
            var entry = stat()
            guard fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0, entry.st_dev == identity.device, entry.st_ino == identity.inode, entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ProfileCacheError.changed }
        }
        guard unlinkat(parent, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw currentPOSIXError() }
    }
}

private func names(in descriptor: Int32) throws -> [String] {
    let copy = dup(descriptor)
    guard copy >= 0 else { throw currentPOSIXError() }
    guard let directory = fdopendir(copy) else { _ = Darwin.close(copy); throw currentPOSIXError() }
    defer { closedir(directory) }
    rewinddir(directory)
    var result: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(directory) else {
            if errno != 0 { throw currentPOSIXError() }; break
        }
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
        }
        guard let name else { throw ProfileCacheError.unsafeEntry }
        if name == "." || name == ".." { continue }
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), PersistedInlineText.isSafe(name), result.count < 100_000 else { throw ProfileCacheError.unsafeEntry }
        result.append(name)
    }
    return result.sorted()
}

/// Anchor every ancestor with openat; never resolve a symlink and then mutate
/// its target. Missing paths are empty only when ENOENT is independently seen.
private func openDirectory(_ url: URL, allowMissing: Bool) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/") else { throw ProfileCacheError.unsafeEntry }
    var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw currentPOSIXError() }
    do {
        // Foundation standardization rewrites an existing /private/tmp path
        // to /tmp on macOS. /tmp is a symlink: preserve the supplied lexical
        // components and validate each via nofollow instead of resolving it.
        for part in url.pathComponents.dropFirst() {
            guard part != ".", part != "..", !part.contains("/"), !part.contains("\\") else { throw ProfileCacheError.unsafeEntry }
            let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT, allowMissing { _ = Darwin.close(descriptor); return -1 }
                throw ProfileCacheError.unsafeEntry
            }
            _ = Darwin.close(descriptor); descriptor = next
        }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == geteuid() else { throw ProfileCacheError.unsafeEntry }
        return descriptor
    } catch { _ = Darwin.close(descriptor); throw error }
}

private func currentPOSIXError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
