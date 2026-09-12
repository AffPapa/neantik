import Foundation
import Testing
@testable import NeAntik

struct EncryptedProfileBackupTests {
    @Test func roundTripIsEncryptedAndOmitsProxyUsername() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = BrowserProfile(name: "Work", proxy: ProxyConfiguration(kind: .http, host: "proxy.example", port: 8080, username: "secret-user"))
        profile.note = "keep this"
        let destination = root.appendingPathComponent("profile.neantik-backup")
        try EncryptedProfileBackup.export(profile: profile, password: "correct horse", to: destination)
        let raw = try String(contentsOf: destination, encoding: .utf8)
        #expect(!raw.contains("keep this"))
        #expect(!raw.contains("secret-user"))
        let restored = try EncryptedProfileBackup.restore(from: destination, password: "correct horse")
        #expect(restored.name == profile.name)
        #expect(restored.note == profile.note)
        #expect(restored.proxy?.username == "")
    }

    @Test func wrongPasswordAndEmptyPasswordAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("backup")
        try EncryptedProfileBackup.export(profile: BrowserProfile(name: "Test"), password: "abc", to: destination)
        #expect(throws: EncryptedProfileBackup.Error.wrongPassword) {
            try EncryptedProfileBackup.restore(from: destination, password: "xyz")
        }
        #expect(throws: EncryptedProfileBackup.Error.invalidPassword) {
            try EncryptedProfileBackup.export(profile: BrowserProfile(name: "Test"), password: "", to: destination)
        }
    }

    @Test func snapshotsRestoreAtomicallyAndRejectOutsidePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = root.appendingPathComponent("Profiles/data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: data.appendingPathComponent("state"))
        let store = AtomicProfileSnapshotStore(rootDirectory: root)
        let id = UUID()
        let snapshot = try store.create(profileID: id, browserData: data)
        try Data("new".utf8).write(to: data.appendingPathComponent("state"))
        try store.restore(snapshot: snapshot, to: data)
        #expect(String(data: try Data(contentsOf: data.appendingPathComponent("state")), encoding: .utf8) == "old")
        #expect(store.snapshots(for: id).count == 1)
        #expect(throws: CocoaError.self) {
            try store.restore(snapshot: root.appendingPathComponent("outside"), to: data)
        }
    }
}
