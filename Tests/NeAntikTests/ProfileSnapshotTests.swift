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
}
