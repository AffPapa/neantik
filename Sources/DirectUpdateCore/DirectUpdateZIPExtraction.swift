import CryptoKit
import Darwin
import DirectInstallFilesystem
import DirectZipCodec
import Foundation

package enum DirectUpdateZIPExtractionPoint: Sendable {
    case created(URL), beforeEntry(String), afterEntry(String), beforeSeal, beforeReturn
}

/// Owned extracted bytes only. Developer ID/runtime/notarization and install
/// authority remain separate. Unknown or changed trees are retained.
final package class ExtractedUpdateApp: @unchecked Sendable {
    package let archiveIntegrity: UpdateArchiveIntegrityReceipt
    package let inventory: DirectUpdateZIPInventory
    private let lock = NSLock()
    private let parentURL: URL, name: String
    private let parent: Int32, root: Int32
    private let parentIdentity: BackupIdentity, rootIdentity: BackupIdentity
    fileprivate var identities: [String: BackupIdentity] = [:]
    fileprivate var completed: Set<String> = []
    private var sealedRoot: BackupIdentity?, sealed = false, discarded = false, transferred = false
    fileprivate var rootURL: URL { parentURL.appendingPathComponent(name) }

    fileprivate init(parentURL: URL, parent: Int32, name: String, root: Int32,
                     parentIdentity: BackupIdentity, rootIdentity: BackupIdentity,
                     inventory: DirectUpdateZIPInventory, integrity: UpdateArchiveIntegrityReceipt) {
        self.parentURL = parentURL; self.parent = parent; self.name = name; self.root = root
        self.parentIdentity = parentIdentity; self.rootIdentity = rootIdentity
        self.inventory = inventory; archiveIntegrity = integrity
    }
    deinit { Darwin.close(root); Darwin.close(parent) }

    package func withValidatedApp<T>(_ operation: (URL) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard sealed else { throw DirectUpdateZIPError.changed }
        try validate(exact: true)
        let result = try operation(rootURL.appendingPathComponent("NeAntik.app"))
        try Task.checkCancellation(); try validate(exact: true)
        return result
    }
    /// One-shot custody transfer, distinct from a borrow whose postcondition
    /// requires the app to remain in the extraction namespace. No install trust.
    package func prepareInstallSlot(lease: InstallFilesystemLease,
                            candidateID: UUID = UUID(),
                            validateAdmission: () throws -> Void = {},
                            fault: ((InstallPreparationPoint) throws -> Void)? = nil) throws -> PreparedInstallSlot {
        guard lock.try() else { throw InstallFilesystemError.busy }; defer { lock.unlock() }
        guard sealed else { throw DirectUpdateZIPError.changed }
        try validateAdmission(); try validate(exact: true); try validateAdmission()
        return try InstallPreparation.transfer(lease: lease, sourceParentURL: rootURL,
            sourceParentDescriptor: root, candidateID: candidateID,
            candidateReceiptSHA256: InstallPreparationReceipt.hash(archiveIntegrity),
            validateSource: { try validateAdmission(); try self.validate(exact: true); try validateAdmission() },
            didTransfer: { self.transferred = true }, fault: fault)
    }
    fileprivate func validateRoot(exact: Bool = false) throws {
        guard !discarded, !transferred else { throw DirectUpdateZIPError.changed }
        try BackupFS.validateDirectoryPath(parentURL, parentIdentity)
        let currentParent = try BackupFS.identity(parent), currentRoot = try BackupFS.identity(root)
        guard currentParent.sameObject(parentIdentity), currentParent.mode & 0o777 == 0o700,
              currentRoot.sameObject(rootIdentity), currentRoot.mode & 0o777 == 0o700,
              try BackupFS.entry(parent, name) == currentRoot,
              !exact || currentRoot == sealedRoot else { throw DirectUpdateZIPError.changed }
    }
    fileprivate func checkedDirectory(_ path: String) throws -> Int32 {
        var fd = dup(root); guard fd >= 0 else { throw BackupFS.posix() }
        do {
            var prefix: [String] = []
            for part in path.split(separator: "/").map(String.init) {
                prefix.append(part)
                guard let expected = identities[prefix.joined(separator: "/")], expected.directory else { throw DirectUpdateZIPError.changed }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw DirectUpdateZIPError.changed }
                do {
                    let actual = try BackupFS.identity(next)
                    guard actual.sameObject(expected), actual.mode == expected.mode,
                          try BackupFS.entry(fd, part) == actual else { throw DirectUpdateZIPError.changed }
                } catch { Darwin.close(next); throw error }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    fileprivate func checkedParent(_ path: String) throws -> Int32 {
        try checkedDirectory(path.split(separator: "/").dropLast().joined(separator: "/"))
    }
    fileprivate func validate(exact: Bool, checksCancellation: Bool = true) throws {
        try validateRoot(exact: exact)
        var children: [String: [String]] = ["": []]
        for (path, expected) in identities {
            if checksCancellation { try Task.checkCancellation() }
            let parts = path.split(separator: "/").map(String.init), leaf = parts.last!, prefix = parts.dropLast().joined(separator: "/")
            children[prefix, default: []].append(leaf)
            let directory = try checkedParent(path); defer { Darwin.close(directory) }
            guard let actual = try BackupFS.entry(directory, leaf), actual.sameObject(expected),
                  !(exact || completed.contains(path)) || actual == expected,
                  actual.directory || actual.links == 1 else { throw DirectUpdateZIPError.changed }
            if actual.directory { children[path, default: []] = children[path, default: []] }
        }
        for (path, expectedNames) in children {
            if checksCancellation { try Task.checkCancellation() }
            let directory = try checkedDirectory(path); defer { Darwin.close(directory) }
            guard try BackupFS.names(directory) == expectedNames.sorted() else { throw DirectUpdateZIPError.changed }
        }
    }
    fileprivate func seal() throws {
        try validate(exact: false)
        guard identities.count == inventory.entries.count else { throw DirectUpdateZIPError.changed }
        for entry in inventory.entries {
            try Task.checkCancellation()
            let directory = try checkedParent(entry.path); defer { Darwin.close(directory) }
            let name = entry.path.split(separator: "/").last!.description
            guard let actual = try BackupFS.entry(directory, name), let captured = identities[entry.path],
                  actual.sameObject(captured), entry.kind == .directory || (completed.contains(entry.path) && actual == captured)
            else { throw DirectUpdateZIPError.changed }
            if entry.kind == .symlink {
                var bytes = [CChar](repeating: 0, count: 1_025)
                let count = readlinkat(directory, name, &bytes, 1_025)
                guard count > 0, count <= 1_024,
                      String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) == entry.target
                else { throw DirectUpdateZIPError.changed }
            }
            identities[entry.path] = actual
        }
        sealedRoot = try BackupFS.identity(root); sealed = true
        try validate(exact: true)
    }
    package func discard() throws {
        lock.lock(); defer { lock.unlock() }
        try remove(exact: sealed)
    }
    fileprivate func cleanupFailure() { try? remove(exact: false, checksCancellation: false) }
    private func remove(exact: Bool, checksCancellation: Bool = true) throws {
        try validate(exact: exact, checksCancellation: checksCancellation)
        let retired = ".neantik-update-extract-retiring-" + UUID().uuidString.lowercased()
        guard renameatx_np(parent, name, parent, retired, UInt32(RENAME_EXCL)) == 0 else { throw BackupFS.posix() }
        guard try BackupFS.entry(parent, retired)?.sameObject(rootIdentity) == true else {
            _ = renameatx_np(parent, retired, parent, name, UInt32(RENAME_EXCL)); _ = fsync(parent)
            throw DirectUpdateZIPError.changed
        }
        // No traversal of unlisted paths. The outer private root is retired
        // first; arbitrary concurrent same-UID rewrites remain outside trust.
        for (path, expected) in identities.sorted(by: { $0.key.split(separator: "/").count > $1.key.split(separator: "/").count }) {
            let directory = try checkedParent(path); defer { Darwin.close(directory) }
            let leaf = path.split(separator: "/").last!.description
            guard let actual = try BackupFS.entry(directory, leaf), actual.sameObject(expected),
                  !completed.contains(path) || actual == expected, actual.directory || actual.links == 1
            else { throw DirectUpdateZIPError.changed }
            guard unlinkat(directory, leaf, actual.directory ? AT_REMOVEDIR : 0) == 0 else { throw BackupFS.posix() }
        }
        guard try BackupFS.names(root).isEmpty, unlinkat(parent, retired, AT_REMOVEDIR) == 0 else { throw DirectUpdateZIPError.changed }
        discarded = true
        guard fsync(parent) == 0 else { throw BackupFS.posix() }
    }
}

package enum DirectUpdateZIPExtraction {
    package static func extract(_ archive: PreparedUpdateArchive, destinationParent: URL,
                        fault: (@Sendable (DirectUpdateZIPExtractionPoint) throws -> Void)? = nil) async throws -> ExtractedUpdateApp {
        let worker = Task.detached(priority: .utility) { try extractSynchronously(archive, destinationParent: destinationParent, fault: fault) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    package static func extractSynchronously(_ archive: PreparedUpdateArchive, destinationParent: URL,
                                    fault: (@Sendable (DirectUpdateZIPExtractionPoint) throws -> Void)? = nil) throws -> ExtractedUpdateApp {
        var created: ExtractedUpdateApp?
        do {
            let result = try archive.withValidatedArchiveFile { source, archiveURL, integrity -> ExtractedUpdateApp in
                try Task.checkCancellation()
                let destination = try DirectUpdateArchiveIntegrityService.platformFileURL(destinationParent)
                guard destination != archiveURL.deletingLastPathComponent() else { throw DirectUpdateZIPError.unsafePath }
                let sourceIdentity = try BackupFS.identity(source)
                let inventory = try DirectUpdateZIPInventory.read(source)
                let parent = try BackupFS.directory(destination)
                var transfer = false, root: Int32 = -1
                defer { if !transfer { if root >= 0 { Darwin.close(root) }; Darwin.close(parent) } }
                let parentIdentity = try BackupFS.identity(parent)
                guard parentIdentity.mode & 0o777 == 0o700 else { throw DirectUpdateZIPError.unsafePath }
                let name = ".neantik-update-extract-" + UUID().uuidString.lowercased()
                guard mkdirat(parent, name, 0o700) == 0 else { throw BackupFS.posix() }
                root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard root >= 0 else { throw DirectUpdateZIPError.changed }
                let result = ExtractedUpdateApp(parentURL: destination, parent: parent, name: name, root: root,
                    parentIdentity: parentIdentity, rootIdentity: try BackupFS.identity(root), inventory: inventory, integrity: integrity)
                created = result; transfer = true
                try fault?(.created(result.rootURL))
                let ordered = inventory.entries.sorted {
                    if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
                    let a = $0.path.split(separator: "/").count, b = $1.path.split(separator: "/").count
                    return a == b ? $0.path < $1.path : a < b
                }
                // Links are created last; no writer ever walks a link ancestor.
                for entry in ordered.filter({ $0.kind != .symlink }) {
                    try Task.checkCancellation(); try result.validateRoot(); try fault?(.beforeEntry(entry.path))
                    let directory = try result.checkedParent(entry.path); defer { Darwin.close(directory) }
                    let leaf = entry.path.split(separator: "/").last!.description
                    if entry.kind == .directory {
                        guard mkdirat(directory, leaf, 0o700) == 0 else { throw BackupFS.posix() }
                        guard let identity = try BackupFS.entry(directory, leaf) else { throw DirectUpdateZIPError.changed }
                        result.identities[entry.path] = identity
                    } else {
                        let output = openat(directory, leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard output >= 0 else { throw BackupFS.posix() }; defer { Darwin.close(output) }
                        result.identities[entry.path] = try BackupFS.identity(output)
                        let status = neantik_zip_decode_fd(source, UInt64(entry.dataOffset), UInt64(entry.compressed), output,
                            UInt64(entry.expanded), entry.method, entry.crc, { _ in Task.isCancelled ? 1 : 0 }, nil)
                        if status == NEANTIK_ZIP_CANCELLED { throw CancellationError() }
                        if status == NEANTIK_ZIP_CRC { throw DirectUpdateZIPError.checksum }
                        guard status == NEANTIK_ZIP_OK else { throw DirectUpdateZIPError.codec }
                        guard fchmod(output, entry.mode) == 0, fsync(output) == 0 else { throw BackupFS.posix() }
                        result.identities[entry.path] = try BackupFS.identity(output)
                        result.completed.insert(entry.path)
                    }
                    try fault?(.afterEntry(entry.path))
                }
                for entry in inventory.entries.filter({ $0.kind == .symlink }) {
                    try Task.checkCancellation(); try result.validateRoot(); try fault?(.beforeEntry(entry.path))
                    let directory = try result.checkedParent(entry.path); defer { Darwin.close(directory) }
                    let leaf = entry.path.split(separator: "/").last!.description
                    guard let target = entry.target, symlinkat(target, directory, leaf) == 0 else { throw BackupFS.posix() }
                    guard let identity = try BackupFS.entry(directory, leaf) else { throw DirectUpdateZIPError.changed }
                    result.identities[entry.path] = identity; result.completed.insert(entry.path)
                    try fault?(.afterEntry(entry.path))
                }
                // Restore directory modes only after creation. File modes never
                // acquire suid/sgid/sticky bits, owner changes or xattrs.
                for entry in inventory.entries.filter({ $0.kind == .directory }).reversed() {
                    let directory = try result.checkedDirectory(entry.path); defer { Darwin.close(directory) }
                    guard fchmod(directory, entry.mode) == 0, fsync(directory) == 0 else { throw BackupFS.posix() }
                    result.identities[entry.path] = try BackupFS.identity(directory)
                }
                guard fsync(root) == 0, fsync(parent) == 0 else { throw BackupFS.posix() }
                try fault?(.beforeSeal); try Task.checkCancellation(); try result.seal()
                try fault?(.beforeReturn); try Task.checkCancellation(); try result.validate(exact: true)
                guard try BackupFS.identity(source) == sourceIdentity else { throw DirectUpdateZIPError.changed }
                return result
            }
            try Task.checkCancellation()
            return result
        } catch { created?.cleanupFailure(); throw error }
    }
}

private enum InstallPreparationReceipt {
    static func hash(_ receipt: UpdateArchiveIntegrityReceipt) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(receipt)).map { String(format: "%02x", $0) }.joined()
    }
}
