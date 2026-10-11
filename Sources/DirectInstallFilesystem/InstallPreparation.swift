import Darwin
import Foundation

public enum InstallPreparationPoint: String, CaseIterable {
    case created, recordWrittenBeforeSync, recordFileSynced, recordDirectorySynced
    case recordPublishedBeforeSync, intentDurable, beforeRename, renamedBeforeSync
    case sourceDirectorySynced, destinationDirectorySynced, beforeReturn
}

/// Filesystem custody only. Neither state authorizes execution or installation.
public enum InstallPreparationLocation: String, Equatable { case source, candidate, journal }

struct InstallPreparationBinding: Codable, Equatable {
    let name: String, sha256: String, directory: InstallObject, file: InstallObject
}

/// A one-shot in-memory handle. No cleanup API and no destructor deletes files.
/// After journal publication its pathname can contain the OLD app after swap.
public final class PreparedInstallSlot {
    public let candidateName: String
    private let lock = NSLock()
    let lease: InstallFilesystemLease, binding: InstallPreparationBinding, tree: InstallTree, receipt: String
    private var journalOwned = false
    fileprivate init(lease: InstallFilesystemLease, binding: InstallPreparationBinding, record: InstallPreparation.Record) {
        self.lease = lease; self.binding = binding; tree = record.tree; receipt = record.receipt
        candidateName = record.candidateName
    }
    public func withValidatedCandidate<T>(_ operation: (URL) throws -> T) throws -> T {
        guard lock.try() else { throw InstallFilesystemError.busy }; defer { lock.unlock() }
        try validate(); let result = try operation(lease.url.appendingPathComponent(candidateName))
        try Task.checkCancellation(); try validate(); return result
    }
    func withTransaction<T>(_ supplied: InstallFilesystemLease, _ operation: (() -> Void) throws -> T) throws -> T {
        guard lock.try() else { throw InstallFilesystemError.busy }; defer { lock.unlock() }
        guard lease === supplied else { throw InstallFilesystemError.changed }
        try validate()
        return try operation({ self.journalOwned = true })
    }
    func validate() throws {
        guard !journalOwned else { throw InstallFilesystemError.changed }
        let record = try InstallPreparation.load(lease: lease, binding: binding)
        guard record.candidateName == candidateName, record.receipt == receipt, record.tree == tree,
              tree.matches(try InstallTree.capture(parent: lease.parent, name: candidateName)) else { throw InstallFilesystemError.changed }
    }
}

/// Transfer of an already sealed/extracted app on the same filesystem. Records
/// are retained on every failure; incomplete records fence further preparation.
/// Recovery classifies custody but never silently adopts or deletes an orphan.
public enum InstallPreparation {
    static let prefix = ".neantik-install-transfer-", preparingPrefix = ".neantik-install-transfer-preparing-"
    static let fileName = "transfer.json", maximumBytes = 4 * 1_024 * 1_024
    struct Record: Codable {
        let schema: Int, id: UUID
        let parent: InstallObject, leaseObject: InstallObject, source: InstallObject
        let candidateName: String, receipt: String, tree: InstallTree
        let directory: InstallObject, file: InstallObject
    }
    struct Document: Codable { let record: Record, sha256: String }

    /// validateSource is called under the owning stage's lock; didTransfer must
    /// invalidate that stage immediately and MUST NOT throw or re-enter its lock.
    public static func transfer(lease: InstallFilesystemLease, sourceParentURL: URL, sourceParentDescriptor: Int32,
                                candidateID: UUID = UUID(), candidateReceiptSHA256: String,
                                validateSource: () throws -> Void, didTransfer: () -> Void,
                                fault: ((InstallPreparationPoint) throws -> Void)? = nil) throws -> PreparedInstallSlot {
        try lease.validate(); try validateSource(); try Task.checkCancellation()
        guard InstallFS.validHash(candidateReceiptSHA256) else { throw InstallFilesystemError.unsafe }
        let source = try InstallFS.privateDirectory(sourceParentDescriptor)
        guard source.device == lease.identity.device, !source.sameObject(lease.identity) else { throw InstallFilesystemError.unsupported }
        func validateParent() throws {
            let fresh = try InstallFS.directory(sourceParentURL); defer { close(fresh) }
            guard try InstallFS.privateDirectory(fresh).sameObject(source),
                  try InstallFS.privateDirectory(sourceParentDescriptor).sameObject(source) else { throw InstallFilesystemError.changed }
            try lease.validate()
        }
        try validateParent()
        guard try InstallFS.names(sourceParentDescriptor) == [InstallFilesystemTransaction.appName] else { throw InstallFilesystemError.changed }
        let names = try InstallFS.names(lease.parent)
        guard !names.contains(InstallFilesystemTransaction.activeName),
              !names.contains(where: { $0.hasPrefix(".neantik-install-preparing-") }),
              try unresolvedNames(lease: lease).isEmpty else { throw InstallFilesystemError.pending }
        let id = candidateID, candidate = ".neantik-next-" + id.uuidString.lowercased() + ".app"
        guard try InstallFS.entry(lease.parent, candidate) == nil else { throw InstallFilesystemError.pending }
        let tree = try InstallTree.capture(parent: sourceParentDescriptor, name: InstallFilesystemTransaction.appName)
        // These bytes must survive the later name transfer; sync all captured
        // regular files and directories, then re-seal after synchronization.
        try syncTree(parent: sourceParentDescriptor, tree: tree)
        try validateParent(); try validateSource()
        guard tree.matches(try InstallTree.capture(parent: sourceParentDescriptor, name: InstallFilesystemTransaction.appName)) else { throw InstallFilesystemError.changed }
        let pending = preparingPrefix + id.uuidString.lowercased(), name = prefix + id.uuidString.lowercased()
        guard mkdirat(lease.parent, pending, 0o700) == 0 else { throw InstallFS.posix() }
        let directory = openat(lease.parent, pending, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw InstallFilesystemError.changed }; defer { close(directory) }
        let directoryObject = try InstallFS.privateDirectory(directory)
        try fault?(.created)
        let file = openat(directory, fileName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw InstallFS.posix() }; defer { close(file) }
        let record = Record(schema: 1, id: id, parent: lease.identity, leaseObject: lease.lockIdentity, source: source,
            candidateName: candidate, receipt: candidateReceiptSHA256, tree: tree, directory: directoryObject, file: try InstallFS.object(file))
        let digest = InstallFS.hash(try InstallFS.encode(record)), bytes = try InstallFS.encode(Document(record: record, sha256: digest))
        guard bytes.count <= maximumBytes else { throw InstallFilesystemError.limit }
        try InstallFS.write(file, bytes); try fault?(.recordWrittenBeforeSync)
        try InstallFS.sync(file); try fault?(.recordFileSynced); try InstallFS.sync(directory); try fault?(.recordDirectorySynced)
        try validateParent(); try validateSource(); try Task.checkCancellation()
        guard try InstallFS.entry(lease.parent, pending)?.sameObject(directoryObject) == true,
              try InstallFS.names(directory) == [fileName], try InstallFS.object(file).sameObject(record.file),
              try InstallFS.entry(directory, fileName) == InstallFS.object(file), try InstallFS.bytes(file, maximum: maximumBytes) == bytes,
              renameatx_np(lease.parent, pending, lease.parent, name, UInt32(RENAME_EXCL)) == 0 else { throw InstallFilesystemError.changed }
        let binding = InstallPreparationBinding(name: name, sha256: digest, directory: directoryObject, file: record.file)
        try fault?(.recordPublishedBeforeSync); try InstallFS.sync(lease.parent); try fault?(.intentDurable)
        try fault?(.beforeRename)
        try validateParent(); try validateSource(); _ = try load(lease: lease, binding: binding)
        guard try InstallFS.names(sourceParentDescriptor) == [InstallFilesystemTransaction.appName],
              tree.matches(try InstallTree.capture(parent: sourceParentDescriptor, name: InstallFilesystemTransaction.appName)),
              try InstallFS.entry(lease.parent, candidate) == nil else { throw InstallFilesystemError.changed }
        try validateParent(); try validateSource(); try Task.checkCancellation()
        guard renameatx_np(sourceParentDescriptor, InstallFilesystemTransaction.appName, lease.parent, candidate, UInt32(RENAME_EXCL)) == 0 else { throw InstallFS.posix() }
        // Never throw, check cancellation or call a fault hook BEFORE this.
        didTransfer()
        try fault?(.renamedBeforeSync)
        try InstallFS.sync(sourceParentDescriptor); try fault?(.sourceDirectorySynced)
        try InstallFS.sync(lease.parent); try fault?(.destinationDirectorySynced)
        try validateParent(); _ = try load(lease: lease, binding: binding)
        guard try InstallFS.names(sourceParentDescriptor).isEmpty,
              tree.matches(try InstallTree.capture(parent: lease.parent, name: candidate)) else { throw InstallFilesystemError.changed }
        try fault?(.beforeReturn); try Task.checkCancellation()
        let slot = PreparedInstallSlot(lease: lease, binding: binding, record: record)
        try slot.validate(); return slot
    }

    /// An explicit source path is re-established by the caller, never followed
    /// from untrusted journal text. No install permission/token is returned.
    public static func inspect(lease: InstallFilesystemLease, recordName: String, sourceParentURL: URL) throws -> InstallPreparationLocation {
        let (record, binding) = try read(lease: lease, name: recordName)
        if try InstallFilesystemTransaction.settledPreparation(lease: lease, binding: binding) { return .journal }
        if try InstallFilesystemTransaction.ownsPreparation(lease: lease, binding: binding) { return .journal }
        let source = try InstallFS.directory(sourceParentURL); defer { close(source) }
        guard try InstallFS.privateDirectory(source).sameObject(record.source) else { throw InstallFilesystemError.changed }
        let sourceNames = try InstallFS.names(source)
        guard sourceNames.isEmpty || sourceNames == [InstallFilesystemTransaction.appName] else { throw InstallFilesystemError.changed }
        let sourcePresent = !sourceNames.isEmpty
        let candidatePresent = try InstallFS.entry(lease.parent, record.candidateName) != nil
        if sourcePresent && !candidatePresent {
            guard record.tree.matches(try InstallTree.capture(parent: source, name: InstallFilesystemTransaction.appName)) else { throw InstallFilesystemError.changed }
            return .source
        }
        if !sourcePresent && candidatePresent {
            guard record.tree.matches(try InstallTree.capture(parent: lease.parent, name: record.candidateName)) else { throw InstallFilesystemError.changed }
            return .candidate
        }
        throw InstallFilesystemError.changed
    }

    // Retained finalized records do not prevent the next update. A canonical
    // journal with its exact decision must prove custody was already handed off.
    // Incomplete, unknown, changed or unbound records continue to fence retries.
    static func unresolvedNames(lease: InstallFilesystemLease) throws -> [String] {
        var pending: [String] = []
        for name in try InstallFS.names(lease.parent).filter({ $0.hasPrefix(prefix) }) {
            if name.hasPrefix(preparingPrefix) { pending.append(name); continue }
            let (_, binding) = try read(lease: lease, name: name)
            if try !InstallFilesystemTransaction.settledPreparation(lease: lease, binding: binding) { pending.append(name) }
        }
        return pending
    }
    static func load(lease: InstallFilesystemLease, binding: InstallPreparationBinding) throws -> Record {
        let (record, current) = try read(lease: lease, name: binding.name)
        guard current == binding else { throw InstallFilesystemError.changed }; return record
    }
    private static func read(lease: InstallFilesystemLease, name: String) throws -> (Record, InstallPreparationBinding) {
        try lease.validate(); try InstallFS.name(name)
        guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + id.uuidString.lowercased(), let observed = try InstallFS.entry(lease.parent, name) else { throw InstallFilesystemError.changed }
        let directory = openat(lease.parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw InstallFilesystemError.changed }; defer { close(directory) }
        guard try InstallFS.privateDirectory(directory).sameObject(observed), try InstallFS.names(directory) == [fileName] else { throw InstallFilesystemError.changed }
        let file = openat(directory, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw InstallFilesystemError.changed }; defer { close(file) }; try InstallFS.noACL(file)
        let bytes = try InstallFS.bytes(file, maximum: maximumBytes), document: Document
        do { document = try JSONDecoder().decode(Document.self, from: bytes) } catch { throw InstallFilesystemError.unsupported }
        let r = document.record
        guard r.schema == 1, r.id == id, r.candidateName == ".neantik-next-" + id.uuidString.lowercased() + ".app",
              InstallFS.validHash(r.receipt), r.parent.sameObject(lease.identity), r.leaseObject == lease.lockIdentity,
              r.source.device == lease.identity.device, !r.source.sameObject(lease.identity), r.tree.root.device == lease.identity.device,
              r.directory.sameObject(observed), r.file.sameObject(try InstallFS.object(file)),
              try InstallFS.entry(directory, fileName) == InstallFS.object(file), r.tree.entries.count <= 6_000,
              InstallFS.validHash(document.sha256), InstallFS.hash(try InstallFS.encode(r)) == document.sha256,
              try InstallFS.encode(document) == bytes else { throw InstallFilesystemError.changed }
        try lease.validate()
        guard try InstallFS.entry(lease.parent, name)?.sameObject(observed) == true else { throw InstallFilesystemError.changed }
        return (r, .init(name: name, sha256: document.sha256, directory: r.directory, file: r.file))
    }
    private static func syncTree(parent: Int32, tree: InstallTree) throws {
        let root = openat(parent, InstallFilesystemTransaction.appName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw InstallFilesystemError.changed }; defer { close(root) }
        guard try InstallFS.object(root).sameObject(tree.root) else { throw InstallFilesystemError.changed }
        // Captured paths only. Links are never opened or traversed.
        for entry in tree.entries.reversed() where entry.target == nil {
            try Task.checkCancellation()
            var descriptor = dup(root); guard descriptor >= 0 else { throw InstallFS.posix() }
            defer { close(descriptor) }
            let parts = entry.path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                let next = openat(descriptor, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | ((index < parts.count - 1 || entry.identity.directory) ? O_DIRECTORY : 0))
                guard next >= 0 else { throw InstallFilesystemError.changed }; close(descriptor); descriptor = next
            }
            guard try InstallFS.object(descriptor) == entry.identity else { throw InstallFilesystemError.changed }
            try InstallFS.noACL(descriptor); try InstallFS.sync(descriptor)
        }
        try InstallFS.sync(root); try InstallFS.sync(parent)
    }
}
