import CryptoKit
import Darwin
import Foundation

enum BrowserDataRestoreError: LocalizedError, Equatable {
    case pending, changed, unsupported, authorityRequired
    var errorDescription: String? {
        switch self {
        case .pending: "Восстановление данных не завершено. Закрой браузеры и заверши восстановление перед работой с профилями."
        case .changed: "Файлы изменились во время восстановления. Данные сохранены; автоматическая замена остановлена."
        case .unsupported: "Журнал восстановления имеет неподдерживаемый формат. Сохрани данные и обратись в поддержку."
        case .authorityRequired: "Перед восстановлением закрой профиль и другие версии NeAntik."
        }
    }
}

enum BrowserDataRestorePoint: String, CaseIterable {
    case beforeActivation, activated, intent, pendingPrevious, pendingMain, swapped, rollForwardRequired
    case publishedPrevious, publishedMain, restoredTree, restoredMain, restoredPrevious, beforeFinish, finished
}

/// A finite filesystem transaction, not process authority. The caller retains
/// the stopped-profile process lease THEN the global metadata guard throughout
/// commit/recovery. Recovery must re-establish that authority after a crash.
/// Earlier cached managers without persisted launch validation must be closed.
/// Finalized journals and the old tree are retained for explicit rollback QA;
/// this worker never deletes BrowserData based on a filename prefix.
enum BrowserDataRestoreTransaction {
    static let activeName = ".browser-data-restore-active"
    static let maximumDocumentBytes = 16 * 1_024 * 1_024
    private static let journalName = "journal.json"
    private static let markerSchema = 99

    struct Result: Sendable, Equatable {
        let profileID: UUID
        let restored: Bool
        let transactionID: UUID
    }
    struct RecoveryPreview: Sendable {
        let context: EncryptedBackupArchive.Manifest
        let retainedTree: URL
    }
    private struct Journal: Codable, Equatable {
        let schema: Int
        let transactionID: UUID
        let root: BackupIdentity
        let directory: BackupIdentity
        let profileID: UUID
        let profileParent: BackupIdentity
        let stageName: String
        let oldTree: BackupIdentity
        let nextTree: BackupIdentity
        let oldEntries: [EncryptedBackupArchive.Entry]
        let manifest: EncryptedBackupArchive.Manifest
        let oldMainSHA256: String
        let oldPreviousSHA256: String?
        let nextSHA256: String
        let markerSHA256: String
        let journalObject: BackupIdentity
        let metadataObjects: [String: BackupIdentity]
    }
    private struct SealedJournal: Codable {
        let journal: Journal
        let sha256: String
    }
    private struct PendingMarker: Encodable {
        let schemaVersion = markerSchema
        let profiles: [String] = []
        let state = "restorePending"
        let transactionID: UUID
    }

    /// Cheap fence checked before ordinary metadata recovery, mutation and
    /// startup directory creation. An unreadable/foreign entry also blocks.
    static func requireNoPending(rootURL: URL) throws {
        // Match AppPaths' existing root contract, including macOS /var and
        // /tmp ancestor aliases. The root itself must never be a symlink.
        let root = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw BrowserDataRestoreError.changed }
        defer { Darwin.close(root) }
        let identity = try BackupFS.identity(root)
        guard identity.directory, identity.uid == geteuid() else { throw BrowserDataRestoreError.changed }
        guard try BackupFS.entry(root, activeName) == nil else { throw BrowserDataRestoreError.pending }
    }

    /// Production entry points bind the borrowed process lease to the exact
    /// profile and retained tree from the authenticated stage/journal.
    static func commit(paths: AppPaths, stage: PreparedBrowserDataBackup,
                       expectedMain: Data, nextDocument: Data, authority: StoppedProfileRestoreAuthority,
                       validateContext: () throws -> Void = {},
                       fault: ((BrowserDataRestorePoint) throws -> Void)? = nil) throws -> Result {
        try commit(paths: paths, stage: stage, expectedMain: expectedMain, nextDocument: nextDocument,
            validateAuthority: { id, tree in
                try authority.validate(paths: paths, profileID: id, retainedTree: tree)
                try validateContext()
            }, fault: fault)
    }

    static func recover(paths: AppPaths, expectedContext: EncryptedBackupArchive.Manifest,
                        authority: StoppedProfileRestoreAuthority, validateContext: () throws -> Void = {}) throws -> Result {
        try recover(paths: paths, expectedContext: expectedContext,
            validateAuthority: { id, tree in
                try authority.validate(paths: paths, profileID: id, retainedTree: tree)
                try validateContext()
            })
    }

    // Filesystem fault-injection seam. Production callers use the typed
    // overloads above; callbacks must validate both scope arguments.
    static func commit(paths: AppPaths, stage: PreparedBrowserDataBackup,
                       expectedMain: Data, nextDocument: Data,
                       validateAuthority: (UUID, URL) throws -> Void,
                       maximumJournalBytes: Int = maximumDocumentBytes,
                       fault: ((BrowserDataRestorePoint) throws -> Void)? = nil) throws -> Result {
        guard let manifest = stage.manifest else { throw BrowserDataRestoreError.changed }
        try validateAuthority(manifest.profileID, stage.url)
        try Task.checkCancellation()
        try EncryptedBackupArchive.validate(manifest)
        let profileURL = paths.profileDirectory(for: manifest.profileID)
        guard stage.url.deletingLastPathComponent() == profileURL else { throw BrowserDataRestoreError.changed }
        try validateTransition(old: expectedMain, next: nextDocument, manifest: manifest)
        let root = try BackupFS.directory(paths.rootDirectory)
        defer { Darwin.close(root) }
        guard try BackupFS.entry(root, activeName) == nil else { throw BrowserDataRestoreError.pending }
        let mainName = paths.profilesFile.lastPathComponent, previousName = paths.profilesBackupFile.lastPathComponent
        guard try read(root, mainName) == expectedMain else { throw BrowserDataRestoreError.changed }
        let previous = try read(root, previousName)
        if let previous { _ = try ProfileStore.decodeProfiles(previous) }
        let old = try BackupTree.capture(paths.browserDataDirectory(for: manifest.profileID), excludeRootTransients: false)
        defer { old.close() }
        let oldManifest = EncryptedBackupArchive.Manifest(profileID: manifest.profileID, identitySHA256: manifest.identitySHA256,
            runtimeExecutableSHA256: manifest.runtimeExecutableSHA256, runtimeFrameworkSHA256: manifest.runtimeFrameworkSHA256,
            runtimeVersion: manifest.runtimeVersion, compatibilityScopeSHA256: manifest.compatibilityScopeSHA256, entries: old.entries)
        try EncryptedBackupArchive.validate(oldManifest)
        let next = try BackupTree.capture(stage.url, excludeRootTransients: false)
        defer { next.close() }
        try stage.validatePreparedContents()
        guard next.entries == manifest.entries, old.rootIdentity.device == next.rootIdentity.device else { throw BrowserDataRestoreError.changed }
        let profile = try BackupFS.directory(profileURL)
        defer { Darwin.close(profile) }
        let transactionID = UUID()
        let marker = try canonical(PendingMarker(transactionID: transactionID))
        try validateAuthority(manifest.profileID, stage.url)
        try Task.checkCancellation()
        guard try read(root, mainName) == expectedMain, try read(root, previousName) == previous else { throw BrowserDataRestoreError.changed }
        try old.validateAll(); try next.validateAll()
        let originalMain = try BackupFS.entry(root, mainName)
        let originalPrevious = try BackupFS.entry(root, previousName)
        guard originalMain != nil else { throw BrowserDataRestoreError.changed }
        // Serialize a conservative upper bound before creating any transaction
        // directory: two valid manifests can together exceed journal limits.
        try validateJournalBudget(old: old.entries, next: next.entries, limit: maximumJournalBytes)
        let preparingName = ".browser-data-restore-preparing-\(transactionID.uuidString.lowercased())"
        guard mkdirat(root, preparingName, 0o700) == 0 else { throw BackupFS.posix() }
        // Preparation failures remain private inactive artifacts. The active
        // fence appears only after a complete bounded, fsynced intent exists.
        let directory = openat(root, preparingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(directory) }
        var metadataObjects = ["original-main": originalMain!]
        if let originalPrevious { metadataObjects["original-previous"] = originalPrevious }
        for (name, bytes) in [("pending-main", marker), ("pending-previous", marker),
                              ("next-main", nextDocument), ("next-previous", nextDocument),
                              ("rollback-main", expectedMain), ("decision", Data(transactionID.uuidString.utf8))] {
            try publish(directory, name, bytes, allowed: [nil])
            metadataObjects[name] = try BackupFS.entry(directory, name)
        }
        if let previous {
            try publish(directory, "rollback-previous", previous, allowed: [nil])
            metadataObjects["rollback-previous"] = try BackupFS.entry(directory, "rollback-previous")
        }
        let journalFile = openat(directory, journalName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard journalFile >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(journalFile) }
        let journal = Journal(schema: 1, transactionID: transactionID, root: try BackupFS.identity(root),
            directory: try BackupFS.identity(directory), profileID: manifest.profileID,
            profileParent: try BackupFS.identity(profile), stageName: stage.url.lastPathComponent,
            oldTree: old.rootIdentity, nextTree: next.rootIdentity, oldEntries: old.entries, manifest: manifest,
            oldMainSHA256: hash(expectedMain), oldPreviousSHA256: previous.map(hash),
            nextSHA256: hash(nextDocument), markerSHA256: hash(marker), journalObject: try BackupFS.identity(journalFile), metadataObjects: metadataObjects)
        try publish(directory, "old-main.json", expectedMain, allowed: [nil])
        if let previous { try publish(directory, "old-previous.json", previous, allowed: [nil]) }
        try publish(directory, "next.json", nextDocument, allowed: [nil])
        try publish(directory, "pending.json", marker, allowed: [nil])
        let journalBytes = try canonical(SealedJournal(journal: journal, sha256: hash(try canonical(journal))))
        guard journalBytes.count <= maximumJournalBytes else { throw BrowserDataBackupStorageError.limitExceeded }
        try BackupFS.write(journalFile, journalBytes, at: 0, checksCancellation: false)
        guard fsync(journalFile) == 0, fsync(directory) == 0,
              try read(root, mainName) == expectedMain, try read(root, previousName) == previous,
              try BackupFS.entry(root, mainName) == originalMain,
              try BackupFS.entry(root, previousName) == originalPrevious else { throw BrowserDataRestoreError.changed }
        try stage.validatePreparedContents(); try old.validateAll()
        try fault?(.beforeActivation)
        try validateAuthority(manifest.profileID, stage.url)
        try BackupFS.validateDirectoryPath(paths.rootDirectory, journal.root)
        guard try BackupFS.entry(root, preparingName)?.sameObject(journal.directory) == true,
              try BackupFS.identity(directory).sameObject(journal.directory) else { throw BrowserDataRestoreError.changed }
        guard renameatx_np(root, preparingName, root, activeName, UInt32(RENAME_EXCL)) == 0 else { throw BackupFS.posix() }
        stage.transferToRestoreJournal()
        guard try BackupFS.entry(root, activeName)?.sameObject(journal.directory) == true else { throw BrowserDataRestoreError.changed }
        try fault?(.activated)
        guard fsync(root) == 0 else { throw BackupFS.posix() }
        try fault?(.intent)
        try Task.checkCancellation()
        try validateJournal(paths: paths, root: root, directory: directory, journal: journal)
        try validateAuthority(manifest.profileID, stage.url)
        try publishMetadata(root: root, directory: directory, name: previousName, state: "pending-previous", journal: journal, allowed: ["original-previous"])
        try fault?(.pendingPrevious)
        try Task.checkCancellation()
        try validateAuthority(manifest.profileID, stage.url)
        try publishMetadata(root: root, directory: directory, name: mainName, state: "pending-main", journal: journal, allowed: ["original-main"])
        try fault?(.pendingMain)
        try Task.checkCancellation()
        try validateAuthority(manifest.profileID, stage.url)
        guard try matches(root, mainName, state: "pending-main", directory: directory, journal: journal),
              try matches(root, previousName, state: "pending-previous", directory: directory, journal: journal) else { throw BrowserDataRestoreError.changed }
        try validateTrees(paths: paths, journal: journal, swapped: false)
        try validateAuthority(manifest.profileID, stage.url)
        try swap(profile, journal.stageName)
        try fault?(.swapped)
        try Task.checkCancellation()
        try validateTrees(paths: paths, journal: journal, swapped: true)
        try validateAuthority(manifest.profileID, stage.url)
        guard try BackupFS.entry(directory, "decision") == journal.metadataObjects["decision"],
              renameatx_np(directory, "decision", directory, "roll-forward-required", UInt32(RENAME_EXCL)) == 0,
              fsync(directory) == 0 else { throw BrowserDataRestoreError.changed }
        // After this durable decision cancellation cannot select rollback.
        try fault?(.rollForwardRequired)
        return try complete(paths: paths, root: root, directory: directory, journal: journal, validateAuthority: validateAuthority, fault: fault)
    }

    static func recover(paths: AppPaths, expectedContext: EncryptedBackupArchive.Manifest,
                        validateAuthority: (UUID, URL) throws -> Void,
                        fault: ((BrowserDataRestorePoint) throws -> Void)? = nil) throws -> Result {
        let preview = try inspectPending(paths: paths)
        guard preview.context.profileID == expectedContext.profileID else { throw BrowserDataRestoreError.changed }
        try validateAuthority(preview.context.profileID, preview.retainedTree)
        let root = try BackupFS.directory(paths.rootDirectory)
        defer { Darwin.close(root) }
        let directory = openat(root, activeName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BrowserDataRestoreError.pending }
        defer { Darwin.close(directory) }
        guard let bytes = try read(directory, journalName),
              let sealed = try? JSONDecoder().decode(SealedJournal.self, from: bytes),
              try canonical(sealed) == bytes, hash(try canonical(sealed.journal)) == sealed.sha256 else { throw BrowserDataRestoreError.changed }
        let journal = sealed.journal
        guard journal.schema == 1 else { throw BrowserDataRestoreError.unsupported }
        let m = journal.manifest
        guard m.profileID == expectedContext.profileID, m.identitySHA256 == expectedContext.identitySHA256,
              m.runtimeExecutableSHA256 == expectedContext.runtimeExecutableSHA256,
              m.runtimeFrameworkSHA256 == expectedContext.runtimeFrameworkSHA256,
              m.runtimeVersion == expectedContext.runtimeVersion,
              m.compatibilityScopeSHA256 == expectedContext.compatibilityScopeSHA256 else { throw BrowserDataRestoreError.changed }
        try validateJournal(paths: paths, root: root, directory: directory, journal: journal)
        return try complete(paths: paths, root: root, directory: directory, journal: journal, validateAuthority: validateAuthority, fault: fault)
    }

    /// Read-only admission input for acquiring process authority before the
    /// metadata guard. Recovery re-reads the immutable intent after both guards
    /// are held; this preview is never authority to mutate either tree.
    static func inspectPending(paths: AppPaths) throws -> RecoveryPreview {
        let root = try BackupFS.directory(paths.rootDirectory)
        defer { Darwin.close(root) }
        let directory = openat(root, activeName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BrowserDataRestoreError.pending }
        defer { Darwin.close(directory) }
        guard let bytes = try read(directory, journalName), let sealed = try? JSONDecoder().decode(SealedJournal.self, from: bytes),
              try canonical(sealed) == bytes, hash(try canonical(sealed.journal)) == sealed.sha256 else { throw BrowserDataRestoreError.changed }
        let journal = sealed.journal
        try validateJournal(paths: paths, root: root, directory: directory, journal: journal)
        try validateTransition(old: required(directory, "old-main.json", journal.oldMainSHA256),
            next: required(directory, "next.json", journal.nextSHA256), manifest: journal.manifest)
        guard try required(directory, "pending.json", journal.markerSHA256) == canonical(PendingMarker(transactionID: journal.transactionID)) else { throw BrowserDataRestoreError.changed }
        return RecoveryPreview(context: journal.manifest, retainedTree: paths.profileDirectory(for: journal.profileID).appendingPathComponent(journal.stageName))
    }

    private static func complete(paths: AppPaths, root: Int32, directory: Int32, journal: Journal,
                                 validateAuthority: (UUID, URL) throws -> Void,
                                 fault: ((BrowserDataRestorePoint) throws -> Void)?) throws -> Result {
        let retainedTree = paths.profileDirectory(for: journal.profileID).appendingPathComponent(journal.stageName)
        try validateAuthority(journal.profileID, retainedTree)
        try validateJournal(paths: paths, root: root, directory: directory, journal: journal)
        let oldMain = try required(directory, "old-main.json", journal.oldMainSHA256)
        let previous = try read(directory, "old-previous.json")
        guard previous.map(hash) == journal.oldPreviousSHA256 else { throw BrowserDataRestoreError.changed }
        let next = try required(directory, "next.json", journal.nextSHA256)
        let marker = try required(directory, "pending.json", journal.markerSHA256)
        try validateTransition(old: oldMain, next: next, manifest: journal.manifest)
        guard marker == (try canonical(PendingMarker(transactionID: journal.transactionID))) else { throw BrowserDataRestoreError.changed }
        let mainName = paths.profilesFile.lastPathComponent, previousName = paths.profilesBackupFile.lastPathComponent
        let forward = try rollForwardRequired(directory: directory, journal: journal)
        try admit(root, mainName, states: forward ? ["pending-main", "next-main"] : ["original-main", "pending-main", "rollback-main"], directory: directory, journal: journal)
        try admit(root, previousName, states: forward ? ["pending-previous", "next-previous"] : ["original-previous", "pending-previous", "rollback-previous"], directory: directory, journal: journal)
        let profile = try BackupFS.directory(paths.profileDirectory(for: journal.profileID))
        defer { Darwin.close(profile) }
        guard try BackupFS.identity(profile).sameObject(journal.profileParent) else { throw BrowserDataRestoreError.changed }
        let live = try BackupFS.entry(profile, "BrowserData")
        let staged = try BackupFS.entry(profile, journal.stageName)
        let swapped = live?.sameObject(journal.nextTree) == true && staged?.sameObject(journal.oldTree) == true
        let original = live?.sameObject(journal.oldTree) == true && staged?.sameObject(journal.nextTree) == true
        guard swapped || original, !forward || swapped else { throw BrowserDataRestoreError.changed }
        try validateTrees(paths: paths, journal: journal, swapped: swapped)
        try validateAuthority(journal.profileID, retainedTree)
        if forward {
            try validateAuthority(journal.profileID, retainedTree)
            try publishMetadata(root: root, directory: directory, name: previousName, state: "next-previous", journal: journal, allowed: ["pending-previous", "next-previous"])
            try fault?(.publishedPrevious)
            try validateAuthority(journal.profileID, retainedTree)
            try publishMetadata(root: root, directory: directory, name: mainName, state: "next-main", journal: journal, allowed: ["pending-main", "next-main"])
            try fault?(.publishedMain)
        } else {
            if swapped {
                try validateAuthority(journal.profileID, retainedTree)
                try swap(profile, journal.stageName)
            }
            try fault?(.restoredTree)
            // MAIN FIRST: old main and previous can intentionally differ.
            // Publishing previous first permits an array-only recovery reader
            // to downgrade main while it still contains a pending marker.
            try validateAuthority(journal.profileID, retainedTree)
            try publishMetadata(root: root, directory: directory, name: mainName, state: "rollback-main", journal: journal, allowed: ["original-main", "pending-main", "rollback-main"])
            try fault?(.restoredMain)
            try validateAuthority(journal.profileID, retainedTree)
            try publishMetadata(root: root, directory: directory, name: previousName, state: "rollback-previous", journal: journal, allowed: ["original-previous", "pending-previous", "rollback-previous"])
            try fault?(.restoredPrevious)
        }
        try validateTrees(paths: paths, journal: journal, swapped: forward)
        try validateJournal(paths: paths, root: root, directory: directory, journal: journal)
        try admit(root, mainName, states: forward ? ["next-main"] : ["rollback-main"], directory: directory, journal: journal)
        try admit(root, previousName, states: forward ? ["next-previous"] : ["rollback-previous"], directory: directory, journal: journal)
        // Atomic removal of the fence preserves exact metadata, intent and
        // old tree for later explicitly scoped rollback/retention decisions.
        let receipt = ".browser-data-restore-\(journal.transactionID.uuidString.lowercased()).\(forward ? "committed" : "rolled-back")"
        try fault?(.beforeFinish)
        try validateJournal(paths: paths, root: root, directory: directory, journal: journal)
        try admit(root, mainName, states: forward ? ["next-main"] : ["rollback-main"], directory: directory, journal: journal)
        try admit(root, previousName, states: forward ? ["next-previous"] : ["rollback-previous"], directory: directory, journal: journal)
        try validateAuthority(journal.profileID, retainedTree)
        guard renameatx_np(root, activeName, root, receipt, UInt32(RENAME_EXCL)) == 0 else { throw BackupFS.posix() }
        guard try BackupFS.entry(root, receipt)?.sameObject(journal.directory) == true else {
            // A non-cooperating local writer raced the source name. Do not
            // accept the moved foreign entry or delete it; retain a fence if
            // its rename removed the active name.
            _ = mkdirat(root, activeName, 0o700); _ = fsync(root)
            throw BrowserDataRestoreError.changed
        }
        guard fsync(root) == 0 else { throw BackupFS.posix() }
        try fault?(.finished)
        return Result(profileID: journal.profileID, restored: forward, transactionID: journal.transactionID)
    }

    private static func validateTrees(paths: AppPaths, journal: Journal, swapped: Bool) throws {
        let parentURL = paths.profileDirectory(for: journal.profileID)
        let parent = try BackupFS.directory(parentURL)
        defer { Darwin.close(parent) }
        guard try BackupFS.identity(parent).sameObject(journal.profileParent) else { throw BrowserDataRestoreError.changed }
        for (name, identity, entries) in [
            ("BrowserData", swapped ? journal.nextTree : journal.oldTree, swapped ? journal.manifest.entries : journal.oldEntries),
            (journal.stageName, swapped ? journal.oldTree : journal.nextTree, swapped ? journal.oldEntries : journal.manifest.entries)
        ] {
            let tree = try BackupTree.capture(parentURL.appendingPathComponent(name), checksCancellation: false, excludeRootTransients: false)
            defer { tree.close() }
            guard tree.rootIdentity.sameObject(identity), tree.entries == entries else { throw BrowserDataRestoreError.changed }
            try tree.validateAll()
        }
    }
    private static func validateJournal(paths: AppPaths, root: Int32, directory: Int32, journal: Journal) throws {
        try BackupFS.validateDirectoryPath(paths.rootDirectory, journal.root)
        guard journal.schema == 1, journal.profileID == journal.manifest.profileID,
              journal.stageName.hasPrefix(".neantik-backup-restore-"),
              try BackupFS.identity(root).sameObject(journal.root),
              try BackupFS.identity(directory).sameObject(journal.directory),
              try BackupFS.entry(root, activeName)?.sameObject(journal.directory) == true,
              try BackupFS.entry(directory, journalName)?.sameObject(journal.journalObject) == true,
              try read(directory, journalName) == canonical(SealedJournal(journal: journal, sha256: hash(try canonical(journal)))) else { throw BrowserDataRestoreError.changed }
        try BackupFS.validateName(journal.stageName)
        try EncryptedBackupArchive.validate(journal.manifest)
        let base: Set<String> = journal.oldPreviousSHA256 == nil ? ["journal.json", "next.json", "old-main.json", "pending.json"] :
            ["journal.json", "next.json", "old-main.json", "old-previous.json", "pending.json"]
        let images: Set<String> = ["pending-main", "pending-previous", "next-main", "next-previous", "rollback-main", "rollback-previous", "decision", "roll-forward-required"]
        let names = Set(try BackupFS.names(directory))
        guard names.isSuperset(of: base), names.isSubset(of: base.union(images)),
              Set(journal.metadataObjects.keys) == (journal.oldPreviousSHA256 == nil ?
                ["original-main", "pending-main", "pending-previous", "next-main", "next-previous", "rollback-main", "decision"] :
                ["original-main", "original-previous", "pending-main", "pending-previous", "next-main", "next-previous", "rollback-main", "rollback-previous", "decision"]) else { throw BrowserDataRestoreError.changed }
        _ = try rollForwardRequired(directory: directory, journal: journal)
    }
    private static func validateTransition(old: Data, next: Data, manifest: EncryptedBackupArchive.Manifest) throws {
        let before = try ProfileStore.decodeProfiles(old), after = try ProfileStore.decodeProfiles(next)
        guard before.count == after.count, Set(before.map(\.id)).count == before.count,
              before.map(\.id) == after.map(\.id), let index = before.firstIndex(where: { $0.id == manifest.profileID }),
              before[index].revision < UInt64.max,
              after[index].revision == before[index].revision + 1,
              after[index].updatedAt >= before[index].updatedAt else { throw BrowserDataRestoreError.changed }
        var expected = before
        expected[index].revision = after[index].revision
        expected[index].updatedAt = after[index].updatedAt
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard expected == after, hash(try encoder.encode(before[index].identity)) == manifest.identitySHA256 else { throw BrowserDataRestoreError.changed }
    }
    static func validateJournalBudget(old: [EncryptedBackupArchive.Entry], next: [EncryptedBackupArchive.Entry], limit: Int = maximumDocumentBytes) throws {
        // Quotes in path components need escaping; 220 also bounds each
        // entry's fixed JSON keys, hash and UInt64 size. Private identities and
        // context/decision fields fit within the remaining 16 KiB allowance.
        let bound = next.reduce(0) { $0 + $1.path.utf8.count * 2 + 220 } + old.reduce(0) { $0 + $1.path.utf8.count * 2 + 220 } + 16_384
        guard limit >= 16_384, limit <= maximumDocumentBytes, bound <= limit else { throw BrowserDataBackupStorageError.limitExceeded }
    }
    private static func rollForwardRequired(directory: Int32, journal: Journal) throws -> Bool {
        let prepared = try BackupFS.entry(directory, "decision"), committed = try BackupFS.entry(directory, "roll-forward-required")
        guard let identity = journal.metadataObjects["decision"], (prepared == nil) != (committed == nil),
              (prepared ?? committed)?.sameObject(identity) == true,
              try read(directory, prepared == nil ? "roll-forward-required" : "decision") == Data(journal.transactionID.uuidString.utf8) else { throw BrowserDataRestoreError.changed }
        return committed != nil
    }
    private static func stateBytes(_ state: String, directory: Int32, journal: Journal) throws -> Data? {
        if state == "original-main" || state == "rollback-main" { return try required(directory, "old-main.json", journal.oldMainSHA256) }
        if state == "original-previous" || state == "rollback-previous" {
            return try journal.oldPreviousSHA256.map { try required(directory, "old-previous.json", $0) }
        }
        if state.hasPrefix("pending-") { return try required(directory, "pending.json", journal.markerSHA256) }
        if state.hasPrefix("next-") { return try required(directory, "next.json", journal.nextSHA256) }
        throw BrowserDataRestoreError.changed
    }
    private static func matches(_ root: Int32, _ name: String, state: String, directory: Int32, journal: Journal) throws -> Bool {
        let object = try BackupFS.entry(root, name), expected = journal.metadataObjects[state]
        guard object == nil ? expected == nil : (expected.map { object!.sameObject($0) } ?? false) else { return false }
        return try read(root, name) == stateBytes(state, directory: directory, journal: journal)
    }
    private static func admit(_ root: Int32, _ name: String, states: [String], directory: Int32, journal: Journal) throws {
        for state in states { if try matches(root, name, state: state, directory: directory, journal: journal) { return } }
        throw BrowserDataRestoreError.changed
    }
    private static func publishMetadata(root: Int32, directory: Int32, name: String, state: String, journal: Journal, allowed: [String]) throws {
        try admit(root, name, states: allowed, directory: directory, journal: journal)
        if try matches(root, name, state: state, directory: directory, journal: journal) { return }
        let bytes = try stateBytes(state, directory: directory, journal: journal)
        if let bytes {
            guard let identity = journal.metadataObjects[state],
                  try BackupFS.entry(directory, state)?.sameObject(identity) == true,
                  try read(directory, state) == bytes else { throw BrowserDataRestoreError.changed }
            try admit(root, name, states: allowed, directory: directory, journal: journal)
            guard renameat(directory, state, root, name) == 0 else { throw BackupFS.posix() }
        } else {
            try admit(root, name, states: allowed, directory: directory, journal: journal)
            guard unlinkat(root, name, 0) == 0 else { throw BackupFS.posix() }
        }
        guard fsync(root) == 0, fsync(directory) == 0,
              try matches(root, name, state: state, directory: directory, journal: journal) else { throw BrowserDataRestoreError.changed }
    }
    private static func swap(_ parent: Int32, _ stage: String) throws {
        guard renameatx_np(parent, "BrowserData", parent, stage, UInt32(RENAME_SWAP)) == 0,
              fsync(parent) == 0 else { throw BackupFS.posix() }
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func hash(_ bytes: Data) -> String { BackupFS.hex(SHA256.hash(data: bytes)) }
    private static func required(_ directory: Int32, _ name: String, _ digest: String) throws -> Data {
        guard let bytes = try read(directory, name), hash(bytes) == digest else { throw BrowserDataRestoreError.changed }
        return bytes
    }
    /// Reads only bounded, owned, private regular files without following
    /// links; revalidates both descriptor and directory entry after reading.
    private static func read(_ directory: Int32, _ name: String) throws -> Data? {
        try BackupFS.validateName(name)
        guard let before = try BackupFS.entry(directory, name) else { return nil }
        try before.validateFile(device: nil)
        guard before.mode & 0o077 == 0, before.size <= maximumDocumentBytes else { throw BrowserDataRestoreError.changed }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(file) }
        guard try BackupFS.identity(file) == before else { throw BrowserDataRestoreError.changed }
        var bytes = Data(), offset: Int64 = 0
        while offset < before.size {
            let part = try BackupFS.read(file, at: offset, count: Int(min(before.size - offset, 1_024 * 1_024)), checksCancellation: false)
            guard !part.isEmpty else { throw BrowserDataRestoreError.changed }
            bytes.append(part); offset += Int64(part.count)
        }
        guard try BackupFS.identity(file) == before, try BackupFS.entry(directory, name) == before else { throw BrowserDataRestoreError.changed }
        return bytes
    }
    /// Same-directory atomic replacement, exact old-byte admission, file and
    /// directory fsync. Recovery finishes bounded IO even in a cancelled task.
    private static func publish(_ directory: Int32, _ name: String, _ bytes: Data?, allowed: [Data?]) throws {
        let old = try read(directory, name)
        guard allowed.contains(old) else { throw BrowserDataRestoreError.changed }
        if old == bytes { return }
        guard let bytes else {
            guard try read(directory, name) == old, unlinkat(directory, name, 0) == 0, fsync(directory) == 0 else { throw BrowserDataRestoreError.changed }
            return
        }
        guard bytes.count <= maximumDocumentBytes else { throw BrowserDataRestoreError.changed }
        let temporary = ".restore-write-\(UUID().uuidString.lowercased())"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw BackupFS.posix() }
        defer { Darwin.close(file) }
        let identity = try BackupFS.identity(file)
        var published = false
        defer { if !published, (try? BackupFS.entry(directory, temporary))?.sameObject(identity) == true { _ = unlinkat(directory, temporary, 0) } }
        try BackupFS.write(file, bytes, at: 0, checksCancellation: false)
        guard fsync(file) == 0, try BackupFS.entry(directory, temporary)?.sameObject(identity) == true,
              try read(directory, name) == old else { throw BrowserDataRestoreError.changed }
        guard renameat(directory, temporary, directory, name) == 0 else { throw BackupFS.posix() }
        published = true
        guard fsync(directory) == 0 else { throw BackupFS.posix() }
    }
}
