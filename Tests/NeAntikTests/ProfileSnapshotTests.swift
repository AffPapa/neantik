import Foundation
import Testing
@testable import NeAntik

struct ProfileSnapshotTests {
    @Test
    func snapshotsKeepOnlyThreeNewestMetadataOnlyVersions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-snapshot-\(UUID().uuidString)")
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(
            name: "Рабочий snapshot",
            note: "не должна попасть в snapshot",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: "user"
            ),
            identity: BrowserIdentity(seed: 12345)
        )

        for offset in 1...4 {
            _ = try ProfileSnapshotStore.save(
                profiles: [profile],
                folderNameByProfileID: [:],
                paths: paths,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset))
            )
        }

        let snapshots = try ProfileSnapshotStore.snapshots(paths: paths)
        #expect(snapshots.count == 3)
        #expect(snapshots.first?.lastPathComponent.contains("1800000004") == true)
        let raw = try Data(contentsOf: try #require(snapshots.first))
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.contains("не должна попасть"))
        #expect(!text.contains("runtimeSeed"))
        #expect(!text.contains("BrowserData"))
    }

    @Test
    func restoreCreatesFreshIdentityAndFailsClosedForCorruption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-snapshot-\(UUID().uuidString)")
        let paths = AppPaths(rootDirectory: root)
        let original = BrowserProfile(
            name: "Восстановление",
            note: "не восстанавливать",
            identity: BrowserIdentity(seed: 67890)
        )
        let snapshotURL = try ProfileSnapshotStore.save(
            profiles: [original],
            folderNameByProfileID: [:],
            paths: paths,
            createdAt: Date(timeIntervalSince1970: 1_800_000_010)
        )
        let restored = try ProfileSnapshotStore.restore(
            from: snapshotURL,
            paths: paths,
            now: Date(timeIntervalSince1970: 1_800_000_020)
        )
        let copy = try #require(restored.first)
        #expect(copy.id != original.id)
        #expect(copy.identity.runtimeSeed != original.identity.runtimeSeed)
        #expect(copy.note.isEmpty)
        #expect(copy.lastLaunchedAt == nil)

        let corrupt = paths.profileSnapshotsDirectory
            .appendingPathComponent("snapshot-1800000099-corrupt.json")
        try paths.writePrivateFile(Data("broken".utf8), to: corrupt)
        #expect(throws: ProfileSnapshotError.invalidFile) {
            try ProfileSnapshotStore.restore(from: corrupt, paths: paths)
        }
    }

    @Test
    func backgroundRestorePreparationPreservesFolderAndCreatesFreshIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-snapshot-async-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(
            name: "Рабочее место",
            identity: BrowserIdentity(seed: 42)
        )
        let snapshotURL = try ProfileSnapshotStore.save(
            profiles: [profile],
            folderNameByProfileID: [profile.id: "Работа"],
            paths: paths,
            createdAt: Date(timeIntervalSince1970: 1_800_000_030)
        )

        let prepared = try await ProfileSnapshotFileService.prepareRestore(
            from: snapshotURL,
            paths: paths,
            now: Date(timeIntervalSince1970: 1_800_000_040)
        )

        let restored = try #require(prepared.profiles.first)
        #expect(prepared.profiles.count == 1)
        #expect(prepared.folderNames == ["Работа"])
        #expect(restored.id != profile.id)
        #expect(restored.identity.runtimeSeed != profile.identity.runtimeSeed)
        #expect(restored.note.isEmpty)
        #expect(restored.lastLaunchedAt == nil)
    }

    @Test
    func backgroundRestorePreparationRejectsExternalAndSymlinkFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-snapshot-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let external = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: external)

        await #expect(throws: ProfileSnapshotError.unsafeLocation) {
            try await ProfileSnapshotFileService.prepareRestore(
                from: external,
                paths: paths
            )
        }

        let linked = paths.profileSnapshotsDirectory
            .appendingPathComponent("snapshot-1800000040-linked.json")
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: external
        )
        await #expect(throws: ProfileSnapshotError.invalidFile) {
            try await ProfileSnapshotFileService.prepareRestore(
                from: linked,
                paths: paths
            )
        }
    }

    @Test
    func missingSnapshotReadReturnsSanitizedError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-snapshot-missing-\(UUID().uuidString)")
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let missing = paths.profileSnapshotsDirectory
            .appendingPathComponent("snapshot-1800000050-missing.json")

        #expect(throws: ProfileSnapshotError.invalidFile) {
            try ProfileSnapshotStore.document(from: missing, paths: paths)
        }
    }

    @Test
    func backgroundSaveWritesAValidatedMetadataOnlySnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-snapshot-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(
            name: "Сохранённый профиль",
            note: "private note must not be included",
            identity: BrowserIdentity(seed: 123)
        )

        let savedURL = try await ProfileSnapshotFileService.save(
            profiles: [profile],
            folderNameByProfileID: [:],
            paths: paths
        )
        let data = try Data(contentsOf: savedURL)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Сохранённый профиль"))
        #expect(!text.contains("private note"))
        #expect(!text.contains("runtimeSeed"))
        #expect(!text.localizedCaseInsensitiveContains("browserdata"))
        let snapshots = try ProfileSnapshotStore.snapshots(paths: paths)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.lastPathComponent == savedURL.lastPathComponent)
    }
}
