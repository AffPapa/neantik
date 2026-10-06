import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ProfileMetadataUndoTests {
    private func paths() -> AppPaths { AppPaths(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("metadata-undo-\(UUID())")) }
    @Test func undoAllowedFieldsPersistsAndAdvancesRevision() throws {
        let paths = paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(BrowserProfile(name: "Original", tags: ["one"], note: "Private", startURL: "https://example.test"))
        let changed = try store.mutateProfile(withID: original.id, registerMetadataUndo: true) {
            $0.name = "Changed"; $0.tags = ["two"]; $0.isArchived = true
        }
        let restored = try store.undoLastMetadataChange()
        #expect(restored.name == original.name && restored.tags == original.tags && !restored.isArchived)
        #expect(restored.note == original.note && restored.identity == original.identity && restored.startURL == original.startURL)
        #expect(restored.revision > changed.revision)
        let reloaded = ProfileStore(paths: paths).profile(withID: original.id)
        #expect(reloaded?.name == restored.name && reloaded?.revision == restored.revision && reloaded?.identity == restored.identity)
        #expect(store.metadataUndo == nil)
    }
    @Test func newerProfileAndABAFolderEditsBlockUndo() throws {
        let paths = paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let store = ProfileStore(paths: paths)
        let a = try store.createFolder(named: "A"), b = try store.createFolder(named: "B")
        let original = try store.upsert(BrowserProfile(name: "Original"), toFolderID: a.id)
        try store.moveProfileWithUndo(original, toFolderID: b.id)
        let other = ProfileStore(paths: paths)
        try other.assignProfile(original.id, toFolderID: a.id)
        try other.assignProfile(original.id, toFolderID: b.id)
        #expect(throws: ProfileMetadataUndoConflict.self) { try store.undoLastMetadataChange() }
        #expect(ProfileStore(paths: paths).folderID(forProfileID: original.id) == b.id)
        _ = try store.mutateProfile(withID: original.id, registerMetadataUndo: true) { $0.name = "Changed" }
        _ = try other.mutateProfile(withID: original.id) { $0.name = "Newer" }
        #expect(throws: BrowserProfileRevisionConflictError.self) { try store.undoLastMetadataChange() }
        #expect(ProfileStore(paths: paths).profile(withID: original.id)?.name == "Newer")
    }
    @Test func importedFolderMutationBlocksStaleUndoFromAnotherWindow() throws {
        let paths = paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let firstWindow = ProfileStore(paths: paths)
        let original = try firstWindow.upsert(BrowserProfile(name: "Original"))
        _ = try firstWindow.mutateProfile(withID: original.id, registerMetadataUndo: true) {
            $0.name = "Changed"
        }
        let secondWindow = ProfileStore(paths: paths)
        let before = secondWindow.organization.mutationRevision
        let importResult = try ProfileMetadataImportTransaction.run(
            paths: paths,
            requestedProfiles: [BrowserProfile(name: "Imported")],
            folderNames: ["Imported folder"]
        )
        #expect(importResult.organization.mutationRevision != before)
        #expect(throws: ProfileMetadataUndoConflict.self) {
            try firstWindow.undoLastMetadataChange()
        }
        let restarted = ProfileStore(paths: paths)
        #expect(restarted.profile(withID: original.id)?.name == "Changed")
        #expect(restarted.organization.folders.contains { $0.name == "Imported folder" })
    }
    @Test func moveUndoAndDeletedDestination() throws {
        let paths = paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let store = ProfileStore(paths: paths)
        let a = try store.createFolder(named: "A")
        let original = try store.upsert(BrowserProfile(name: "Original"), toFolderID: a.id)
        try store.moveProfileWithUndo(original, toFolderID: nil)
        let restored = try store.undoLastMetadataChange()
        #expect(store.folderID(forProfileID: original.id) == a.id)
        try store.moveProfileWithUndo(restored, toFolderID: nil)
        _ = try store.deleteFolder(withID: a.id)
        #expect(throws: (any Error).self) { try store.undoLastMetadataChange() }
        #expect(store.folderID(forProfileID: original.id) == nil)
    }
    @Test func failedMoveRollsBackAndDoesNotRegisterUndo() throws {
        let paths = paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let store = ProfileStore(paths: paths)
        let a = try store.createFolder(named: "A")
        let original = try store.upsert(BrowserProfile(name: "Original"))
        let failing = ProfileStore(paths: paths, beforeOrganizationPersist: { throw POSIXError(.ENOSPC) })
        #expect(throws: (any Error).self) { try failing.moveProfileWithUndo(original, toFolderID: a.id) }
        #expect(failing.metadataUndo == nil)
        let restarted = ProfileStore(paths: paths)
        #expect(restarted.profile(withID: original.id)?.name == "Original")
        #expect(restarted.folderID(forProfileID: original.id) == nil)
    }
    @Test func noOpMoveDoesNotReplaceUsefulUndo() throws {
        let paths = paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(BrowserProfile(name: "Original"))
        let changed = try store.mutateProfile(withID: original.id, registerMetadataUndo: true) { $0.name = "Changed" }
        try store.moveProfileWithUndo(changed, toFolderID: nil)
        #expect(try store.undoLastMetadataChange().name == "Original")
    }

    @Test func editorWithoutProxyCanUndoMetadataWithoutUndoingSecrets() {
        let original = BrowserProfile(name: "Original")
        #expect(ProfileMetadataUndo.editorPreservesSecrets(original: original, passwordUpdate: .delete))
        #expect(ProfileMetadataUndo.editorPreservesSecrets(original: original, passwordUpdate: .keepExisting))
        #expect(!ProfileMetadataUndo.editorPreservesSecrets(original: original, passwordUpdate: .replace("synthetic")))
        #expect(!ProfileMetadataUndo.editorPreservesSecrets(original: nil, passwordUpdate: .delete))
    }

    @Test func protectedFieldsDoNotBecomeUndoable() throws {
        let before = BrowserProfile(name: "Original")
        var after = before; after.note = "new note"
        #expect(!ProfileMetadataUndo.onlyAllowedFieldsChanged(before: before, after: after))
        after = before; after.identity = BrowserIdentity()
        #expect(!ProfileMetadataUndo.onlyAllowedFieldsChanged(before: before, after: after))
        after = before; after.startURL = "https://example.test"
        #expect(!ProfileMetadataUndo.onlyAllowedFieldsChanged(before: before, after: after))
    }
}
