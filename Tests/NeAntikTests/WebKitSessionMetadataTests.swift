import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor struct WebKitSessionMetadataTests {
    private func fixture<T>(_ operation: (URL, ProfileStore, WebKitSessionStore, BrowserProfile) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-session-metadata-owned-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths), sessions = WebKitSessionStore(paths: paths)
        let profile = try store.upsert(BrowserProfile(name: "Own restore", startURL: "about:blank", startupMode: .restoreSession, engine: .webkit))
        try sessions.save(.capture(profileID: profile.id, urls: ["https://example.com/owned?tab=one#selected"], selectedIndex: 0))
        return try operation(root, store, sessions, profile)
    }
    private func file(_ root: URL, _ id: UUID) -> URL { root.appendingPathComponent("WebKitSessions/\(id.uuidString.lowercased()).json") }

    @Test func renameArchiveAndDuplicateKeepSessionOwnership() throws {
        try fixture { root, store, sessions, profile in
            let bytes = try Data(contentsOf: file(root, profile.id))
            var change = profile; change.name = "Renamed own profile"
            let renamed = try store.upsert(change)
            let archived = try store.mutateProfile(withID: renamed.id) { $0.isArchived = true }
            #expect(archived.id == profile.id)
            #expect(try Data(contentsOf: file(root, profile.id)) == bytes)
            let active = try store.mutateProfile(withID: profile.id) { $0.isArchived = false }
            let clone = try store.duplicateProfile(active, name: "Own clone")
            #expect(clone.id != profile.id && clone.startupMode == .restoreSession)
            #expect(try sessions.load(for: clone.id) == nil)
            #expect(try Data(contentsOf: file(root, profile.id)) == bytes)
        }
    }

    @Test func disableDeletesOnlyItsSessionAndNextEnableStartsFresh() throws {
        try fixture { root, store, sessions, profile in
            let other = UUID(); try sessions.save(.capture(profileID: other, urls: ["about:blank"], selectedIndex: 0))
            let canary = root.appendingPathComponent("own-website-data-canary")
            try Data("retain own site data".utf8).write(to: canary)
            var change = profile; change.startupMode = .startPage
            let off = try store.upsert(change)
            #expect(try sessions.load(for: profile.id) == nil && sessions.load(for: other) != nil)
            #expect(FileManager.default.fileExists(atPath: canary.path))
            // An old OFF state cannot be revived during a later opt-in.
            try sessions.save(.capture(profileID: profile.id, urls: ["https://example.com/stale"], selectedIndex: 0))
            change = off; change.startupMode = .restoreSession
            let enabled = try store.upsert(change)
            let restored = try sessions.load(for: profile.id)
            #expect(enabled.startupMode == .restoreSession && restored == nil)
        }
    }

    @Test func compoundFolderCredentialFailureRollsBackWithoutDeletingOnSnapshot() throws {
        try fixture { root, store, _, profile in
            let bytes = try Data(contentsOf: file(root, profile.id))
            let folder = try store.createFolder(named: "Own folder")
            var change = profile; change.startupMode = .startPage
            #expect(throws: WebKitSessionError.self) {
                try store.upsert(change, toFolderID: folder.id, afterPersist: { _ in throw WebKitSessionError.unavailable })
            }
            #expect(store.profile(withID: profile.id)?.startupMode == .restoreSession)
            #expect(store.folderID(forProfileID: profile.id) == nil)
            #expect(try Data(contentsOf: file(root, profile.id)) == bytes)
            #expect(store.postCommitWarning == nil)
        }
    }

    @Test func staleStartupPreferenceCannotPassPersistedLaunchAdmission() throws {
        try fixture { _, store, _, profile in
            var changed = profile; changed.startupMode = .startPage
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try store.paths.writePrivateFile(ProfileStore.encodeProfiles([changed], encoder: encoder), to: store.paths.profilesFile)
            var called = false
            #expect(throws: BrowserProfileRevisionConflictError.self) {
                try ProfileStore.withPersistedLaunchSnapshot(profile, paths: store.paths) { called = true }
            }
            #expect(!called)
        }
    }
}
