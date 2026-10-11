import Darwin
import Foundation

public enum InstallFilesystemPoint: String, CaseIterable {
    case prepared, journalWrittenBeforeSync, journalFileSynced, journalSynced, beforeActivation, activatedBeforeSync, intentDurable
    case beforeSwap, swappedBeforeSync, pendingLaunch, beforeAcknowledgement
    case acknowledgementWrittenBeforeSync, acknowledgementFileSynced, beforeAcknowledgementPublication, beforeRollbackSwap
    case acknowledgementPublishedBeforeSync, acknowledgementDurable
    case beforeRollback, rolledBackBeforeSync, rollbackDurable
    case beforeFinish, finalizedBeforeSync, finished
}

/// A binding for a future authenticated first-launch protocol, not a permission
/// or proof of successful execution. This module deliberately has no launcher.
public struct InstallFilesystemReceipt: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let journalSHA256: String
    public let candidateReceiptSHA256: String
    public let candidateDevice: Int64
    public let candidateInode: UInt64
}

public struct InstallFilesystemResult: Equatable, Sendable {
    public let transactionID: UUID
    public let committed: Bool
}

/// Finite two-slot filesystem primitive ONLY. Callers must separately establish
/// signature/provisioning/runtime/system trust, stage transfer, all-process
/// stopped authority and authenticated readiness. No production caller exists.
/// Before a valid durable acknowledgement, recovery restores the original app.
/// Both trees and finalized records are retained; user-data rollback is separate.
public enum InstallFilesystemTransaction {
    public static let activeName = ".neantik-install-active"
    public static let appName = "NeAntik.app"
    static let journalName = "journal.json", pendingAckName = "ack.pending", commitName = "commit.json"
    static let maximumJournalBytes = 4 * 1_024 * 1_024
    struct Journal: Codable {
        let schema: Int
        let transactionID: UUID
        let candidateReceiptSHA256: String
        let parent: InstallObject, leaseObject: InstallObject, directory: InstallObject, journalObject: InstallObject
        let candidateName: String
        let original: InstallTree, candidate: InstallTree
        let preparation: InstallPreparationBinding?
    }
    struct Document: Codable { let journal: Journal, sha256: String }
    struct Loaded {
        let journal: Journal, digest: String, descriptor: Int32, object: InstallObject, name: String
        var receipt: InstallFilesystemReceipt {
            .init(transactionID: journal.transactionID, journalSHA256: digest,
                  candidateReceiptSHA256: journal.candidateReceiptSHA256,
                  candidateDevice: journal.candidate.root.device, candidateInode: journal.candidate.root.inode)
        }
    }
    private static func candidateName(_ name: String) throws {
        try InstallFS.name(name)
        guard name.hasPrefix(".neantik-next-"), name.hasSuffix(".app"),
              let id = UUID(uuidString: String(name.dropFirst(14).dropLast(4))),
              name == ".neantik-next-" + id.uuidString.lowercased() + ".app" else { throw InstallFilesystemError.unsafe }
    }

    /// Slots must already exist under one private, user-owned, same-volume
    /// parent. This method does not copy/adopt ExtractedUpdateApp or authorize it.
    public static func begin(lease: InstallFilesystemLease, candidateName: String,
                             candidateReceiptSHA256: String, validateStoppedAuthority: () throws -> Void,
                             fault: ((InstallFilesystemPoint) throws -> Void)? = nil) throws -> InstallFilesystemReceipt {
        try beginCore(lease: lease, candidateName: candidateName, candidateReceiptSHA256: candidateReceiptSHA256,
                      preparation: nil, didActivate: {}, validateStoppedAuthority: validateStoppedAuthority, fault: fault)
    }

    /// A prepared token is consumed immediately on visible journal publication,
    /// before a sync or throwing hook. Its old pathname is never cleanup authority.
    public static func begin(lease: InstallFilesystemLease, preparedSlot: PreparedInstallSlot,
                             validateStoppedAuthority: () throws -> Void,
                             fault: ((InstallFilesystemPoint) throws -> Void)? = nil) throws -> InstallFilesystemReceipt {
        try preparedSlot.withTransaction(lease) { consume in
            try beginCore(lease: lease, candidateName: preparedSlot.candidateName,
                          candidateReceiptSHA256: preparedSlot.receipt, preparation: preparedSlot.binding,
                          didActivate: consume, validateStoppedAuthority: validateStoppedAuthority, fault: fault)
        }
    }
    private static func beginCore(lease: InstallFilesystemLease, candidateName: String, candidateReceiptSHA256: String,
                                  preparation: InstallPreparationBinding?, didActivate: () -> Void,
                                  validateStoppedAuthority: () throws -> Void,
                                  fault: ((InstallFilesystemPoint) throws -> Void)?) throws -> InstallFilesystemReceipt {
        try lease.validate(); try validateStoppedAuthority(); try Task.checkCancellation()
        try self.candidateName(candidateName)
        guard InstallFS.validHash(candidateReceiptSHA256) else { throw InstallFilesystemError.unsafe }
        guard try InstallFS.entry(lease.parent, activeName) == nil,
              !(try InstallFS.names(lease.parent)).contains(where: { $0.hasPrefix(".neantik-install-preparing-") }) else { throw InstallFilesystemError.pending }
        let transferNames = try InstallPreparation.unresolvedNames(lease: lease)
        guard transferNames == (preparation.map { [$0.name] } ?? []) else { throw InstallFilesystemError.pending }
        if let preparation { _ = try InstallPreparation.load(lease: lease, binding: preparation) }
        let old = try InstallTree.capture(parent: lease.parent, name: appName)
        let new = try InstallTree.capture(parent: lease.parent, name: candidateName)
        guard old.root.device == lease.identity.device, new.root.device == lease.identity.device,
              !old.root.sameObject(new.root) else { throw InstallFilesystemError.unsafe }
        if let preparation {
            let record = try InstallPreparation.load(lease: lease, binding: preparation)
            guard record.candidateName == candidateName, record.receipt == candidateReceiptSHA256,
                  record.tree.matches(new) else { throw InstallFilesystemError.changed }
        }
        let transactionID = UUID(), preparing = ".neantik-install-preparing-" + transactionID.uuidString.lowercased()
        guard mkdirat(lease.parent, preparing, 0o700) == 0 else { throw InstallFS.posix() }
        let directory = openat(lease.parent, preparing, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw InstallFilesystemError.changed }; defer { close(directory) }
        let directoryObject = try InstallFS.privateDirectory(directory)
        guard directoryObject.device == lease.identity.device else { throw InstallFilesystemError.unsafe }
        try fault?(.prepared)
        let file = openat(directory, journalName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw InstallFS.posix() }; defer { close(file) }
        let journal = Journal(schema: 1, transactionID: transactionID, candidateReceiptSHA256: candidateReceiptSHA256,
            parent: lease.identity, leaseObject: lease.lockIdentity, directory: directoryObject, journalObject: try InstallFS.object(file),
            candidateName: candidateName, original: old, candidate: new, preparation: preparation)
        let hash = InstallFS.hash(try InstallFS.encode(journal)), bytes = try InstallFS.encode(Document(journal: journal, sha256: hash))
        guard bytes.count <= maximumJournalBytes else { throw InstallFilesystemError.limit }
        try InstallFS.write(file, bytes); try fault?(.journalWrittenBeforeSync)
        try InstallFS.sync(file); try fault?(.journalFileSynced); try InstallFS.sync(directory)
        try fault?(.journalSynced)
        try validatePair(lease, journal, requireNew: false)
        try validateStoppedAuthority(); try Task.checkCancellation(); try fault?(.beforeActivation)
        try lease.validate()
        guard try InstallFS.entry(lease.parent, preparing)?.sameObject(directoryObject) == true,
              try InstallFS.object(file).sameObject(journal.journalObject),
              try InstallFS.bytes(file, maximum: maximumJournalBytes) == bytes,
              try InstallFS.names(directory) == [journalName],
              renameatx_np(lease.parent, preparing, lease.parent, activeName, UInt32(RENAME_EXCL)) == 0 else { throw InstallFilesystemError.changed }
        // Publication transfers cleanup custody even if the following sync fails.
        // Neither this worker nor a preparer deletes either application tree.
        didActivate()
        try fault?(.activatedBeforeSync); try InstallFS.sync(lease.parent); try fault?(.intentDurable)
        let loaded = try load(lease); defer { close(loaded.descriptor) }
        guard loaded.digest == hash else { throw InstallFilesystemError.changed }
        try validateStoppedAuthority(); try Task.checkCancellation(); try fault?(.beforeSwap)
        try validatePair(lease, journal, requireNew: false); try validateLoaded(lease, loaded)
        guard try InstallFS.names(loaded.descriptor) == [journalName] else { throw InstallFilesystemError.changed }
        try validateStoppedAuthority(); try Task.checkCancellation()
        try swap(lease, journal); try fault?(.swappedBeforeSync); try InstallFS.sync(lease.parent)
        try validatePair(lease, journal, requireNew: true); try validateLoaded(lease, loaded)
        try fault?(.pendingLaunch)
        return loaded.receipt
    }

    public static func pendingReceipt(lease: InstallFilesystemLease) throws -> InstallFilesystemReceipt? {
        try lease.validate(); guard try InstallFS.entry(lease.parent, activeName) != nil else { return nil }
        let loaded = try load(lease); defer { close(loaded.descriptor) }
        try validatePair(lease, loaded.journal, requireNew: true); return loaded.receipt
    }

    /// Records a decision only AFTER the caller authenticates the exact new
    /// process/session/readiness. A receipt supplied by a file or version string
    /// alone is insufficient. Current use is isolated filesystem QA only.
    public static func acknowledge(lease: InstallFilesystemLease, expected: InstallFilesystemReceipt,
                                   validateLaunchAuthority: () throws -> Void,
                                   fault: ((InstallFilesystemPoint) throws -> Void)? = nil) throws -> InstallFilesystemResult {
        let loaded = try load(lease); defer { close(loaded.descriptor) }
        guard loaded.receipt == expected else { throw InstallFilesystemError.invalidAcknowledgement }
        try validatePair(lease, loaded.journal, requireNew: true)
        guard try InstallFS.entry(loaded.descriptor, pendingAckName) == nil,
              try InstallFS.entry(loaded.descriptor, commitName) == nil else { throw InstallFilesystemError.pending }
        try validateLaunchAuthority(); try Task.checkCancellation(); try fault?(.beforeAcknowledgement)
        try validateLoaded(lease, loaded); try validatePair(lease, loaded.journal, requireNew: true)
        let file = openat(loaded.descriptor, pendingAckName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw InstallFS.posix() }; defer { close(file) }
        let created = try InstallFS.object(file), bytes = try InstallFS.encode(expected)
        try InstallFS.write(file, bytes); try fault?(.acknowledgementWrittenBeforeSync)
        try InstallFS.sync(file); try fault?(.acknowledgementFileSynced)
        try validateLaunchAuthority(); try Task.checkCancellation(); try validateLoaded(lease, loaded)
        guard try InstallFS.object(file).sameObject(created),
              try InstallFS.entry(loaded.descriptor, pendingAckName) == InstallFS.object(file),
              try InstallFS.bytes(file, maximum: 2_048) == bytes else { throw InstallFilesystemError.changed }
        try validatePair(lease, loaded.journal, requireNew: true)
        try fault?(.beforeAcknowledgementPublication); try validateLaunchAuthority(); try Task.checkCancellation()
        try validateLoaded(lease, loaded)
        guard renameatx_np(loaded.descriptor, pendingAckName, loaded.descriptor, commitName, UInt32(RENAME_EXCL)) == 0 else { throw InstallFS.posix() }
        // From visible publication onward completion ignores Task cancellation:
        // selecting rollback after this point could contradict the durable ACK.
        try fault?(.acknowledgementPublishedBeforeSync); try InstallFS.sync(loaded.descriptor)
        try fault?(.acknowledgementDurable)
        return try finish(lease, loaded, committed: true, fault: fault)
    }

    /// Caller re-establishes stopped authority for both app/runtime/relay trees.
    /// Missing ACK restores old. Unknown custody/namespace preserves the fence.
    public static func recover(lease: InstallFilesystemLease, validateStoppedAuthority: () throws -> Void,
                               fault: ((InstallFilesystemPoint) throws -> Void)? = nil) throws -> InstallFilesystemResult? {
        try lease.validate(); guard try InstallFS.entry(lease.parent, activeName) != nil else { return nil }
        let loaded = try load(lease); defer { close(loaded.descriptor) }
        try validateStoppedAuthority()
        let committed = try acknowledgement(loaded)
        let newActive = try orientation(lease, loaded.journal)
        guard !committed || newActive else { throw InstallFilesystemError.changed }
        if !committed {
            try Task.checkCancellation(); try fault?(.beforeRollback)
            try validateStoppedAuthority(); try validateLoaded(lease, loaded)
            if newActive {
                try validatePair(lease, loaded.journal, requireNew: true); try fault?(.beforeRollbackSwap)
                try validateStoppedAuthority(); try Task.checkCancellation(); try validateLoaded(lease, loaded)
                try swap(lease, loaded.journal)
                try fault?(.rolledBackBeforeSync)
            }
            try InstallFS.sync(lease.parent); try validatePair(lease, loaded.journal, requireNew: false)
            try fault?(.rollbackDurable)
        }
        return try finish(lease, loaded, committed: committed, fault: fault)
    }

    private static func swap(_ lease: InstallFilesystemLease, _ journal: Journal) throws {
        guard renameatx_np(lease.parent, appName, lease.parent, journal.candidateName, UInt32(RENAME_SWAP)) == 0 else { throw InstallFS.posix() }
    }
    private static func orientation(_ lease: InstallFilesystemLease, _ journal: Journal) throws -> Bool {
        try lease.validate()
        guard journal.parent.sameObject(lease.identity),
              let active = try InstallFS.entry(lease.parent, appName),
              let retained = try InstallFS.entry(lease.parent, journal.candidateName) else { throw InstallFilesystemError.changed }
        if active.sameObject(journal.original.root), retained.sameObject(journal.candidate.root) {
            try validatePair(lease, journal, requireNew: false); return false
        }
        if active.sameObject(journal.candidate.root), retained.sameObject(journal.original.root) {
            try validatePair(lease, journal, requireNew: true); return true
        }
        throw InstallFilesystemError.changed
    }
    private static func validatePair(_ lease: InstallFilesystemLease, _ journal: Journal, requireNew: Bool,
                                     checksCancellation: Bool = true) throws {
        try lease.validate()
        let active = try InstallTree.capture(parent: lease.parent, name: appName, checksCancellation: checksCancellation)
        let retained = try InstallTree.capture(parent: lease.parent, name: journal.candidateName, checksCancellation: checksCancellation)
        guard (requireNew ? journal.candidate : journal.original).matches(active),
              (requireNew ? journal.original : journal.candidate).matches(retained),
              journal.parent.sameObject(lease.identity) else { throw InstallFilesystemError.changed }
        try lease.validate()
        try validatePreparation(lease, journal)
    }
    private static func validatePreparation(_ lease: InstallFilesystemLease, _ journal: Journal) throws {
        guard let binding = journal.preparation else { return }
        let record = try InstallPreparation.load(lease: lease, binding: binding)
        guard record.candidateName == journal.candidateName, record.receipt == journal.candidateReceiptSHA256,
              record.tree.matches(journal.candidate) else { throw InstallFilesystemError.changed }
    }
    // Read-only crash recovery classification; no token adoption or deletion.
    static func ownsPreparation(lease: InstallFilesystemLease, binding: InstallPreparationBinding) throws -> Bool {
        // Finalized history has its own decision check; current slot orientation
        // applies only while the transaction still owns the active fence.
        let names = try InstallFS.names(lease.parent).filter { $0 == activeName }
        for name in names {
            let loaded = try load(lease, name: name); defer { close(loaded.descriptor) }
            if loaded.journal.preparation == binding {
                _ = try orientation(lease, loaded.journal)
                return true
            }
        }
        return false
    }
    static func settledPreparation(lease: InstallFilesystemLease, binding: InstallPreparationBinding) throws -> Bool {
        for name in try InstallFS.names(lease.parent).filter({ $0.hasPrefix(".neantik-install-committed-") || $0.hasPrefix(".neantik-install-rolledback-") }) {
            let loaded = try load(lease, name: name); defer { close(loaded.descriptor) }
            if loaded.journal.preparation == binding {
                guard try acknowledgement(loaded) == name.hasPrefix(".neantik-install-committed-") else { throw InstallFilesystemError.changed }
                return true
            }
        }
        return false
    }
    private static func load(_ lease: InstallFilesystemLease, name: String = activeName) throws -> Loaded {
        try lease.validate()
        guard let observed = try InstallFS.entry(lease.parent, name), observed.directory else { throw InstallFilesystemError.changed }
        let directory = openat(lease.parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw InstallFilesystemError.changed }
        var keep = false; defer { if !keep { close(directory) } }
        guard try InstallFS.privateDirectory(directory).sameObject(observed), observed.device == lease.identity.device else { throw InstallFilesystemError.changed }
        let file = openat(directory, journalName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw InstallFilesystemError.changed }; defer { close(file) }
        try InstallFS.noACL(file)
        let bytes = try InstallFS.bytes(file, maximum: maximumJournalBytes)
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: bytes) } catch { throw InstallFilesystemError.unsupported }
        let journal = document.journal
        guard journal.schema == 1, InstallFS.validHash(document.sha256), InstallFS.validHash(journal.candidateReceiptSHA256),
              InstallFS.hash(try InstallFS.encode(journal)) == document.sha256,
              try InstallFS.encode(document) == bytes,
              journal.parent.sameObject(lease.identity), journal.leaseObject == lease.lockIdentity, journal.directory.sameObject(observed),
              try InstallFS.object(file).sameObject(journal.journalObject),
              try InstallFS.entry(directory, journalName) == InstallFS.object(file),
              journal.original.entries.count <= 6_000, journal.candidate.entries.count <= 6_000 else { throw InstallFilesystemError.changed }
        try candidateName(journal.candidateName)
        guard name == activeName || name == ".neantik-install-committed-" + journal.transactionID.uuidString.lowercased()
                || name == ".neantik-install-rolledback-" + journal.transactionID.uuidString.lowercased() else { throw InstallFilesystemError.changed }
        let loaded = Loaded(journal: journal, digest: document.sha256, descriptor: directory, object: observed, name: name)
        try validateLoaded(lease, loaded); keep = true; return loaded
    }
    private static func validateLoaded(_ lease: InstallFilesystemLease, _ loaded: Loaded) throws {
        try lease.validate()
        guard try InstallFS.privateDirectory(loaded.descriptor).sameObject(loaded.object),
              try InstallFS.entry(lease.parent, loaded.name)?.sameObject(loaded.object) == true else { throw InstallFilesystemError.changed }
        let names = try InstallFS.names(loaded.descriptor)
        guard names.contains(journalName), names.allSatisfy({ [journalName, pendingAckName, commitName].contains($0) }),
              !(names.contains(pendingAckName) && names.contains(commitName)) else { throw InstallFilesystemError.changed }
        let file = openat(loaded.descriptor, journalName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw InstallFilesystemError.changed }; defer { close(file) }
        try InstallFS.noACL(file)
        guard try InstallFS.object(file).sameObject(loaded.journal.journalObject),
              try InstallFS.bytes(file, maximum: maximumJournalBytes) == InstallFS.encode(Document(journal: loaded.journal, sha256: loaded.digest)),
              try InstallFS.entry(loaded.descriptor, journalName) == InstallFS.object(file) else { throw InstallFilesystemError.changed }
        try validatePreparation(lease, loaded.journal)
        // An interrupted uncommitted ACK is retained but never interpreted.
        if names.contains(pendingAckName) { _ = try readRecord(loaded.descriptor, pendingAckName) }
    }
    private static func readRecord(_ parent: Int32, _ name: String) throws -> Data {
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw InstallFilesystemError.changed }; defer { close(file) }
        try InstallFS.noACL(file)
        let before = try InstallFS.object(file), bytes = try InstallFS.bytes(file, maximum: 2_048)
        guard try InstallFS.entry(parent, name) == before else { throw InstallFilesystemError.changed }; return bytes
    }
    private static func acknowledgement(_ loaded: Loaded) throws -> Bool {
        guard try InstallFS.entry(loaded.descriptor, commitName) != nil else { return false }
        let bytes = try readRecord(loaded.descriptor, commitName)
        guard bytes == (try InstallFS.encode(loaded.receipt)) else { throw InstallFilesystemError.invalidAcknowledgement }
        return true
    }
    private static func finish(_ lease: InstallFilesystemLease, _ loaded: Loaded, committed: Bool,
                               fault: ((InstallFilesystemPoint) throws -> Void)?) throws -> InstallFilesystemResult {
        try fault?(.beforeFinish); try validateLoaded(lease, loaded)
        guard try acknowledgement(loaded) == committed else { throw InstallFilesystemError.changed }
        try validatePair(lease, loaded.journal, requireNew: committed, checksCancellation: !committed)
        let name = ".neantik-install-" + (committed ? "committed-" : "rolledback-") + loaded.journal.transactionID.uuidString.lowercased()
        guard renameatx_np(lease.parent, activeName, lease.parent, name, UInt32(RENAME_EXCL)) == 0 else { throw InstallFS.posix() }
        try fault?(.finalizedBeforeSync); try InstallFS.sync(lease.parent)
        guard try InstallFS.entry(lease.parent, name)?.sameObject(loaded.object) == true else { throw InstallFilesystemError.changed }
        try lease.validate(); try fault?(.finished)
        return .init(transactionID: loaded.journal.transactionID, committed: committed)
    }
}
