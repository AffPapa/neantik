import CryptoKit
import Darwin
import Foundation

enum BrowserDataBackupStorageError: Error, Equatable {
    case unsafeEntry, changed, limitExceeded, incompatibleContext, destinationInsideSource
}
enum BrowserDataBackupStoragePoint { case scanned, outputIdentity(Int32), restoreRootIdentity(Int32), frameWritten(Int), beforePublish, restoreBegan, restoredChunk(Int), restoreVerified }

/// Storage worker only. The manager must retain verified stopped-profile
/// authority for export and later restore publication. A prepared stage is
/// NOT a restored live profile; metadata+BrowserData commit needs its journal.
enum BrowserDataBackupStorage {
    typealias Archive = EncryptedBackupArchive
    static let maximumArchiveBytes: Int64 = Int64(Archive.maximumFileBytes) + 32 * 1_024 * 1_024

    static func export(browserData: URL, context: Archive.Manifest, destination: URL, password: String,
                       fault: ((BrowserDataBackupStoragePoint) throws -> Void)? = nil) throws -> Archive.Manifest {
        let source = try BackupTree.capture(browserData)
        defer { source.close() }
        try fault?(.scanned)
        var manifest = context
        manifest = .init(schema: context.schema, profileID: context.profileID, identitySHA256: context.identitySHA256,
                         runtimeExecutableSHA256: context.runtimeExecutableSHA256, runtimeFrameworkSHA256: context.runtimeFrameworkSHA256,
                         runtimeVersion: context.runtimeVersion, compatibilityScopeSHA256: context.compatibilityScopeSHA256, entries: source.entries)
        try Archive.validate(manifest)
        guard !destination.pathComponents.starts(with: browserData.pathComponents) else { throw BrowserDataBackupStorageError.destinationInsideSource }
        let parentURL = destination.deletingLastPathComponent()
        let parent = try BackupFS.directory(parentURL)
        defer { Darwin.close(parent) }
        let parentIdentity = try BackupFS.identity(parent)
        let name = destination.lastPathComponent
        try BackupFS.validateName(name)
        guard try BackupFS.entry(parent, name) == nil else { throw BrowserDataBackupStorageError.unsafeEntry }
        let pending = ".neantik-backup-\(UUID().uuidString.lowercased()).partial"
        let output = openat(parent, pending, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(output) }
        try fault?(.outputIdentity(output))
        let outputIdentity = try BackupFS.identity(output)
        var published = false
        defer {
            if !published, let current = try? BackupFS.entry(parent, pending), current.sameObject(outputIdentity) {
                _ = unlinkat(parent, pending, 0)
            }
        }
        var written: Int64 = 0, frame = 0
        var expectedHash = SHA256()
        try Archive.encode(manifest: manifest, password: password, readFile: { index, offset, count in
            try source.read(index: index, offset: offset, count: count)
        }, write: { bytes in
            try Task.checkCancellation()
            guard written <= maximumArchiveBytes - Int64(bytes.count) else { throw BrowserDataBackupStorageError.limitExceeded }
            try BackupFS.write(output, bytes, at: written)
            written += Int64(bytes.count); expectedHash.update(data: bytes)
            try fault?(.frameWritten(frame)); frame += 1
        })
        guard fsync(output) == 0 else { throw BackupFS.posix() }
        let finalOutput = try BackupFS.identity(output)
        guard finalOutput.size == written,
              try BackupFS.hash(output, size: written) == BackupFS.hex(expectedHash.finalize()),
              try BackupFS.identity(output) == finalOutput,
              try BackupFS.entry(parent, pending) == finalOutput else { throw BrowserDataBackupStorageError.changed }
        try source.validateAll()
        try fault?(.beforePublish)
        try Task.checkCancellation()
        try source.validateAll()
        try BackupFS.validateDirectoryPath(parentURL, parentIdentity)
        guard try BackupFS.identity(output) == finalOutput, try BackupFS.entry(parent, pending) == finalOutput else { throw BrowserDataBackupStorageError.changed }
        guard renameatx_np(parent, pending, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw BackupFS.posix() }
        published = true
        guard fsync(parent) == 0 else { throw BackupFS.posix() }
        return manifest
    }

    /// Only returns after AEAD/footer/EOF and all reconstructed file hashes.
    /// Caller must either pass this owned stage to a journaled commit or
    /// explicitly discard it. This operation never replaces live BrowserData.
    static func prepareRestore(archive: URL, parentURL: URL, expectedContext: Archive.Manifest, password: String,
                               stageName: String? = nil,
                               fault: ((BrowserDataBackupStoragePoint) throws -> Void)? = nil) throws -> PreparedBrowserDataBackup {
        let archiveParent = try BackupFS.directory(archive.deletingLastPathComponent())
        defer { Darwin.close(archiveParent) }
        let input = openat(archiveParent, archive.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(input) }
        let inputIdentity = try BackupFS.identity(input)
        try inputIdentity.validateFile(device: nil)
        guard inputIdentity.size <= maximumArchiveBytes else { throw BrowserDataBackupStorageError.limitExceeded }
        let stage = try PreparedBrowserDataBackup(parentURL: parentURL, requestedName: stageName, fault: fault)
        var position: Int64 = 0
        do {
            let manifest = try Archive.decode(password: password, read: { maximum in
                try Task.checkCancellation()
                let count = Int(min(Int64(maximum), inputIdentity.size - position))
                guard count > 0 else { return Data() }
                let bytes = try BackupFS.read(input, at: position, count: count)
                position += Int64(bytes.count)
                return bytes
            }, begin: { manifest in
                guard compatible(manifest, expectedContext) else { throw BrowserDataBackupStorageError.incompatibleContext }
                try stage.createEntries(manifest.entries)
                try fault?(.restoreBegan)
            }, writeFile: { index, offset, data in
                try stage.write(index, offset: offset, data: data)
                try fault?(.restoredChunk(index))
            })
            guard try BackupFS.identity(input) == inputIdentity,
                  try BackupFS.entry(archiveParent, archive.lastPathComponent) == inputIdentity else { throw BrowserDataBackupStorageError.changed }
            try stage.finish(manifest)
            try fault?(.restoreVerified)
            try stage.validatePreparedContents()
            try Task.checkCancellation()
            return stage
        } catch {
            // Never delete a substituted inode. A cleanup refusal preserves
            // the private stage and surfaces separately from authentication.
            do { try stage.discard() } catch { throw BrowserDataBackupStorageError.changed }
            throw error
        }
    }

    private static func compatible(_ left: Archive.Manifest, _ right: Archive.Manifest) -> Bool {
        left.schema == right.schema && left.profileID == right.profileID && left.identitySHA256 == right.identitySHA256 &&
        left.runtimeExecutableSHA256 == right.runtimeExecutableSHA256 && left.runtimeFrameworkSHA256 == right.runtimeFrameworkSHA256 &&
        left.runtimeVersion == right.runtimeVersion && left.compatibilityScopeSHA256 == right.compatibilityScopeSHA256
    }
}

final class PreparedBrowserDataBackup {
    let url: URL
    private let parent: Int32, root: Int32
    private let name: String
    private let parentIdentity: BackupIdentity, rootIdentity: BackupIdentity
    private var entries: [EncryptedBackupArchive.Entry] = []
    private var identities: [String: BackupIdentity] = [:]
    private(set) var manifest: EncryptedBackupArchive.Manifest?
    private var discarded = false

    fileprivate init(parentURL: URL, requestedName: String?, fault: ((BrowserDataBackupStoragePoint) throws -> Void)?) throws {
        parent = try BackupFS.directory(parentURL)
        var openedRoot: Int32 = -1
        var transferred = false
        defer { if !transferred, openedRoot >= 0 { Darwin.close(openedRoot) } }
        do {
            parentIdentity = try BackupFS.identity(parent)
            if let requestedName {
                let prefix = ".neantik-backup-restore-"
                guard requestedName.hasPrefix(prefix), let id = UUID(uuidString: String(requestedName.dropFirst(prefix.count))),
                      requestedName == prefix + id.uuidString.lowercased() else { throw BrowserDataBackupStorageError.unsafeEntry }
                name = requestedName
            } else { name = ".neantik-backup-restore-\(UUID().uuidString.lowercased())" }
            url = parentURL.appendingPathComponent(name, isDirectory: true)
            guard mkdirat(parent, name, 0o700) == 0 else { throw BackupFS.posix() }
            openedRoot = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard openedRoot >= 0 else { throw BackupFS.posix() }
            try fault?(.restoreRootIdentity(openedRoot))
            rootIdentity = try BackupFS.identity(openedRoot)
            root = openedRoot
            transferred = true
        } catch { Darwin.close(parent); throw error }
    }
    deinit { Darwin.close(root); Darwin.close(parent) }

    fileprivate func createEntries(_ entries: [EncryptedBackupArchive.Entry]) throws {
        self.entries = entries
        for entry in entries {
            try Task.checkCancellation()
            let directory = try ownedParent(entry.path)
            defer { Darwin.close(directory) }
            let name = entry.path.split(separator: "/").last!.description
            if entry.kind == .directory {
                guard mkdirat(directory, name, 0o700) == 0 else { throw BackupFS.posix() }
            } else {
                let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard file >= 0 else { throw BackupFS.posix() }
                Darwin.close(file)
            }
            identities[entry.path] = try BackupFS.entry(directory, name)
        }
    }
    fileprivate func write(_ index: Int, offset: UInt64, data: Data) throws {
        let entry = entries[index]
        let parent = try ownedParent(entry.path)
        defer { Darwin.close(parent) }
        let name = entry.path.split(separator: "/").last!.description
        let file = openat(parent, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(file) }
        let before = try BackupFS.identity(file)
        try before.validateFile(device: rootIdentity.device)
        guard let created = identities[entry.path], before.sameObject(created), before.size == Int64(offset),
              try BackupFS.entry(parent, name) == before else { throw BrowserDataBackupStorageError.changed }
        try BackupFS.write(file, data, at: Int64(offset))
        guard fsync(file) == 0 else { throw BackupFS.posix() }
        let after = try BackupFS.identity(file)
        guard after.sameObject(created), after.size == Int64(offset) + Int64(data.count),
              try BackupFS.entry(parent, name) == after else { throw BrowserDataBackupStorageError.changed }
    }
    fileprivate func finish(_ manifest: EncryptedBackupArchive.Manifest) throws {
        try validateRoot()
        let captured = try BackupTree.capture(url, excludeRootTransients: false)
        defer { captured.close() }
        guard captured.rootIdentity.sameObject(rootIdentity), captured.entries == manifest.entries else { throw BrowserDataBackupStorageError.changed }
        try validateCreatedContents(captured)
        try captured.validateAll()
        // Persist every directory, including empty ones, before handing the
        // stage to the future journaled publication transaction.
        for entry in entries.reversed() where entry.kind == .directory {
            let descriptor = try BackupFS.relativeDirectory(root, entry.path)
            defer { Darwin.close(descriptor) }
            guard fsync(descriptor) == 0 else { throw BackupFS.posix() }
        }
        guard fsync(root) == 0, fsync(parent) == 0 else { throw BackupFS.posix() }
        self.manifest = manifest
    }
    func validateRoot() throws {
        guard !discarded, try BackupFS.entry(parent, name)?.sameObject(rootIdentity) == true else { throw BrowserDataBackupStorageError.changed }
        try BackupFS.validateDirectoryPath(url.deletingLastPathComponent(), parentIdentity)
    }
    func validatePreparedContents(afterRootValidation: (() throws -> Void)? = nil) throws {
        try Task.checkCancellation()
        try validateRoot()
        guard let manifest else { throw BrowserDataBackupStorageError.changed }
        try afterRootValidation?()
        let captured = try BackupTree.capture(url, excludeRootTransients: false)
        defer { captured.close() }
        guard captured.rootIdentity.sameObject(rootIdentity), captured.entries == manifest.entries else { throw BrowserDataBackupStorageError.changed }
        try validateCreatedContents(captured)
        try captured.validateAll()
    }
    func discard() throws {
        if discarded { return }
        try validateRoot()
        let captured = try BackupTree.capture(url, checksCancellation: false, includeHashes: false, excludeRootTransients: false)
        defer { captured.close() }
        guard captured.rootIdentity.sameObject(rootIdentity) else { throw BrowserDataBackupStorageError.changed }
        try validateCreatedContents(captured)
        try captured.validateAll()
        try captured.removeContents()
        guard try BackupFS.entry(parent, name)?.sameObject(rootIdentity) == true,
              unlinkat(parent, name, AT_REMOVEDIR) == 0, fsync(parent) == 0 else { throw BrowserDataBackupStorageError.changed }
        discarded = true
    }

    /// Called only after a durable restore intent pins this stage's inode and
    /// contents. Its URL can then contain the old live tree after RENAME_SWAP;
    /// the preparer's cleanup must never interpret that tree as its own stage.
    func transferToRestoreJournal() {
        // The caller validated this stage and wrote its inode/content pins
        // before activating the intent. Ownership transfer itself must not
        // throw after activation, including on cancellation or fsync failure.
        discarded = true
    }

    private func validateCreatedContents(_ tree: BackupTree) throws {
        guard tree.entries.count == identities.count else { throw BrowserDataBackupStorageError.changed }
        for entry in tree.entries {
            guard let expected = identities[entry.path], tree.identities[entry.path]?.sameObject(expected) == true else {
                throw BrowserDataBackupStorageError.changed
            }
        }
    }
    private func ownedParent(_ path: String) throws -> Int32 {
        try validateRoot()
        var fd = dup(root); guard fd >= 0 else { throw BackupFS.posix() }
        do {
            var prefix = ""
            for part in path.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? part.description : prefix + "/" + part
                let next = openat(fd, part.description, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw BrowserDataBackupStorageError.changed }
                do {
                    guard let expected = identities[prefix], try BackupFS.identity(next).sameObject(expected) else { throw BrowserDataBackupStorageError.changed }
                } catch { Darwin.close(next); throw error }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
}

struct BackupIdentity: Equatable, Codable {
    let device: dev_t, inode: ino_t, uid: uid_t, mode: mode_t, links: nlink_t, size: Int64
    let mtimeSeconds: Int, mtimeNanos: Int, ctimeSeconds: Int, ctimeNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; uid = value.st_uid; mode = value.st_mode; links = value.st_nlink; size = value.st_size
        mtimeSeconds = value.st_mtimespec.tv_sec; mtimeNanos = value.st_mtimespec.tv_nsec
        ctimeSeconds = value.st_ctimespec.tv_sec; ctimeNanos = value.st_ctimespec.tv_nsec
    }
    var directory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode && uid == other.uid && (mode & mode_t(S_IFMT)) == (other.mode & mode_t(S_IFMT)) }
    func validateFile(device: dev_t?) throws {
        guard mode & mode_t(S_IFMT) == mode_t(S_IFREG), links == 1, uid == geteuid(), size >= 0,
              device == nil || self.device == device else { throw BrowserDataBackupStorageError.unsafeEntry }
    }
}

final class BackupTree {
    let url: URL, root: Int32, rootIdentity: BackupIdentity
    fileprivate var identities: [String: BackupIdentity] = [:]
    private(set) var entries: [EncryptedBackupArchive.Entry] = []
    private var bytes: UInt64 = 0, closed = false
    private let checksCancellation: Bool, includeHashes: Bool, excludeRootTransients: Bool
    private init(_ url: URL, checksCancellation: Bool, includeHashes: Bool, excludeRootTransients: Bool) throws {
        self.checksCancellation = checksCancellation; self.includeHashes = includeHashes; self.excludeRootTransients = excludeRootTransients
        self.url = url; root = try BackupFS.directory(url)
        do { rootIdentity = try BackupFS.identity(root) } catch { Darwin.close(root); throw error }
    }
    static func capture(_ url: URL, checksCancellation: Bool = true, includeHashes: Bool = true, excludeRootTransients: Bool = true) throws -> BackupTree {
        if checksCancellation { try Task.checkCancellation() }
        let result = try BackupTree(url, checksCancellation: checksCancellation, includeHashes: includeHashes, excludeRootTransients: excludeRootTransients)
        do { try result.scan(result.root, prefix: "", depth: 0); result.entries.sort { $0.path < $1.path }; try result.validateAll(); return result }
        catch { result.close(); throw error }
    }
    func close() { if !closed { closed = true; Darwin.close(root) } }
    deinit { close() }
    private func scan(_ directory: Int32, prefix: String, depth: Int) throws {
        if checksCancellation { try Task.checkCancellation() }
        guard depth <= 32 else { throw BrowserDataBackupStorageError.limitExceeded }
        let before = try BackupFS.identity(directory)
        for name in try BackupFS.names(directory) {
            if checksCancellation { try Task.checkCancellation() }
            guard entries.count < EncryptedBackupArchive.maximumEntries else { throw BrowserDataBackupStorageError.limitExceeded }
            // Explicit stopped-browser transient paths only, never generic
            // symlink adoption. They are not meaningful restored browser data.
            if excludeRootTransients, prefix.isEmpty, ["SingletonLock", "SingletonCookie", "SingletonSocket"].contains(name) { continue }
            guard name != ".neantik-cache-maintenance.json", !name.hasPrefix(".neantik-cache-clearing-") else { throw BrowserDataBackupStorageError.unsafeEntry }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            guard let observed = try BackupFS.entry(directory, name), observed.uid == geteuid(), observed.device == rootIdentity.device else { throw BrowserDataBackupStorageError.unsafeEntry }
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (observed.directory ? O_DIRECTORY : 0))
            guard descriptor >= 0 else { throw BrowserDataBackupStorageError.unsafeEntry }
            defer { Darwin.close(descriptor) }
            guard try BackupFS.identity(descriptor) == observed else { throw BrowserDataBackupStorageError.changed }
            identities[path] = observed
            if observed.directory {
                entries.append(.init(path: path, kind: .directory, size: 0, sha256: ""))
                try scan(descriptor, prefix: path, depth: depth + 1)
            } else {
                try observed.validateFile(device: rootIdentity.device)
                let addition = bytes.addingReportingOverflow(UInt64(observed.size))
                guard !addition.overflow, addition.partialValue <= EncryptedBackupArchive.maximumFileBytes else { throw BrowserDataBackupStorageError.limitExceeded }
                bytes = addition.partialValue
                entries.append(.init(path: path, kind: .file, size: UInt64(observed.size), sha256: includeHashes ? try BackupFS.hash(descriptor, size: observed.size, checksCancellation: checksCancellation) : ""))
            }
            guard try BackupFS.identity(descriptor) == observed, try BackupFS.entry(directory, name) == observed else { throw BrowserDataBackupStorageError.changed }
        }
        guard try BackupFS.identity(directory) == before else { throw BrowserDataBackupStorageError.changed }
    }
    func read(index: Int, offset: UInt64, count: Int) throws -> Data {
        let entry = entries[index]
        let parent = try checkedParent(entry.path)
        defer { Darwin.close(parent) }
        let name = entry.path.split(separator: "/").last!.description
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw BrowserDataBackupStorageError.unsafeEntry }
        defer { Darwin.close(file) }
        guard try BackupFS.identity(file) == identities[entry.path], try BackupFS.entry(parent, name) == identities[entry.path] else { throw BrowserDataBackupStorageError.changed }
        let data = try BackupFS.read(file, at: Int64(offset), count: count)
        guard data.count == count, try BackupFS.identity(file) == identities[entry.path], try BackupFS.entry(parent, name) == identities[entry.path] else { throw BrowserDataBackupStorageError.changed }
        return data
    }
    func validateAll() throws {
        if checksCancellation { try Task.checkCancellation() }
        guard try BackupFS.identity(root) == rootIdentity else { throw BrowserDataBackupStorageError.changed }
        try BackupFS.validateDirectoryPath(url, rootIdentity)
        for entry in entries {
            if checksCancellation { try Task.checkCancellation() }
            let parent = try checkedParent(entry.path); defer { Darwin.close(parent) }
            guard try BackupFS.entry(parent, entry.path.split(separator: "/").last!.description) == identities[entry.path] else { throw BrowserDataBackupStorageError.changed }
        }
    }
    private func checkedParent(_ path: String, stableObjectOnly: Bool = false) throws -> Int32 {
        var directory = dup(root)
        guard directory >= 0 else { throw BackupFS.posix() }
        do {
            var prefix = ""
            for part in path.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? part.description : prefix + "/" + part
                let next = openat(directory, part.description, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw BrowserDataBackupStorageError.changed }
                do {
                    let actual = try BackupFS.identity(next)
                    guard let expected = identities[prefix], stableObjectOnly ? actual.sameObject(expected) : actual == expected else { throw BrowserDataBackupStorageError.changed }
                } catch { Darwin.close(next); throw error }
                Darwin.close(directory); directory = next
            }
            return directory
        } catch { Darwin.close(directory); throw error }
    }
    func removeContents() throws {
        // Full validation precedes deletion; every unlink also checks the
        // captured inode. Removed children legitimately change parent times.
        for entry in entries.reversed() {
            let parent = try checkedParent(entry.path, stableObjectOnly: true); defer { Darwin.close(parent) }
            let name = entry.path.split(separator: "/").last!.description
            guard let expected = identities[entry.path], let actual = try BackupFS.entry(parent, name), actual.sameObject(expected) else { throw BrowserDataBackupStorageError.changed }
            guard unlinkat(parent, name, entry.kind == .directory ? AT_REMOVEDIR : 0) == 0 else { throw BackupFS.posix() }
        }
    }
}

enum BackupFS {
    static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    static func identity(_ fd: Int32) throws -> BackupIdentity {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw posix() }; return .init(value)
    }
    static func entry(_ parent: Int32, _ name: String) throws -> BackupIdentity? {
        var value = stat(); if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return nil }; throw posix() }; return .init(value)
    }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw BrowserDataBackupStorageError.unsafeEntry }
    }
    static func directory(_ url: URL) throws -> Int32 {
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
    static func validateDirectoryPath(_ url: URL, _ expected: BackupIdentity) throws {
        let fd = try directory(url); defer { Darwin.close(fd) }
        guard try identity(fd).sameObject(expected) else { throw BrowserDataBackupStorageError.changed }
    }
    static func relativeParent(_ root: Int32, _ path: String) throws -> Int32 {
        try relativeDirectory(root, path.split(separator: "/").dropLast().joined(separator: "/"))
    }
    static func relativeDirectory(_ root: Int32, _ path: String) throws -> Int32 {
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
    static func names(_ fd: Int32) throws -> [String] {
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
            guard result.count < EncryptedBackupArchive.maximumEntries else { throw BrowserDataBackupStorageError.limitExceeded }
            result.append(name)
        }
        return result.sorted()
    }
    static func read(_ fd: Int32, at offset: Int64, count: Int, checksCancellation: Bool = true) throws -> Data {
        guard count >= 0, count <= EncryptedBackupFraming.maximumPayload + EncryptedBackupFraming.recordOverhead + 16,
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
    static func write(_ fd: Int32, _ data: Data, at offset: Int64, checksCancellation: Bool = true) throws {
        var written = 0
        while written < data.count {
            if checksCancellation { try Task.checkCancellation() }
            let count = data.withUnsafeBytes { pwrite(fd, $0.baseAddress!.advanced(by: written), data.count - written, offset + Int64(written)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posix() }; written += count
        }
    }
    static func hash(_ fd: Int32, size: Int64, checksCancellation: Bool = true) throws -> String {
        var hash = SHA256(), offset: Int64 = 0
        while offset < size {
            let count = Int(min(Int64(EncryptedBackupFraming.maximumPayload), size - offset))
            let bytes = try read(fd, at: offset, count: count, checksCancellation: checksCancellation)
            guard bytes.count == count else { throw BrowserDataBackupStorageError.changed }
            hash.update(data: bytes); offset += Int64(count)
        }
        return hex(hash.finalize())
    }
    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
