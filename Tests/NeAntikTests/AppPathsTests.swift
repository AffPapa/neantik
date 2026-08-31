import Foundation
import Testing
@testable import NeAntik

struct AppPathsTests {
    @Test
    func migratesLegacyRootWhenMoveSucceeds() throws {
        let applicationSupport = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let legacy = applicationSupport.appendingPathComponent("NeVision")
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        try Data("[]".utf8).write(
            to: legacy.appendingPathComponent("profiles.json")
        )

        let paths = AppPaths(
            applicationSupportDirectory: applicationSupport
        )

        #expect(paths.rootDirectory.lastPathComponent == "NeAntik")
        #expect(paths.migrationWarning == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.profilesFile.path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test
    func keepsLegacyRootWhenMoveFails() throws {
        let applicationSupport = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let legacy = applicationSupport.appendingPathComponent("NeVision")
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        try Data("[]".utf8).write(
            to: legacy.appendingPathComponent("profiles.json")
        )

        let paths = AppPaths(
            applicationSupportDirectory: applicationSupport,
            moveLegacy: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        )

        #expect(
            paths.rootDirectory.standardizedFileURL.path ==
                legacy.standardizedFileURL.path
        )
        #expect(paths.migrationWarning != nil)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.profilesFile.path
            )
        )
    }

    @Test
    func prefersLegacyProfilesOverEmptyPartialCurrentRoot() throws {
        let applicationSupport = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let current = applicationSupport.appendingPathComponent("NeAntik")
        let legacy = applicationSupport.appendingPathComponent("NeVision")
        try FileManager.default.createDirectory(
            at: current,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        try Data("[]".utf8).write(
            to: legacy.appendingPathComponent("profiles.json")
        )

        let paths = AppPaths(
            applicationSupportDirectory: applicationSupport
        )

        #expect(
            paths.rootDirectory.standardizedFileURL.path ==
                legacy.standardizedFileURL.path
        )
        #expect(paths.migrationWarning != nil)
    }

    @Test
    func doesNotMergeTwoProfileStoresAutomatically() throws {
        let applicationSupport = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let current = applicationSupport.appendingPathComponent("NeAntik")
        let legacy = applicationSupport.appendingPathComponent("NeVision")
        for root in [current, legacy] {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try Data("[]".utf8).write(
                to: root.appendingPathComponent("profiles.json")
            )
        }

        let paths = AppPaths(
            applicationSupportDirectory: applicationSupport
        )

        #expect(
            paths.rootDirectory.standardizedFileURL.path ==
                current.standardizedFileURL.path
        )
        #expect(paths.migrationWarning != nil)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test
    func hardensExistingRegularLogsWithoutFollowingSymlinks() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
            .appendingPathComponent("outside.log")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let paths = AppPaths(rootDirectory: root)
        try FileManager.default.createDirectory(
            at: paths.logsDirectory,
            withIntermediateDirectories: true
        )
        let inherited = paths.logsDirectory.appendingPathComponent("old.log")
        try Data("legacy".utf8).write(to: inherited)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: inherited.path
        )
        try FileManager.default.createDirectory(
            at: outside.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: outside)
        let link = paths.logsDirectory.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        try paths.prepareBaseDirectories()

        let inheritedMode = try FileManager.default.attributesOfItem(
            atPath: inherited.path
        )[.posixPermissions] as? NSNumber
        let outsideMode = try FileManager.default.attributesOfItem(
            atPath: outside.path
        )[.posixPermissions] as? NSNumber
        #expect(inheritedMode?.intValue == 0o600)
        #expect(outsideMode?.intValue != 0o600)
    }

    @Test
    func createsPrivateStableProcessLockDirectoryAndGuard() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()

        try paths.prepareBaseDirectories()
        try paths.withProcessLockGuard(for: profileID) {}
        try paths.withProfilesMetadataGuard {}

        let directoryMode = try FileManager.default.attributesOfItem(
            atPath: paths.processLocksDirectory.path
        )[.posixPermissions] as? NSNumber
        let guardMode = try FileManager.default.attributesOfItem(
            atPath: paths.lockGuardFile(for: profileID).path
        )[.posixPermissions] as? NSNumber
        let metadataGuardMode = try FileManager.default.attributesOfItem(
            atPath: paths.profilesMetadataGuardFile.path
        )[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(guardMode?.intValue == 0o600)
        #expect(metadataGuardMode?.intValue == 0o600)
        #expect(
            paths.lockGuardFile(for: profileID)
                .deletingLastPathComponent() ==
                paths.processLocksDirectory
        )
    }

    @Test
    func privateReaderReturnsExactRegularFileBytes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let file = root.appendingPathComponent("private.json")
        let expected = Data("{\"ok\":true}".utf8)
        try paths.writePrivateFile(expected, to: file)

        let observed = try paths.readPrivateFile(
            file,
            maximumBytes: 1_024
        )

        #expect(observed == expected)
    }

    @Test
    func privateReaderRejectsSymlinkAndHardLinkWithoutReadingTarget() throws {
        let root = temporaryDirectory()
        let outsideRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        try FileManager.default.createDirectory(
            at: outsideRoot,
            withIntermediateDirectories: true
        )
        let outside = outsideRoot.appendingPathComponent("secret.json")
        let secret = Data("never-read".utf8)
        try secret.write(to: outside)

        let symlink = root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: outside
        )
        #expect(throws: (any Error).self) {
            _ = try paths.readPrivateFile(
                symlink,
                maximumBytes: 1_024
            )
        }

        let hardLink = root.appendingPathComponent("hardlink.json")
        try FileManager.default.linkItem(at: outside, to: hardLink)
        #expect(throws: (any Error).self) {
            _ = try paths.readPrivateFile(
                hardLink,
                maximumBytes: 1_024
            )
        }
        #expect(try Data(contentsOf: outside) == secret)
    }

    @Test
    func privateReaderEnforcesMaximumBeforeAllocatingFileSize() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let file = root.appendingPathComponent("oversized.json")
        try paths.writePrivateFile(
            Data(repeating: 0x41, count: 4_096),
            to: file
        )

        #expect(throws: (any Error).self) {
            _ = try paths.readPrivateFile(
                file,
                maximumBytes: 1_024
            )
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
    }
}
