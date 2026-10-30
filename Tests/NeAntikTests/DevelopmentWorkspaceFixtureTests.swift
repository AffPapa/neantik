import Foundation
import Testing
@testable import NeAntik

extension ProfileStoreTests {
    @Test func readonlyDevelopmentMetadataCompatibility() throws {
        guard let path = ProcessInfo.processInfo.environment["NEANTIK_READONLY_DEV_METADATA"] else { return }
        let file = URL(fileURLWithPath: path)
        try #require(file.lastPathComponent == "profiles.json" && file.deletingLastPathComponent().lastPathComponent == "NeAntik Development")
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        try #require(size != nil && size! <= 64 * 1024 * 1024)
        let before = try Data(contentsOf: file)
        let profiles = try ProfileStore.decodeProfiles(before)
        #expect(!profiles.isEmpty)
        #expect(profiles.contains { $0.startURL == "about:blank" })
        #expect(try Data(contentsOf: file) == before)
        print("DEV_COMPATIBILITY decoded=\(profiles.count) blank=\(profiles.filter { $0.startURL == "about:blank" }.count) mutation=none")
    }

    /// Populate only an explicitly selected empty temporary Dev workspace.
    /// With no environment override, exercise the same fixture and remove it.
    @Test func populatedDevelopmentWorkspaceSurvivesRestart() throws {
        let requested = ProcessInfo.processInfo.environment["NEANTIK_POPULATE_DEV_FIXTURE"]
        let root = URL(fileURLWithPath: requested ?? "/private/tmp/neantik-dev-fixture.\(UUID().uuidString)")
        #expect(root.path.hasPrefix("/private/tmp/neantik-dev-fixture."))
        try #require(root.path.hasPrefix("/private/tmp/neantik-dev-fixture."))
        try #require(root.deletingLastPathComponent().path == "/private/tmp")
        if FileManager.default.fileExists(atPath: root.path) {
            try #require(root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true)
            try #require(FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
        defer { if requested == nil { try? FileManager.default.removeItem(at: root) } }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let folder = try store.createFolder(named: "QA — тестовые профили")
        for index in 0..<8 {
            let profile = try store.upsert(BrowserProfile(
                name: index == 1 ? "QA — длинное имя для проверки списка, поиска и переноса текста в узком окне" : "QA — профиль \(index + 1)",
                tags: ["QA", index.isMultiple(of: 2) ? "Работа" : "Тест"],
                note: "Синтетический профиль. Не содержит аккаунтов, паролей или пользовательских данных.",
                isPinned: index == 0,
                isArchived: index == 7,
                startURL: "about:blank"
            ))
            if index < 4 { try store.assignProfile(profile.id, toFolderID: folder.id) }
        }
        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.hasTrustedMetadata)
        #expect(reloaded.hasTrustedOrganization)
        #expect(reloaded.profiles.count == 8)
        #expect(reloaded.profiles.filter(\.isPinned).count == 1)
        #expect(reloaded.profiles.filter(\.isArchived).count == 1)
        #expect(reloaded.profiles.allSatisfy { $0.startURL == "about:blank" && $0.proxy == nil })
        #expect(reloaded.organization.folders.count == 1)
    }
}
