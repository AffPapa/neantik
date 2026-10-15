import CryptoKit
import Darwin
import Foundation
import WebKit

enum WebKitProfileDeletionError: LocalizedError, Equatable {
    case wrongEngine, unsafeJournal, changed, nativeFailed, identifierStillPresent, interrupted
    var errorDescription: String? {
        switch self {
        case .wrongEngine: "Эта операция предназначена для профиля WebKit."
        case .unsafeJournal: "Журнал удаления WebKit не прошёл проверку. Запуск профиля заблокирован; сохрани папку данных NeAntik и обратись в поддержку."
        case .changed: "Настройки или защита удаления изменились. Операция остановлена; данные WebKit уже могли быть удалены. Закрой другие экземпляры NeAntik и открой восстановление удаления."
        case .nativeFailed: "macOS не завершила удаление WebKit. Данные могли быть удалены частично; профиль скрыт и заблокирован. Закрой его окна и повтори удаление через восстановление."
        case .identifierStillPresent: "WebKit ещё сообщает об этом хранилище после удаления. Завершение не подтверждено; профиль остаётся заблокированным."
        case .interrupted: "Удаление данных WebKit подтверждено, но очистка профиля ещё не завершена. Открой восстановление удаления; возвращать пустой профиль в работу небезопасно."
        }
    }
}

/// One file is both write-ahead intent and the existing deletion fence. It is
/// never removed on an error or reused for another UUID. No URL, cookie, login
/// or website data is recorded. Process + WebKit metadata guards belong to caller.
struct WebKitProfileDeletionJournal: Sendable {
    enum Stage: String, Codable, Sendable { case prepared, dataRemoved, metadataRemoved }
    struct DirectoryPin: Codable, Equatable, Sendable {
        let parentDevice: Int64
        let parentInode: UInt64
        let device: Int64?
        let inode: UInt64?
    }
    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let kind: String
        let operationID: UUID
        let profileID: UUID
        let revision: UInt64
        let profileSHA256: String
        let rootDevice: Int64
        let rootInode: UInt64
        let locksDevice: Int64
        let locksInode: UInt64
        let profileDirectory: DirectoryPin
        var stage: Stage
    }
    let paths: AppPaths
    private static let maximumBytes = 4096

    static func profileDigest(_ profile: BrowserProfile) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return BackupFS.hex(SHA256.hash(data: try encoder.encode(profile)))
    }

    func load(for id: UUID) throws -> Record? {
        try withDirectory { _, directory, root, locks in
            guard let bytes = try read(directory, name(id)) else { return nil }
            let record: Record
            do { record = try JSONDecoder().decode(Record.self, from: bytes) }
            catch { throw WebKitProfileDeletionError.unsafeJournal }
            try validate(record, id: id, root: root, locks: locks)
            guard try encode(record) == bytes else { throw WebKitProfileDeletionError.unsafeJournal }
            return record
        }
    }

    func prepare(_ profile: BrowserProfile) throws -> Record {
        guard profile.engine == .webkit else { throw WebKitProfileDeletionError.wrongEngine }
        if let existing = try load(for: profile.id) {
            guard existing.revision == profile.revision,
                  existing.profileSHA256 == (try Self.profileDigest(profile)) else { throw WebKitProfileDeletionError.changed }
            return existing
        }
        return try withDirectory { rootFD, directory, root, locks in
            let pin = try withProfileDirectory(rootFD, id: profile.id) { parent, child in
                DirectoryPin(parentDevice: Int64(parent.device), parentInode: UInt64(parent.inode),
                    device: child.map { Int64($0.device) }, inode: child.map { UInt64($0.inode) })
            }
            let record = Record(schemaVersion: 1, kind: "neantik-webkit-deletion-v1", operationID: UUID(),
                profileID: profile.id, revision: profile.revision, profileSHA256: try Self.profileDigest(profile),
                rootDevice: Int64(root.device), rootInode: UInt64(root.inode),
                locksDevice: Int64(locks.device), locksInode: UInt64(locks.inode), profileDirectory: pin, stage: .prepared)
            try validate(record, id: profile.id, root: root, locks: locks)
            try publish(record, expected: nil, directory: directory)
            return record
        }
    }

    func advance(_ expected: Record, to stage: Stage) throws -> Record {
        guard (expected.stage == .prepared && stage == .dataRemoved)
                || (expected.stage == .dataRemoved && stage == .metadataRemoved) else {
            throw WebKitProfileDeletionError.changed
        }
        return try withDirectory { _, directory, root, locks in
            try validate(expected, id: expected.profileID, root: root, locks: locks)
            var next = expected; next.stage = stage
            try publish(next, expected: expected, directory: directory)
            return next
        }
    }

    /// Any incomplete intent needs explicit recovery, even when metadata was
    /// fenced before native dispatch. Absence of metadata never means success.
    /// Completed records remain permanent fences against UUID reuse.
    func pendingProfileIDs(includingCompletedProfiles knownIDs: Set<UUID> = []) throws -> [UUID] {
        try withDirectory { _, directory, _, _ in
            try BackupFS.names(directory).compactMap { filename in
                guard filename.hasSuffix(".deleted"),
                      let id = UUID(uuidString: String(filename.dropLast(8))), filename == name(id),
                      let bytes = try read(directory, filename), bytes.first == UInt8(ascii: "{") else { return nil }
                guard let record = try load(for: id) else { return nil }
                return record.stage == .metadataRemoved && !knownIDs.contains(id) ? nil : id
            }
        }
    }

    /// Pin the NeAntik-owned directory as well as the native UUID. A replacement
    /// must never be moved to Trash by a resumed operation. A missing original
    /// directory is accepted only after native completion (a previous Trash step).
    func validateProfileDirectory(_ record: Record) throws {
        try withDirectory { rootFD, _, root, locks in
            try validate(record, id: record.profileID, root: root, locks: locks)
            try withProfileDirectory(rootFD, id: record.profileID) { parent, child in
                let pin = record.profileDirectory
                guard pin.parentDevice == Int64(parent.device), pin.parentInode == UInt64(parent.inode) else {
                    throw WebKitProfileDeletionError.changed
                }
                if let child {
                    guard pin.device == Int64(child.device), pin.inode == UInt64(child.inode) else {
                        throw WebKitProfileDeletionError.changed
                    }
                } else if pin.inode != nil && record.stage == .prepared {
                    throw WebKitProfileDeletionError.changed
                }
            }
        }
    }

    /// Isolate the pinned object with renameat before touching contents. Finder
    /// Trash APIs accept mutable paths; even NSURL reference bridging retargeted
    /// a replacement in a real filesystem control. Never recursively remove
    /// local files: only known empty scaffolding is disposable here.
    /// Returns true when unexpected local contents were retained privately.
    func retireProfileDirectory(_ record: Record, beforeMove: () throws -> Void = {}) throws -> Bool {
        guard record.stage != .prepared else { throw WebKitProfileDeletionError.changed }
        try validateProfileDirectory(record)
        return try withDirectory { root, _, _, _ in
            let parent = openat(root, "Profiles", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw WebKitProfileDeletionError.changed }
            defer { Darwin.close(parent) }
            let parentIdentity = try BackupFS.identity(parent), pin = record.profileDirectory
            guard Int64(parentIdentity.device) == pin.parentDevice, UInt64(parentIdentity.inode) == pin.parentInode else {
                throw WebKitProfileDeletionError.changed
            }
            let source = record.profileID.uuidString, staged = ".webkit-deleted-" + record.operationID.uuidString
            func matches(_ value: BackupIdentity) -> Bool {
                value.directory && value.uid == geteuid() && value.mode & 0o077 == 0 &&
                    pin.device == Int64(value.device) && pin.inode == UInt64(value.inode)
            }
            func validateParent() throws {
                guard try BackupFS.entry(root, "Profiles")?.sameObject(parentIdentity) == true else {
                    throw WebKitProfileDeletionError.changed
                }
            }
            if let current = try BackupFS.entry(parent, source) {
                guard matches(current), try BackupFS.entry(parent, staged) == nil else { throw WebKitProfileDeletionError.changed }
                try beforeMove() // Fault seam; not called by the production path.
                try validateParent()
                guard renameatx_np(parent, source, parent, staged, UInt32(RENAME_EXCL)) == 0 else { throw BackupFS.posix() }
                guard fsync(parent) == 0 else { throw BackupFS.posix() }
                guard let moved = try BackupFS.entry(parent, staged), matches(moved) else {
                    // A replacement arrived before rename. Restore it only to
                    // an unoccupied source name; never delete or overwrite it.
                    _ = renameatx_np(parent, staged, parent, source, UInt32(RENAME_EXCL))
                    _ = fsync(parent)
                    throw WebKitProfileDeletionError.changed
                }
            }
            guard let stagedIdentity = try BackupFS.entry(parent, staged) else { return false }
            guard matches(stagedIdentity) else { throw WebKitProfileDeletionError.changed }
            let fd = openat(parent, staged, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw WebKitProfileDeletionError.changed }
            defer { Darwin.close(fd) }
            guard try BackupFS.identity(fd).sameObject(stagedIdentity) else { throw WebKitProfileDeletionError.changed }
            try validateParent()
            let names = try BackupFS.names(fd)
            if names == ["BrowserData"] {
                let browser = openat(fd, "BrowserData", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard browser >= 0 else { return true } // Preserve unexpected links/types.
                defer { Darwin.close(browser) }
                let child = try BackupFS.identity(browser)
                guard child.directory, child.uid == geteuid(), child.mode & 0o077 == 0,
                      try BackupFS.names(browser).isEmpty,
                      try BackupFS.entry(fd, "BrowserData")?.sameObject(child) == true else { return true }
                // rmdir refuses nonempty replacements. No recursive deletion.
                guard unlinkat(fd, "BrowserData", AT_REMOVEDIR) == 0 else { return true }
                guard fsync(fd) == 0 else { throw BackupFS.posix() }
            } else if !names.isEmpty { return true }
            try validateParent()
            guard try BackupFS.entry(parent, staged)?.sameObject(stagedIdentity) == true else { throw WebKitProfileDeletionError.changed }
            guard unlinkat(parent, staged, AT_REMOVEDIR) == 0 else { return true }
            guard fsync(parent) == 0 else { throw BackupFS.posix() }
            return false
        }
    }

    private func withProfileDirectory<T>(_ root: Int32, id: UUID,
        _ body: (BackupIdentity, BackupIdentity?) throws -> T) throws -> T {
        let fd = openat(root, "Profiles", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WebKitProfileDeletionError.changed }
        defer { Darwin.close(fd) }
        let parent = try BackupFS.identity(fd), child = try BackupFS.entry(fd, id.uuidString)
        guard parent.directory, parent.uid == geteuid(), parent.mode & 0o077 == 0 else {
            throw WebKitProfileDeletionError.unsafeJournal
        }
        if let child {
            guard child.directory, child.uid == geteuid(), child.mode & 0o077 == 0 else {
                throw WebKitProfileDeletionError.unsafeJournal
            }
        }
        let result = try body(parent, child)
        let current = try BackupFS.entry(fd, id.uuidString)
        let sameChild = child.map { previous in current?.sameObject(previous) == true } ?? (current == nil)
        guard try BackupFS.entry(root, "Profiles")?.sameObject(parent) == true, sameChild else {
            throw WebKitProfileDeletionError.changed
        }
        return result
    }

    /// Persist both metadata snapshots before recording completion. A crash
    /// may leave either old snapshot, but the .deleted fence always survives.
    func synchronizeMetadataFiles() throws {
        let root = try BackupFS.directory(canonicalRoot)
        defer { Darwin.close(root) }
        for filename in [paths.profilesFile.lastPathComponent, paths.profilesBackupFile.lastPathComponent] {
            guard let named = try BackupFS.entry(root, filename) else { throw WebKitProfileDeletionError.changed }
            try named.validateFile(device: nil)
            guard named.mode & 0o077 == 0 else { throw WebKitProfileDeletionError.unsafeJournal }
            let fd = openat(root, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw BackupFS.posix() }
            defer { Darwin.close(fd) }
            guard try BackupFS.identity(fd) == named, fsync(fd) == 0,
                  try BackupFS.entry(root, filename) == named else { throw WebKitProfileDeletionError.changed }
        }
        guard fsync(root) == 0 else { throw BackupFS.posix() }
    }

    private func name(_ id: UUID) -> String { id.uuidString + ".deleted" }
    private var canonicalRoot: URL {
        let path = paths.rootDirectory.path
        return URL(fileURLWithPath: path.hasPrefix("/tmp/") || path.hasPrefix("/var/") ? "/private" + path : path)
    }
    private func encode(_ value: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func validate(_ value: Record, id: UUID, root: BackupIdentity, locks: BackupIdentity) throws {
        guard value.schemaVersion == 1, value.kind == "neantik-webkit-deletion-v1", value.profileID == id,
              id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              value.operationID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              value.profileSHA256.count == 64, value.profileSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              value.rootDevice == Int64(root.device), value.rootInode == UInt64(root.inode),
              value.locksDevice == Int64(locks.device), value.locksInode == UInt64(locks.inode),
              (value.profileDirectory.device == nil) == (value.profileDirectory.inode == nil),
              value.profileDirectory.parentInode != 0 else {
            throw WebKitProfileDeletionError.unsafeJournal
        }
    }
    private func read(_ directory: Int32, _ filename: String) throws -> Data? {
        guard let named = try BackupFS.entry(directory, filename) else { return nil }
        try named.validateFile(device: nil)
        guard named.mode & 0o077 == 0, (1...Int64(Self.maximumBytes)).contains(named.size) else { throw WebKitProfileDeletionError.unsafeJournal }
        let fd = openat(directory, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(fd) }
        guard try BackupFS.identity(fd) == named else { throw WebKitProfileDeletionError.changed }
        let bytes = try BackupFS.read(fd, at: 0, count: Int(named.size), checksCancellation: false)
        guard bytes.count == Int(named.size), try BackupFS.identity(fd) == named,
              try BackupFS.entry(directory, filename) == named else { throw WebKitProfileDeletionError.changed }
        return bytes
    }
    private func publish(_ next: Record, expected: Record?, directory: Int32) throws {
        let filename = name(next.profileID), old = try read(directory, filename)
        guard old == (try expected.map(encode)) else { throw WebKitProfileDeletionError.changed }
        let previous = try BackupFS.entry(directory, filename)
        let temporary = ".\(UUID().uuidString).webkit-deletion-tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BackupFS.posix() }
        let own = try BackupFS.identity(fd)
        var published = false
        defer {
            if !published, (try? BackupFS.entry(directory, temporary)?.sameObject(own)) == true { _ = unlinkat(directory, temporary, 0) }
            Darwin.close(fd)
        }
        let bytes = try encode(next)
        guard bytes.count <= Self.maximumBytes else { throw WebKitProfileDeletionError.unsafeJournal }
        try BackupFS.write(fd, bytes, at: 0, checksCancellation: false)
        guard fsync(fd) == 0, try BackupFS.entry(directory, filename) == previous,
              try read(directory, filename) == old,
              try BackupFS.entry(directory, temporary)?.sameObject(own) == true else { throw WebKitProfileDeletionError.changed }
        guard renameatx_np(directory, temporary, directory, filename, expected == nil ? UInt32(RENAME_EXCL) : 0) == 0 else { throw BackupFS.posix() }
        published = true
        guard fsync(directory) == 0, try read(directory, filename) == bytes else { throw WebKitProfileDeletionError.changed }
    }
    private func withDirectory<T>(_ body: (Int32, Int32, BackupIdentity, BackupIdentity) throws -> T) throws -> T {
        let root = try BackupFS.directory(canonicalRoot)
        defer { Darwin.close(root) }
        let rootIdentity = try BackupFS.identity(root)
        guard rootIdentity.mode & 0o077 == 0 else { throw WebKitProfileDeletionError.unsafeJournal }
        let directory = openat(root, "ProcessLocks", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw WebKitProfileDeletionError.unsafeJournal }
        defer { Darwin.close(directory) }
        let locks = try BackupFS.identity(directory)
        guard locks.directory, locks.uid == geteuid(), locks.mode & 0o077 == 0 else { throw WebKitProfileDeletionError.unsafeJournal }
        func validateNames() throws {
            try BackupFS.validateDirectoryPath(canonicalRoot, rootIdentity)
            guard try BackupFS.entry(root, "ProcessLocks")?.sameObject(locks) == true,
                  try BackupFS.identity(directory).sameObject(locks) else { throw WebKitProfileDeletionError.changed }
        }
        try validateNames()
        let result = try body(root, directory, rootIdentity, locks)
        try validateNames()
        return result
    }
}

@MainActor enum WebKitDataStoreRemoval {
    static func remove(profileID: UUID) async throws {
        guard profileID != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else { throw WebKitProfileDeletionError.unsafeJournal }
        // Initialize WebKit without opening the default or target persistent
        // store. Fresh-process removal otherwise crashes on the tested SDK.
        let initialization = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(initialization) {} }
        let before = await identifiers()
        if !before.contains(profileID) { return } // Also recovers a crash after native removal.
        let error: Error? = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.remove(forIdentifier: profileID) { continuation.resume(returning: $0) }
        }
        guard error == nil else { throw WebKitProfileDeletionError.nativeFailed }
        guard !(await identifiers()).contains(profileID) else { throw WebKitProfileDeletionError.identifierStillPresent }
    }
    private static func identifiers() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
        }
    }
}
