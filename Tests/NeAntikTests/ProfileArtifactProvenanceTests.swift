import Foundation
import Testing
@testable import NeAntik

struct ProfileArtifactProvenanceTests {
    @Test
    func inventoryIsBoundedAndDoesNotExposeExtensionIdentifiers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: profileID)
        let browserData = paths.browserDataDirectory(for: profileID)
        let downloads = browserData.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )
        let extensions = browserData
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(
                "abcdefghijklmnopabcdefghijklmnop",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: downloads,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: extensions,
            withIntermediateDirectories: true
        )
        try Data("file".utf8).write(
            to: downloads.appendingPathComponent("payload.bin")
        )
        try Data("manifest".utf8).write(
            to: extensions.appendingPathComponent("manifest.json")
        )

        let snapshot = ProfileArtifactProvenanceSnapshot.inspect(
            profileID: profileID,
            paths: paths
        )


        #expect(snapshot.downloads == .available(count: 1, bytes: 4))
        #expect(snapshot.extensions == .available(count: 1, bytes: 8))
        #expect(snapshot.quarantine == .empty)
        #expect(snapshot.quarantinePolicy == .explicitManagerActionOnly)
        #expect(!snapshot.extensions.title.contains("abcdefghijklmnop"))
    }

    @Test
    func extensionInventoryCountsTopLevelDirectoriesRatherThanFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-extension-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareProfileDirectories(for: profileID)
        let extensions = paths.browserDataDirectory(for: profileID)
            .appendingPathComponent("Default/Extensions", isDirectory: true)
        for id in ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] {
            let version = extensions.appendingPathComponent(id + "/1.0", isDirectory: true)
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: version.appendingPathComponent("manifest.json"))
        }
        try Data("more".utf8).write(to: extensions
            .appendingPathComponent("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0/content.js"))

        let snapshot = ProfileArtifactProvenanceSnapshot.inspect(
            profileID: profileID, paths: paths
        )
        #expect(snapshot.extensions == .available(count: 2, bytes: 8))
        #expect(!snapshot.extensions.title.contains("aaaaaaaa"))
    }

    @Test
    func backgroundInventoryPreservesTheSameBoundedResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-artifact-async-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareProfileDirectories(for: profileID)
        let downloads = paths.browserDataDirectory(for: profileID)
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: downloads.appendingPathComponent("sample.bin"))

        let expected = ProfileArtifactProvenanceSnapshot.inspect(
            profileID: profileID, paths: paths
        )
        let actual = try await ProfileArtifactProvenanceSnapshot.inspectAsync(
            profileID: profileID, paths: paths
        )
        #expect(actual == expected)
        #expect(actual.downloads == .available(count: 1, bytes: 9))
    }

    @Test
    func extensionInventoryRefusesSymlinkedAncestor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-extension-ancestor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareProfileDirectories(for: profileID)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let extensions = outside.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: extensions.appendingPathComponent("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            withIntermediateDirectories: true
        )
        let browserData = paths.browserDataDirectory(for: profileID)
        try FileManager.default.createSymbolicLink(
            at: browserData.appendingPathComponent("Default"),
            withDestinationURL: outside
        )

        let snapshot = ProfileArtifactProvenanceSnapshot.inspect(
            profileID: profileID, paths: paths
        )
        #expect(snapshot.extensions == .unavailable)
    }

    @Test
    func quarantineMovesOnlyAnExplicitSafeProfileArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: profileID)
        let source = paths.browserDataDirectory(for: profileID)
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("review.bin")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("review".utf8).write(to: source)

        let destination = try ProfileArtifactQuarantine.moveToQuarantine(
            source: source,
            profileID: profileID,
            paths: paths,
            reason: "Проверка пользователем"
        )

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(
            FileManager.default.fileExists(
                atPath: destination.deletingLastPathComponent()
                    .appendingPathComponent(destination.lastPathComponent + ".json")
                    .path
            )
        )
        #expect(
            !destination.path.contains("review.bin")
        )
    }

    @Test
    func quarantineRejectsAnArtifactOutsideTheProfileDataRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        let outside = root.appendingPathComponent("outside.bin")
        try Data("outside".utf8).write(to: outside)

        #expect(throws: ProfileArtifactQuarantineError.unsafeSource) {
            try ProfileArtifactQuarantine.moveToQuarantine(
                source: outside,
                profileID: profileID,
                paths: paths,
                reason: "Нельзя"
            )
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func quarantineRejectsFilesReachedThroughSymlinkedProfileFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: profileID)
        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        let target = external.appendingPathComponent("important.bin")
        try Data("keep".utf8).write(to: target)

        let downloads = paths.browserDataDirectory(for: profileID)
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: downloads,
            withDestinationURL: external
        )
        let source = downloads.appendingPathComponent("important.bin")

        #expect(throws: ProfileArtifactQuarantineError.unsafeSource) {
            try ProfileArtifactQuarantine.moveToQuarantine(
                source: source,
                profileID: profileID,
                paths: paths,
                reason: "Проверка пользователем"
            )
        }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }
}
