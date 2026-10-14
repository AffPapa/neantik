import Darwin
import Foundation
import Testing
@testable import NeAntik

@Suite struct WebKitSessionPolicyTests {
    @Test func keepsCompleteWorkingAddressesAndOrder() throws {
        let values = ["https://example.com/campaign?utm_source=qa&id=42#report", "http://127.0.0.1:8765/one?tab=2", "about:blank"]
        let snapshot = try WebKitSessionSnapshot.capture(profileID: UUID(), urls: values, selectedIndex: 1)
        #expect(snapshot.urls == values)
        #expect(snapshot.selectedIndex == 1 && snapshot.unavailableCount == 0)
    }

    @Test(arguments: ["https://login:password@example.com/", "file:///private/tmp/a", "data:text/plain,qa", "blob:https://example.com/owned", "javascript:alert(1)", "example.com", "about:blank#fragment", " https://example.com/", "https://example.com/\n"])
    func unavailableAddressKeepsItsSlotRatherThanChangingDestination(value: String) throws {
        let snapshot = try WebKitSessionSnapshot.capture(profileID: UUID(), urls: ["https://example.com/", value], selectedIndex: 1)
        #expect(snapshot.urls == ["https://example.com/", "about:blank"])
        #expect(snapshot.selectedIndex == 1 && snapshot.unavailableCount == 1)
    }

    @Test func boundedIdentityAndSelectionAreRequired() throws {
        let id = UUID()
        #expect(throws: WebKitSessionError.self) { try WebKitSessionSnapshot.capture(profileID: id, urls: [], selectedIndex: 0) }
        #expect(throws: WebKitSessionError.self) { try WebKitSessionSnapshot.capture(profileID: id, urls: Array(repeating: "about:blank", count: 33), selectedIndex: 0) }
        #expect(throws: WebKitSessionError.self) { try WebKitSessionSnapshot.capture(profileID: id, urls: ["about:blank"], selectedIndex: -1) }
        #expect(throws: WebKitSessionError.self) { try WebKitSessionSnapshot.capture(profileID: id, urls: ["about:blank"], selectedIndex: 1) }
        let snapshot = try WebKitSessionSnapshot.capture(profileID: id, urls: ["about:blank"], selectedIndex: 0)
        #expect(throws: WebKitSessionError.self) { try snapshot.validate(for: UUID()) }
        let long = try WebKitSessionSnapshot.capture(profileID: id, urls: ["https://example.com/" + String(repeating: "x", count: 4096)], selectedIndex: 0)
        #expect(long.urls == ["about:blank"])
    }
}

@Suite struct WebKitSessionStoreTests {
    private func fixture<T>(_ operation: (URL, WebKitSessionStore, UUID, URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-session-owned-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WebKitSessionStore(paths: AppPaths(rootDirectory: root)), id = UUID()
        let file = root.appendingPathComponent("WebKitSessions/\(id.uuidString.lowercased()).json")
        return try operation(root, store, id, file)
    }
    private func snapshot(_ id: UUID) throws -> WebKitSessionSnapshot {
        try .capture(profileID: id, urls: ["https://example.com/one?source=owned#two", "about:blank"], selectedIndex: 1)
    }

    @Test func realPrivateFilePersistsAcrossNewStoreAndDeletesOnlyThisProfile() throws {
        try fixture { root, store, id, file in
            #expect(try store.load(for: id) == nil)
            let value = try snapshot(id); try store.save(value)
            let other = UUID(); try store.save(snapshot(other))
            #expect(try WebKitSessionStore(paths: store.paths).load(for: id) == value)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
            #expect(try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["WebKitSessions"])
            try store.discard(for: id); try store.discard(for: id)
            #expect(try store.load(for: id) == nil)
            #expect(try store.load(for: other) == snapshot(other))
        }
    }

    @Test func wrongProfileAndCorruptOrOversizedDocumentsAreRefused() throws {
        try fixture { _, store, id, file in
            try store.save(snapshot(id))
            let wrong = try JSONEncoder().encode(snapshot(UUID()))
            let schema = WebKitSessionSnapshot(schemaVersion: 2, profileID: id, urls: ["about:blank"], selectedIndex: 0, unavailableCount: 0)
            let unsafe = WebKitSessionSnapshot(schemaVersion: 1, profileID: id, urls: ["javascript:alert(1)"], selectedIndex: 0, unavailableCount: 0)
            for data in [Data("{truncated".utf8), wrong, try JSONEncoder().encode(schema), try JSONEncoder().encode(unsafe), Data(repeating: 0, count: WebKitSessionSnapshot.maximumBytes + 1)] {
                try data.write(to: file)
                #expect(throws: WebKitSessionError.self) { try store.load(for: id) }
            }
        }
    }

    @Test func systemTemporaryAliasWorksButUserRootSymlinkIsRefused() throws {
        try fixture { root, store, id, _ in
            try store.save(snapshot(id))
            let alternate = root.path.hasPrefix("/private/var/") || root.path.hasPrefix("/private/tmp/")
                ? String(root.path.dropFirst("/private".count)) : "/private" + root.path
            #expect(try WebKitSessionStore(paths: AppPaths(rootDirectory: URL(fileURLWithPath: alternate))).load(for: id) == snapshot(id))
            let link = root.appendingPathComponent("root-alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            #expect(throws: WebKitSessionError.self) { try WebKitSessionStore(paths: AppPaths(rootDirectory: link)).load(for: id) }
        }
    }

    @Test func symlinkCannotReadOverwriteOrDeleteItsTarget() throws {
        try fixture { root, store, id, file in
            let value = try snapshot(id); try store.save(value)
            let target = root.appendingPathComponent("unrelated.txt"); let bytes = Data("untouched owned fixture".utf8)
            try bytes.write(to: target); try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            #expect(throws: WebKitSessionError.self) { try store.load(for: id) }
            #expect(throws: WebKitSessionError.self) { try store.save(value) }
            #expect(throws: WebKitSessionError.self) { try store.discard(for: id) }
            #expect(try Data(contentsOf: target) == bytes)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
        }
    }

    @Test func hardlinkAndPublicPermissionsAreRefused() throws {
        try fixture { root, store, id, file in
            let value = try snapshot(id); try store.save(value)
            let link = root.appendingPathComponent("second-link")
            try FileManager.default.linkItem(at: file, to: link)
            #expect(throws: WebKitSessionError.self) { try store.load(for: id) }
            #expect(throws: WebKitSessionError.self) { try store.save(value) }
            #expect(throws: WebKitSessionError.self) { try store.discard(for: id) }
            try FileManager.default.removeItem(at: link)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(throws: WebKitSessionError.self) { try store.load(for: id) }
            #expect(throws: WebKitSessionError.self) { try store.save(value) }
        }
    }

    @Test func directorySymlinkAndFifoAreRefusedWithoutBlocking() throws {
        try fixture { root, store, id, file in
            let foreign = root.appendingPathComponent("unrelated-directory")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: foreign)
            #expect(throws: WebKitSessionError.self) { try store.save(snapshot(id)) }
            #expect(throws: WebKitSessionError.self) { try store.load(for: id) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
            try FileManager.default.removeItem(at: file.deletingLastPathComponent())
            try store.save(snapshot(id)); try FileManager.default.removeItem(at: file)
            #expect(mkfifo(file.path, mode_t(0o600)) == 0)
            #expect(throws: WebKitSessionError.self) { try store.load(for: id) }
            #expect(throws: WebKitSessionError.self) { try store.discard(for: id) }
        }
    }

    @Test func failedWriteRetainsPreviousCompleteStateAndRemovesOwnTemporaryFile() throws {
        try fixture { _, store, id, file in
            try store.save(snapshot(id)); let before = try Data(contentsOf: file)
            var failed = store
            failed.beforeCommit = { throw WebKitSessionError.unavailable }
            let change = try WebKitSessionSnapshot.capture(profileID: id, urls: ["https://example.com/new"], selectedIndex: 0)
            #expect(throws: WebKitSessionError.self) { try failed.save(change) }
            #expect(try Data(contentsOf: file) == before)
            #expect(try store.load(for: id) == snapshot(id))
            #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [file.lastPathComponent])
        }
    }
}
