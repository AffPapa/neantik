import Foundation
import Testing
@testable import NeAntik

private enum OwnDeletionFault: Error { case injected }
@MainActor private final class OwnDeletionCallback {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; started = true } }
    func finish() { continuation?.resume(); continuation = nil }
}

@Suite(.serialized) @MainActor struct WebKitProfileDeletionTests {
    private func fixture(failMetadata: @escaping () throws -> Void = {}, failAfterMetadata: @escaping () throws -> Void = {}) throws -> (URL, AppPaths, ProfileStore, BrowserProfile, BrowserProfile, BrowserProcessManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-owned-wk-deletion-\(UUID())").resolvingSymlinksInPath()
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths, trashDirectory: { source in
            let trash = root.appendingPathComponent("OwnTrash-\(UUID())")
            try FileManager.default.moveItem(at: source, to: trash)
            return trash
        }, beforeDeleteMetadataPersist: failMetadata, afterDeleteMetadataPersist: failAfterMetadata)
        let a = try store.upsert(BrowserProfile(name: "Own WK delete A", startupMode: .restoreSession, engine: .webkit))
        let b = try store.upsert(BrowserProfile(name: "Own WK preserve B", startupMode: .restoreSession, engine: .webkit))
        for profile in [a,b] {
            try WebKitSessionStore(paths: paths).save(.capture(profileID: profile.id, urls: ["https://example.test/owned"], selectedIndex: 0))
        }
        let manager = BrowserProcessManager(launchAdmission: .init(observePressure: false, thermalState: { .nominal }),
            paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent }, validatesPersistedProfiles: true)
        return (root, paths, store, a, b, manager)
    }
    private func started(_ gate: OwnDeletionCallback) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.started)
    }

    @Test func successfulTransactionKeepsBAndPermanentTombstoneAndBothMetadataSnapshots() async throws {
        let (root,paths,store,a,b,manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let beforeB = try WebKitSessionStore(paths: paths).load(for: b.id)
        var removed: [UUID] = [], credentials: [UUID] = []
        try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
            operation: { removed.append($0) }, afterCommit: { credentials.append($0) })
        #expect(removed == [a.id] && credentials == [a.id])
        #expect(store.profile(withID: a.id) == nil && store.profile(withID: b.id) != nil)
        for file in [paths.profilesFile, paths.profilesBackupFile] {
            #expect(try !ProfileStore.readProfiles(from: file).contains { $0.id == a.id })
            #expect(try ProfileStore.readProfiles(from: file).contains { $0.id == b.id })
        }
        #expect(try WebKitSessionStore(paths: paths).load(for: a.id) == nil)
        #expect(try WebKitSessionStore(paths: paths).load(for: b.id) == beforeB)
        #expect(try paths.privateFileEntryKind(paths.profileDirectory(for: a.id)) == .missing)
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id)?.stage == .metadataRemoved)
        #expect(try WebKitProfileDeletionJournal(paths: paths).pendingProfileIDs().isEmpty)
        #expect(throws: BrowserProfileDeletedError.self) { try store.upsert(a) }
        #expect(!manager.hasPendingWebKitWork)
    }

    @Test func nativeErrorRetainsSessionAndFencesMetadataUntilExplicitRetry() async throws {
        let (root,paths,store,a,b,manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try WebKitSessionStore(paths: paths).load(for: a.id)
        await #expect(throws: WebKitProfileDeletionError.nativeFailed) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
                operation: { _ in throw OwnDeletionFault.injected }, afterCommit: { _ in Issue.record("No credential cleanup before native completion") })
        }
        #expect(store.profile(withID: a.id) == nil && store.profile(withID: b.id) != nil)
        #expect(try WebKitSessionStore(paths: paths).load(for: a.id) == before)
        for file in [paths.profilesFile, paths.profilesBackupFile] {
            #expect(try !ProfileStore.readProfiles(from: file).contains { $0.id == a.id })
        }
        #expect(throws: BrowserProfileDeletedError.self) {
            try ProfileStore.withPersistedLaunchSnapshot(a, paths: paths) { Issue.record("Old launch contract must refuse A") }
        }
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id)?.stage == .prepared)
        #expect(throws: BrowserProfileRevisionConflictError.self) { try store.duplicateProfile(a, name: "Do not create") }
        #expect(throws: ProfileOrganizationError.profileNotFound) { try store.assignProfiles([a.id], toFolderID: nil) }
        #expect(throws: ProfileMetadataUndoConflict.self) { try store.moveProfileWithUndo(a, toFolderID: nil) }
        #expect(throws: BrowserProfileDeletedError.self) { try manager.launchWebKitProfile(a) }
        await #expect(throws: BrowserProfileDeletedError.self) { try await manager.clearWebKitCache(profile: a) { _ in Issue.record("Pending deletion cannot clear caches") } }
        _ = try store.mutateProfile(withID: b.id) { $0.name = "Independent B works" }
        var calls = 0
        try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
            operation: { _ in calls += 1 }, afterCommit: { _ in })
        #expect(calls == 1 && store.profile(withID: a.id) == nil)
    }

    @Test func interruptionAfterNativeCompletionResumesWithoutCallingNativeAgain() async throws {
        let (root,paths,store,a,_,manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var native = 0
        await #expect(throws: WebKitProfileDeletionError.interrupted) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
                operation: { _ in native += 1 }, afterNative: { throw OwnDeletionFault.injected }, afterCommit: { _ in })
        }
        #expect(native == 1 && store.profile(withID: a.id) == nil)
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id)?.stage == .dataRemoved)
        let reloaded = ProfileStore(paths: paths, trashDirectory: { source in
            let destination=root.appendingPathComponent("OwnedRecoveryTrash"); try FileManager.default.moveItem(at: source, to: destination); return destination
        })
        try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: nil, store: reloaded,
            operation: { _ in native += 1; Issue.record("Native completion must not repeat") }, afterCommit: { _ in })
        #expect(native == 1 && reloaded.profile(withID: a.id) == nil)
    }

    @Test func metadataFailureAfterNativeRemovalRetainsRecoverableIntentAndOtherProfile() async throws {
        var commits = 0
        let (root,paths,store,a,b,manager) = try fixture(failMetadata: {
            commits += 1
            if commits == 2 { throw OwnDeletionFault.injected }
        })
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: WebKitProfileDeletionError.interrupted) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
                operation: { _ in }, afterCommit: { _ in })
        }
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id)?.stage == .dataRemoved)
        #expect(store.profile(withID: a.id) == nil && store.profile(withID: b.id) != nil)
        let reloaded = ProfileStore(paths: paths)
        try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: reloaded.profile(withID: a.id), store: reloaded,
            operation: { _ in Issue.record("No second native call") }, afterCommit: { _ in })
        #expect(reloaded.profile(withID: a.id) == nil && reloaded.profile(withID: b.id) != nil)
    }

    @Test func nativeCompleteOrphanCanFinalizeWithoutProfileOrNativeCall() async throws {
        let (root,paths,store,a,b,manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let record = try store.prepareWebKitDeletion(profileID: a.id, expected: a)
        let journal = WebKitProfileDeletionJournal(paths: paths)
        _ = try journal.advance(record, to: .dataRemoved)
        // Simulate crash after committing main metadata but before journal stage.
        let remaining=try ProfileStore.readProfiles(from: paths.profilesFile).filter { $0.id != a.id }
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(ProfileStore.encodeProfiles(remaining, encoder: encoder), to: paths.profilesFile)
        let reloaded=ProfileStore(paths: paths,trashDirectory: { source in
            let destination=root.appendingPathComponent("OwnOrphanTrash");try FileManager.default.moveItem(at: source,to: destination);return destination
        })
        #expect(reloaded.profile(withID: a.id) == nil)
        #expect(try journal.pendingProfileIDs() == [a.id])
        try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: nil, store: reloaded,
            operation: { _ in Issue.record("Orphan has no native permission") }, afterCommit: { _ in })
        #expect(try reloaded.profile(withID: b.id) != nil && journal.load(for: a.id)?.stage == .metadataRemoved)
    }

    @Test func staleWrongProfileWrongEngineLeaseAndRestoreNeverReachNative() async throws {
        let (root,paths,store,a,b,manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var calls=0
        await #expect(throws: BrowserProfileRevisionConflictError.self) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: b, store: store,operation: { _ in calls += 1 },afterCommit: { _ in })
        }
        var chromium=a;chromium.engine = .chromium
        await #expect(throws: WebKitProfileDeletionError.wrongEngine) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: chromium, store: store,operation: { _ in calls += 1 },afterCommit: { _ in })
        }
        let changed=try store.mutateProfile(withID: a.id) { $0.name="Changed A" }
        await #expect(throws: BrowserProfileRevisionConflictError.self) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,operation: { _ in calls += 1 },afterCommit: { _ in })
        }
        try paths.writePrivateFile(Data(),to: paths.lockFile(for: a.id))
        await #expect(throws: BrowserProfileDeletionBlockedError.self) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: changed, store: store,operation: { _ in calls += 1 },afterCommit: { _ in })
        }
        try FileManager.default.removeItem(at: paths.lockFile(for: a.id))
        try paths.writePrivateFile(Data(),to:root.appendingPathComponent(BrowserDataRestoreTransaction.activeName))
        await #expect(throws:(any Error).self) {
            try await manager.deleteClosedWebKitProfile(profileID:a.id,expected:changed,store:store,operation:{ _ in calls += 1 },afterCommit:{ _ in })
        }
        #expect(calls == 0)
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id) == nil)
    }

    @Test func cancelledBeforeDispatchHasNoIntentOrNativeCall() async throws {
        let (root,paths,store,a,_,manager)=try fixture();defer { try? FileManager.default.removeItem(at: root) }
        let task=Task { try await manager.deleteClosedWebKitProfile(profileID: a.id,expected: a,store: store,
            operation: { _ in Issue.record("Cancelled admission") },afterCommit: { _ in }) }
        task.cancel();await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id) == nil)
    }

    @Test func cancelledAfterDispatchKeepsGuardsAndFinishesWithoutFalseCancellation() async throws {
        let (root,paths,store,a,_,manager)=try fixture();defer { try? FileManager.default.removeItem(at: root) }
        let gate=OwnDeletionCallback();defer { gate.finish() }
        let task=Task { try await manager.deleteClosedWebKitProfile(profileID: a.id,expected: a,store: store,
            operation: { _ in await gate.wait() },afterCommit: { _ in }) }
        try await started(gate);task.cancel()
        #expect(manager.hasPendingWebKitWork)
        #expect(throws: ProfileProcessBusyError.self) { try paths.acquireWebKitSessionGuard(for: a.id) }
        #expect(throws: ProfileProcessBusyError.self) { try paths.acquireWebKitMetadataGuard(for: a.id) }
        #expect(throws: ApplicationUpdateAdmissionError.busy) { try ApplicationUpdateAdmission.shared.acquireUpdate() }
        gate.finish();try await task.value
        #expect(store.profile(withID: a.id) == nil && !manager.hasPendingWebKitWork)
    }

    @Test func replacedAuthorityAfterNativeCallbackCannotCommitMetadata() async throws {
        let (root,paths,store,a,_,manager)=try fixture();defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: WebKitProfileDeletionError.changed) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id,expected: a,store: store,operation: { _ in
                try FileManager.default.moveItem(at: paths.lockGuardFile(for: a.id),to: root.appendingPathComponent("OwnHeldGuard"))
                try paths.writePrivateFile(Data(),to: paths.lockGuardFile(for: a.id))
            },afterCommit: { _ in Issue.record("Authority changed") })
        }
        #expect(store.profile(withID: a.id) == nil)
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id)?.stage == .prepared)
    }

    @Test(arguments: [false, true])
    func replacedProfileOrParentDirectoryNeverTrashesReplacement(replaceParent: Bool) async throws {
        let (root, paths, store, a, b, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: WebKitProfileDeletionError.interrupted) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
                operation: { _ in }, afterNative: {
                    let source = replaceParent ? paths.profilesDirectory : paths.profileDirectory(for: a.id)
                    try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("OriginalOwnedDirectory"))
                    try paths.prepareProfileDirectories(for: a.id)
                    try paths.writePrivateFile(Data("replacement".utf8), to: paths.profileDirectory(for: a.id).appendingPathComponent("OwnedSentinel"))
                }, afterCommit: { _ in Issue.record("Replacement cannot commit") })
        }
        #expect(try Data(contentsOf: paths.profileDirectory(for: a.id).appendingPathComponent("OwnedSentinel")) == Data("replacement".utf8))
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id)?.stage == .dataRemoved)
        #expect(store.profile(withID: b.id) != nil)
        #expect(try paths.privateFileEntryKind(paths.profileCredentialCleanupMarker(for: a.id)) == .missing)
        await #expect(throws: (any Error).self) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: nil, store: store,
                operation: { _ in Issue.record("Recovery cannot touch replacement") }, afterCommit: { _ in })
        }
    }

    @Test func replacementBetweenValidationAndRenameIsRetainedAndRestored() throws {
        let (root, paths, _, a, b, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = WebKitProfileDeletionJournal(paths: paths)
        let record = try journal.advance(journal.prepare(a), to: .dataRemoved)
        let original = root.appendingPathComponent("OriginalBeforeAtomicMove")
        #expect(throws: WebKitProfileDeletionError.changed) {
            try journal.retireProfileDirectory(record) {
                try FileManager.default.moveItem(at: paths.profileDirectory(for: a.id), to: original)
                try paths.prepareProfileDirectories(for: a.id)
                try paths.writePrivateFile(Data("replacement".utf8), to: paths.profileDirectory(for: a.id).appendingPathComponent("OwnReplacement"))
            }
        }
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: paths.profileDirectory(for: a.id).appendingPathComponent("OwnReplacement")) == Data("replacement".utf8))
        #expect(FileManager.default.fileExists(atPath: paths.profileDirectory(for: b.id).path))
    }

    @Test func unexpectedLocalFilesRemainPrivateAfterSupportedWebKitRemoval() async throws {
        let (root, paths, store, a, _, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try paths.writePrivateFile(Data("own-file".utf8), to: paths.profileDirectory(for: a.id).appendingPathComponent("KeepLocalFile"))
        try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
            operation: { _ in }, afterCommit: { _ in })
        let record = try #require(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id))
        let retained = paths.profilesDirectory.appendingPathComponent(".webkit-deleted-" + record.operationID.uuidString)
        #expect(try Data(contentsOf: retained.appendingPathComponent("KeepLocalFile")) == Data("own-file".utf8))
        #expect(store.postCommitWarning != nil && store.profile(withID: a.id) == nil)
        #expect(try paths.privateFileEntryKind(paths.profileDirectory(for: a.id)) == .missing)
    }

    @Test func postPersistFaultKeepsMemoryAlignedAndPreparedOrphanResumesNative() async throws {
        var fail = true
        let (root, paths, store, a, b, manager) = try fixture(failAfterMetadata: {
            if fail { throw OwnDeletionFault.injected }
        })
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: WebKitProfileDeletionError.interrupted) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
                operation: { _ in Issue.record("Metadata was not durably acknowledged") }, afterCommit: { _ in })
        }
        #expect(store.profile(withID: a.id) == nil && store.profile(withID: b.id) != nil)
        for file in [paths.profilesFile, paths.profilesBackupFile] {
            #expect(try !ProfileStore.readProfiles(from: file).contains { $0.id == a.id })
        }
        let journal = WebKitProfileDeletionJournal(paths: paths)
        #expect(try journal.load(for: a.id)?.stage == .prepared)
        #expect(try journal.pendingProfileIDs() == [a.id])
        #expect(try paths.privateFileEntryKind(paths.profileCredentialCleanupMarker(for: a.id)) == .missing)
        fail = false
        var calls = 0
        try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: nil, store: store, operation: { _ in
            calls += 1
            for file in [paths.profilesFile, paths.profilesBackupFile] {
                let saved = try ProfileStore.readProfiles(from: file)
                #expect(!saved.contains { $0.id == a.id })
            }
        }, afterCommit: { _ in })
        #expect(calls == 1 && store.profile(withID: a.id) == nil)
        #expect(try journal.load(for: a.id)?.stage == .metadataRemoved)
    }

    @Test func prePersistFailureRetainsProfileAndNeverCallsNativeOrCleansCredentials() async throws {
        let (root, paths, store, a, b, manager) = try fixture(failMetadata: { throw OwnDeletionFault.injected })
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: WebKitProfileDeletionError.interrupted) {
            try await manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: store,
                operation: { _ in Issue.record("No native before durable metadata fence") }, afterCommit: { _ in })
        }
        #expect(store.profile(withID: a.id) != nil && store.profile(withID: b.id) != nil)
        #expect(try WebKitProfileDeletionJournal(paths: paths).load(for: a.id)?.stage == .prepared)
        #expect(try paths.privateFileEntryKind(paths.profileCredentialCleanupMarker(for: a.id)) == .missing)
    }

}

@Suite(.serialized) @MainActor struct WebKitDeletionJournalTests {
    @Test(arguments: ["symlink","hardlink","empty","public-mode","wrong-root","wrong-id","extra-field"])
    func unsafeIntentNeverBecomesNativeAuthority(kind: String) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("neantik-own-wk-journal-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths=AppPaths(rootDirectory: root),store=ProfileStore(paths: paths)
        let a=try store.upsert(BrowserProfile(name:"Own journal A",engine:.webkit))
        let journal=WebKitProfileDeletionJournal(paths:paths),record=try journal.prepare(a)
        let marker=paths.profileDeletionTombstone(for:a.id)
        switch kind {
        case "symlink":try FileManager.default.moveItem(at:marker,to:root.appendingPathComponent("OwnMarker"));try FileManager.default.createSymbolicLink(at:marker,withDestinationURL:root.appendingPathComponent("OwnMarker"))
        case "hardlink":try FileManager.default.linkItem(at:marker,to:root.appendingPathComponent("OwnMarker"))
        case "empty":try Data().write(to:marker)
        case "public-mode":try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:marker.path)
        case "wrong-root","wrong-id","extra-field":
            var object=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:marker)) as? [String:Any])
            if kind=="wrong-root" { object["rootInode"]=record.rootInode+1 }
            if kind=="wrong-id" { object["profileID"]=UUID().uuidString }
            if kind=="extra-field" { object["unexpected"]="never accepted" }
            try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]).write(to:marker)
        default:Issue.record("Unknown own control")
        }
        #expect(throws:(any Error).self) { try journal.load(for:a.id) }
        #expect(throws:(any Error).self) { try journal.advance(record,to:.dataRemoved) }
        #expect(store.profile(withID:a.id) != nil)
    }

    @Test func stageOrderAndExactProfileDigestPreventWrongOrStaleFinalize() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("neantik-own-wk-stage-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at:root) }
        let paths=AppPaths(rootDirectory:root),store=ProfileStore(paths:paths)
        let a=try store.upsert(BrowserProfile(name:"Own stage A",engine:.webkit))
        let journal=WebKitProfileDeletionJournal(paths:paths),record=try journal.prepare(a)
        #expect(throws:WebKitProfileDeletionError.changed) { try journal.advance(record,to:.metadataRemoved) }
        var other=a;other.name="Wrong snapshot"
        #expect(throws:WebKitProfileDeletionError.changed) { try journal.prepare(other) }
        let removed=try journal.advance(record,to:.dataRemoved)
        #expect(throws:WebKitProfileDeletionError.changed) { try journal.advance(record,to:.dataRemoved) }
        #expect(throws:WebKitProfileDeletionError.changed) { try store.finalizeWebKitDeletion(record) }
        #expect(try journal.load(for:a.id)==removed)
    }
}
