import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

struct BrowserDataRestoreTransactionTests {
    private let fs = FileManager.default
    private let password = "owned restore fixture password"
    private struct Fixture {
        let paths: AppPaths
        let profile: BrowserProfile
        let context: EncryptedBackupArchive.Manifest
        let stage: PreparedBrowserDataBackup
        let main: Data
        let previous: Data
        let next: Data
        var data: URL { paths.browserDataDirectory(for: profile.id).appendingPathComponent("Default/Cookies") }
    }
    private enum Interrupted: Error { case simulatedCrash }

    @Test func atomicRestorePublishesNewRevisionAndPreservesOldTree() throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        let result = try commit(f)
        #expect(result.restored && result.profileID == f.profile.id)
        #expect(try Data(contentsOf: f.data) == Data("backup value".utf8))
        #expect(try Data(contentsOf: f.stage.url.appendingPathComponent("Default/Cookies")) == Data("newer live value".utf8))
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.next)
        #expect(try Data(contentsOf: f.paths.profilesBackupFile) == f.next)
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory)
        // The preparer lost cleanup ownership before swap. It must not remove
        // the old live tree now occupying its original URL.
        try f.stage.discard()
        #expect(fs.fileExists(atPath: f.stage.url.path))
        #expect(try fs.contentsOfDirectory(atPath: f.paths.rootDirectory.path).contains(where: { $0.hasSuffix(".committed") }))
    }

    @Test(arguments: [BrowserDataRestorePoint.pendingPrevious, .swapped, .rollForwardRequired, .publishedPrevious, .beforeFinish])
    func lateAuthorityLossStopsPublicationAndPreservesRecoveryFence(point: BrowserDataRestorePoint) throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        var authorityLost = false
        #expect(throws: BrowserDataRestoreError.authorityRequired) {
            try BrowserDataRestoreTransaction.commit(paths: f.paths, stage: f.stage, expectedMain: f.main, nextDocument: f.next,
                validateAuthority: { _, _ in if authorityLost { throw BrowserDataRestoreError.authorityRequired } },
                fault: { if $0 == point { authorityLost = true } })
        }
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory) }
        if point == .publishedPrevious {
            #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(Data(contentsOf: f.paths.profilesFile)) }
        }
        let result = try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in })
        let forward = [BrowserDataRestorePoint.rollForwardRequired, .publishedPrevious, .beforeFinish].contains(point)
        #expect(result.restored == forward)
        #expect(try Data(contentsOf: f.paths.profilesFile) == (forward ? f.next : f.main))
        #expect(try Data(contentsOf: f.data) == Data((forward ? "backup value" : "newer live value").utf8))
    }

    @Test func lateAuthorityLossDuringRollbackKeepsMetadataPendingUntilFreshRecovery() throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .swapped { throw Interrupted.simulatedCrash } } }
        var authorityLost = false
        #expect(throws: BrowserDataRestoreError.authorityRequired) {
            try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context,
                validateAuthority: { _, _ in if authorityLost { throw BrowserDataRestoreError.authorityRequired } },
                fault: { if $0 == .restoredTree { authorityLost = true } })
        }
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(Data(contentsOf: f.paths.profilesFile)) }
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory) }
        let result = try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in })
        #expect(!result.restored)
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.main)
    }

    @Test func activationDirectoryFsyncFailureTransfersCleanupOwnershipBeforeThrowing() throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: POSIXError(.EIO)) { try commit(f) { if $0 == .activated { throw POSIXError(.EIO) } } }
        // Caller cancellation/error cleanup must not remove the next tree once
        // an active intent is visible, even if its parent fsync failed.
        try f.stage.discard()
        #expect(fs.fileExists(atPath: f.stage.url.path))
        let result = try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in })
        #expect(!result.restored)
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.main)
        #expect(try Data(contentsOf: f.data) == Data("newer live value".utf8))
    }

    @Test(arguments: ["activation", "finish"])
    func directoryNamespaceSubstitutionRefusesBeforeRename(kind: String) throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        var foreign: URL?
        #expect(throws: BrowserDataRestoreError.changed) {
            try commit(f) { point in
                guard point == (kind == "activation" ? .beforeActivation : .beforeFinish) else { return }
                let name: String
                if kind == "activation" { name = try #require(fs.contentsOfDirectory(atPath: f.paths.rootDirectory.path).first(where: { $0.hasPrefix(".browser-data-restore-preparing-") })) }
                else { name = BrowserDataRestoreTransaction.activeName }
                let location = f.paths.rootDirectory.appendingPathComponent(name)
                try fs.moveItem(at: location, to: f.paths.rootDirectory.appendingPathComponent("retained-original-journal"))
                try fs.createDirectory(at: location, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let sentinel = location.appendingPathComponent("foreign-sentinel"); try Data("preserve foreign directory".utf8).write(to: sentinel)
                foreign = sentinel
            }
        }
        #expect(try Data(contentsOf: #require(foreign)) == Data("preserve foreign directory".utf8))
        if kind == "activation" {
            try f.stage.discard()
            try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory)
            #expect(try Data(contentsOf: f.data) == Data("newer live value".utf8))
        } else {
            #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory) }
            #expect(try Data(contentsOf: f.data) == Data("backup value".utf8))
        }
    }

    @Test(arguments: [BrowserDataRestorePoint.intent, .pendingPrevious, .pendingMain, .swapped,
                      .rollForwardRequired, .publishedPrevious, .publishedMain])
    func everyDurableInterruptionRecoversWithoutMixedMetadata(point: BrowserDataRestorePoint) throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == point { throw Interrupted.simulatedCrash } } }
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory) }
        let result = try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in })
        let forward = [BrowserDataRestorePoint.rollForwardRequired, .publishedPrevious, .publishedMain].contains(point)
        #expect(result.restored == forward)
        #expect(try Data(contentsOf: f.data) == Data((forward ? "backup value" : "newer live value").utf8))
        #expect(try Data(contentsOf: f.paths.profilesFile) == (forward ? f.next : f.main))
        #expect(try Data(contentsOf: f.paths.profilesBackupFile) == (forward ? f.next : f.previous))
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory)
    }

    @Test(arguments: [BrowserDataRestorePoint.restoredTree, .restoredMain, .restoredPrevious])
    func interruptedRollbackResumesAndNeverDowngradesMain(point: BrowserDataRestorePoint) throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .swapped { throw Interrupted.simulatedCrash } } }
        #expect(throws: Interrupted.simulatedCrash) {
            try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in }, fault: { if $0 == point { throw Interrupted.simulatedCrash } })
        }
        if point != .restoredTree {
            #expect(try Data(contentsOf: f.paths.profilesFile) == f.main)
        }
        let result = try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in })
        #expect(!result.restored)
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.main)
        #expect(try Data(contentsOf: f.paths.profilesBackupFile) == f.previous)
        #expect(try Data(contentsOf: f.data) == Data("newer live value".utf8))
    }

    @Test(arguments: ["main", "previous", "live-file", "stage-file", "journal", "root", "stage-inode"])
    func unknownChangesArePreservedAndKeepFence(kind: String) throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .swapped { throw Interrupted.simulatedCrash } } }
        let sentinel = Data("foreign owned-fixture bytes".utf8)
        var changedURL: URL?
        switch kind {
        case "main": changedURL = f.paths.profilesFile
        case "previous": changedURL = f.paths.profilesBackupFile
        case "live-file": changedURL = f.data
        case "stage-file": changedURL = f.stage.url.appendingPathComponent("Default/Cookies")
        case "journal": changedURL = f.paths.rootDirectory.appendingPathComponent(BrowserDataRestoreTransaction.activeName + "/journal.json")
        case "root":
            let moved = f.paths.rootDirectory.appendingPathExtension("retained")
            try fs.moveItem(at: f.paths.rootDirectory, to: moved)
            defer { try? fs.removeItem(at: moved) }
            try fs.createDirectory(at: f.paths.rootDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            #expect(throws: (any Error).self) { try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in }) }
            #expect(fs.fileExists(atPath: moved.appendingPathComponent(BrowserDataRestoreTransaction.activeName).path))
            return
        default:
            let moved = f.stage.url.appendingPathExtension("retained")
            try fs.moveItem(at: f.stage.url, to: moved)
            try fs.createDirectory(at: f.stage.url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        if let changedURL { try sentinel.write(to: changedURL) }
        #expect(throws: (any Error).self) { try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in }) }
        if let changedURL { #expect(try Data(contentsOf: changedURL) == sentinel) }
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory) }
    }

    @Test func mismatchedContextAndAuthorityRefuseBeforeWrites() throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: BrowserDataRestoreError.authorityRequired) {
            try BrowserDataRestoreTransaction.commit(paths: f.paths, stage: f.stage, expectedMain: f.main, nextDocument: f.next,
                validateAuthority: { _, _ in throw BrowserDataRestoreError.authorityRequired })
        }
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.main)
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .swapped { throw Interrupted.simulatedCrash } } }
        let wrong = EncryptedBackupArchive.Manifest(profileID: f.profile.id, identitySHA256: String(repeating: "f", count: 64),
            runtimeExecutableSHA256: f.context.runtimeExecutableSHA256, runtimeFrameworkSHA256: f.context.runtimeFrameworkSHA256,
            runtimeVersion: f.context.runtimeVersion, compatibilityScopeSHA256: f.context.compatibilityScopeSHA256, entries: [])
        #expect(throws: BrowserDataRestoreError.changed) { try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: wrong, validateAuthority: { _, _ in }) }
        #expect(try Data(contentsOf: f.data) == Data("backup value".utf8))
    }

    @Test(arguments: ["main", "previous"])
    func identicalBytesForeignMetadataInodeMustNotBeAdopted(kind: String) throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        let target = kind == "main" ? f.paths.profilesFile : f.paths.profilesBackupFile
        #expect(throws: Interrupted.simulatedCrash) {
            try commit(f) { if $0 == .swapped {
                let temporary = f.paths.rootDirectory.appendingPathComponent("foreign-identical")
                try Data(contentsOf: target).write(to: temporary)
                try fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                try #require(rename(temporary.path, target.path) == 0)
                throw Interrupted.simulatedCrash
            } }
        }
        #expect(throws: BrowserDataRestoreError.changed) { try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in }) }
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory) }
    }

    @Test(arguments: ["forward-main", "forward-previous", "rollback-main", "rollback-previous"])
    func finalMetadataMutationMustKeepFence(kind: String) throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        let sentinel = Data("foreign final bytes".utf8)
        let target = kind.hasSuffix("main") ? f.paths.profilesFile : f.paths.profilesBackupFile
        if kind.hasPrefix("forward") {
            #expect(throws: (any Error).self) {
                try commit(f) { if $0 == .publishedMain { try sentinel.write(to: target) } }
            }
        } else {
            #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .swapped { throw Interrupted.simulatedCrash } } }
            #expect(throws: (any Error).self) {
                try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in }, fault: {
                    if $0 == .restoredPrevious { try sentinel.write(to: target) }
                })
            }
        }
        #expect(try Data(contentsOf: target) == sentinel)
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory) }
    }

    @Test func metadataChangesBeyondRevisionAndTimeAreRefused() throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        var wrong = try ProfileStore.decodeProfiles(f.next)
        wrong[0].name = "changed by restore"
        #expect(throws: BrowserDataRestoreError.changed) {
            try BrowserDataRestoreTransaction.commit(paths: f.paths, stage: f.stage, expectedMain: f.main, nextDocument: encode(wrong), validateAuthority: { _, _ in })
        }
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.main)
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory)
    }

    @Test func journalBudgetRefusesBeforeActiveFenceAndCombinedManifestsAreBounded() throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: BrowserDataBackupStorageError.limitExceeded) {
            try BrowserDataRestoreTransaction.commit(paths: f.paths, stage: f.stage, expectedMain: f.main,
                nextDocument: f.next, validateAuthority: { _, _ in }, maximumJournalBytes: 16_384)
        }
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory)
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.main)
        #expect(try Data(contentsOf: f.data) == Data("newer live value".utf8))
        #expect(try fs.contentsOfDirectory(atPath: f.paths.rootDirectory.path).filter { $0.hasPrefix(".browser-data-restore") }.isEmpty)
        try f.stage.validatePreparedContents()
        let emptyHash = BackupFS.hex(SHA256.hash(data: Data()))
        let entries = (0..<35_000).map {
            EncryptedBackupArchive.Entry(path: String(format: "%05d-", $0) + String(repeating: "x", count: 214), kind: .file, size: 0, sha256: emptyHash)
        }
        let manifest = EncryptedBackupArchive.Manifest(profileID: f.context.profileID, identitySHA256: f.context.identitySHA256,
            runtimeExecutableSHA256: f.context.runtimeExecutableSHA256, runtimeFrameworkSHA256: f.context.runtimeFrameworkSHA256,
            runtimeVersion: f.context.runtimeVersion, compatibilityScopeSHA256: f.context.compatibilityScopeSHA256, entries: entries)
        try EncryptedBackupArchive.validate(manifest)
        let actualManifestBytes = try JSONEncoder().encode(manifest)
        #expect(actualManifestBytes.count < EncryptedBackupArchive.maximumManifestBytes)
        #expect(actualManifestBytes.count * 2 > BrowserDataRestoreTransaction.maximumDocumentBytes)
        #expect(throws: BrowserDataBackupStorageError.limitExceeded) { try BrowserDataRestoreTransaction.validateJournalBudget(old: entries, next: entries) }
        try BrowserDataRestoreTransaction.validateJournalBudget(old: [], next: [])
    }

    @Test func readOnlyAndCachedStoresRefusePendingBeforeStampFastPath() async throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        let cached = await ProfileStore(paths: f.paths, readOnlyMetadata: true)
        try await cached.refreshExternalMetadata(force: true)
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .intent { throw Interrupted.simulatedCrash } } }
        do { try await cached.refreshExternalMetadata(); Issue.record("Cached metadata bypassed pending restore") }
        catch { #expect(error as? BrowserDataRestoreError == .pending) }
        #expect(await cached.hasTrustedMetadata == false)
        #expect(await cached.lastError != nil)
        let other = await ProfileStore(paths: f.paths, readOnlyMetadata: true)
        #expect(await other.profiles.isEmpty)
        #expect(await other.lastError != nil)
        // Recovery restores the original bytes and stamps. A forced reread
        // must follow the failure, even when those stamps are unchanged.
        _ = try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, validateAuthority: { _, _ in })
        try await cached.refreshExternalMetadata()
        #expect(await cached.hasTrustedMetadata)
        #expect(await cached.hasTrustedOrganization)
        #expect(await cached.profiles.count == 1)
        #expect(await cached.lastError == nil)
    }

    @Test(arguments: [BrowserDataRestorePoint.swapped, .rollForwardRequired])
    @MainActor func immutablePreviewAndFreshRestoreAuthorityRecoverPendingMetadata(point: BrowserDataRestorePoint) async throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == point { throw Interrupted.simulatedCrash } } }
        let preview = try BrowserDataRestoreTransaction.inspectPending(paths: f.paths)
        #expect(preview.context.profileID == f.profile.id && preview.context.identitySHA256 == f.context.identitySHA256)
        #expect(preview.retainedTree == f.stage.url)
        let manager = BrowserProcessManager(paths: f.paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
            processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let result = try await manager.withVerifiedStoppedProfileRestore(profileID: preview.context.profileID, retainedTree: preview.retainedTree) { authority in
            try f.paths.withProfilesMetadataGuardForRestore(authority: authority) {
                try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, authority: authority)
            }
        }
        #expect(result.restored == (point == .rollForwardRequired))
        #expect(try Data(contentsOf: f.paths.profilesFile) == (result.restored ? f.next : f.main))
        #expect(try Data(contentsOf: f.data) == Data((result.restored ? "backup value" : "newer live value").utf8))
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory)
    }

    @Test @MainActor func typedCommitAcceptsSameDirectoryWithDifferentURLDirectoryHint() async throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        let retained = f.paths.profileDirectory(for: f.profile.id).appendingPathComponent(f.stage.url.lastPathComponent, isDirectory: false)
        #expect(retained.path == f.stage.url.path)
        let manager = BrowserProcessManager(paths: f.paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
            processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let result = try await manager.withVerifiedStoppedProfileRestore(profileID: f.profile.id, retainedTree: retained) { authority in
            try f.paths.withProfilesMetadataGuardForRestore(authority: authority) {
                try BrowserDataRestoreTransaction.commit(paths: f.paths, stage: f.stage, expectedMain: f.main, nextDocument: f.next, authority: authority)
            }
        }
        #expect(result.restored)
        #expect(try Data(contentsOf: f.data) == Data("backup value".utf8))
    }

    @Test(arguments: ["other-profile", "other-stage"])
    @MainActor func typedAuthorityCannotBeReusedForAnotherRestoreScope(kind: String) async throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        let authorizedID = kind == "other-profile" ? UUID() : f.profile.id
        if authorizedID != f.profile.id { try f.paths.prepareProfileDirectories(for: authorizedID) }
        let authorizedTree = f.paths.profileDirectory(for: authorizedID).appendingPathComponent(".neantik-backup-restore-" + UUID().uuidString.lowercased())
        let manager = BrowserProcessManager(paths: f.paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
            processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        // A different target's process lease remains held. The authority is
        // valid for its own scope; it must refuse before touching this target.
        let targetLease = authorizedID != f.profile.id ? try f.paths.acquireProcessMaintenanceGuard(for: f.profile.id) : nil
        defer { targetLease?.release() }
        do {
            _ = try await manager.withVerifiedStoppedProfileRestore(profileID: authorizedID, retainedTree: authorizedTree) { authority in
                try f.paths.withProfilesMetadataGuardForRestore(authority: authority) {
                    try BrowserDataRestoreTransaction.commit(paths: f.paths, stage: f.stage, expectedMain: f.main, nextDocument: f.next, authority: authority)
                }
            }
            Issue.record("Authority was reused for a foreign restore scope")
        } catch { #expect(error as? BrowserDataRestoreError == .authorityRequired) }
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.main)
        #expect(try Data(contentsOf: f.data) == Data("newer live value".utf8))
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory)
        // Recovery is bound independently to the journal's actual scope.
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .swapped { throw Interrupted.simulatedCrash } } }
        do {
            _ = try await manager.withVerifiedStoppedProfileRestore(profileID: authorizedID, retainedTree: authorizedTree) { authority in
                try f.paths.withProfilesMetadataGuardForRestore(authority: authority) {
                    try BrowserDataRestoreTransaction.recover(paths: f.paths, expectedContext: f.context, authority: authority)
                }
            }
            Issue.record("Authority was reused for a foreign recovery scope")
        } catch { #expect(error as? BrowserDataRestoreError == .authorityRequired) }
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: f.paths.rootDirectory) }
        #expect(try Data(contentsOf: f.data) == Data("backup value".utf8))
    }

    @Test func arrayOnlyHistoricalControlRejectsBothMarkersAndDetectsWrongOrder() throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .pendingMain { throw Interrupted.simulatedCrash } } }
        let pendingMain = try Data(contentsOf: f.paths.profilesFile)
        let pendingPrevious = try Data(contentsOf: f.paths.profilesBackupFile)
        // Independent model of the reviewed array-only decoder/fallback. This
        // is a sensitivity control, not a claim that an old binary was run.
        func oldArrayReader(_ main: Data, _ previous: Data) throws -> [BrowserProfile] {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            do { return try decoder.decode([BrowserProfile].self, from: main) }
            catch is DecodingError { return try decoder.decode([BrowserProfile].self, from: previous) }
        }
        #expect(throws: (any Error).self) { try oldArrayReader(pendingMain, pendingPrevious) }
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(pendingMain) }
        let badOrderControl = try oldArrayReader(pendingMain, f.previous)
        #expect(badOrderControl[0].revision == 7 && badOrderControl[0].revision != f.profile.revision)
        #expect(try oldArrayReader(f.main, pendingPrevious)[0].revision == f.profile.revision)
    }

    @Test func durableForwardDecisionIgnoresTaskCancellationAndCannotRollback() async throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        let task = Task {
            try commit(f) { if $0 == .rollForwardRequired { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        let result = try await task.value
        #expect(result.restored)
        #expect(try Data(contentsOf: f.paths.profilesFile) == f.next)
        #expect(try Data(contentsOf: f.data) == Data("backup value".utf8))
    }

    @Test func pendingBarrierCoversOrdinaryReadsCreationAndMCP() throws {
        let f = try fixture(); defer { try? fs.removeItem(at: f.paths.rootDirectory) }
        #expect(throws: Interrupted.simulatedCrash) { try commit(f) { if $0 == .intent { throw Interrupted.simulatedCrash } } }
        #expect(throws: BrowserDataRestoreError.pending) { try f.paths.withProfilesMetadataGuard {} }
        #expect(throws: BrowserDataRestoreError.pending) { try ProfileStore.readProfilesWithRecovery(paths: f.paths) }
        let other = UUID()
        #expect(throws: BrowserDataRestoreError.pending) { try f.paths.prepareProfileDirectories(for: other) }
        #expect(!fs.fileExists(atPath: f.paths.browserDataDirectory(for: other).path))
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "workspace_list_profiles", "arguments": [:]]]
        let reply = try #require(MCPStdioServer.handle(JSONSerialization.data(withJSONObject: request), dataRoot: f.paths.rootDirectory))
        let object = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect((object["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(!String(decoding: reply, as: UTF8.self).contains("fixture profile"))
    }

    private func commit(_ fixture: Fixture, fault: ((BrowserDataRestorePoint) throws -> Void)? = nil) throws -> BrowserDataRestoreTransaction.Result {
        try BrowserDataRestoreTransaction.commit(paths: fixture.paths, stage: fixture.stage,
            expectedMain: fixture.main, nextDocument: fixture.next, validateAuthority: { _, _ in }, fault: fault)
    }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-restore-transaction-\(UUID())", isDirectory: true)
        let paths = AppPaths(rootDirectory: root); try paths.prepareBaseDirectories()
        var profile = BrowserProfile(name: "fixture profile")
        profile.revision = 8; profile.updatedAt = Date(timeIntervalSince1970: 1000)
        try paths.prepareProfileDirectories(for: profile.id)
        let folder = paths.browserDataDirectory(for: profile.id).appendingPathComponent("Default")
        try fs.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("Cookies")
        try Data("backup value".utf8).write(to: file); try fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let identityEncoder = JSONEncoder(); identityEncoder.outputFormatting = [.sortedKeys]
        let context = EncryptedBackupArchive.Manifest(profileID: profile.id,
            identitySHA256: BackupFS.hex(SHA256.hash(data: try identityEncoder.encode(profile.identity))),
            runtimeExecutableSHA256: String(repeating: "1", count: 64), runtimeFrameworkSHA256: String(repeating: "2", count: 64),
            runtimeVersion: "156.0.8078.12", compatibilityScopeSHA256: String(repeating: "3", count: 64), entries: [])
        let archive = root.appendingPathComponent("own.nabackup")
        _ = try BrowserDataBackupStorage.export(browserData: paths.browserDataDirectory(for: profile.id), context: context, destination: archive, password: password)
        let stage = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: paths.profileDirectory(for: profile.id), expectedContext: context, password: password)
        try Data("newer live value".utf8).write(to: file)
        let main = try encode([profile])
        var older = profile; older.name = "older metadata"; older.revision = 7
        let previous = try encode([older])
        var next = profile; next.revision += 1; next.updatedAt = Date(timeIntervalSince1970: 2000)
        let nextBytes = try encode([next])
        try paths.writePrivateFile(main, to: paths.profilesFile)
        try paths.writePrivateFile(previous, to: paths.profilesBackupFile)
        return Fixture(paths: paths, profile: profile, context: context, stage: stage, main: main, previous: previous, next: nextBytes)
    }
    private func encode(_ profiles: [BrowserProfile]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(profiles)
    }
}
