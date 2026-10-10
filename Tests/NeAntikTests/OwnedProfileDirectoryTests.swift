import Darwin
import Foundation
import Testing
@testable import NeAntik

struct OwnedProfileDirectoryTests {
    @Test func descriptorBudgetIncludesCurrentOpenFilesAndRejectsOverflow() throws {
        #expect(throws: Never.self) { try OwnedProfileDirectory.validateDescriptorBudget(profileCount: 5_000, limit: 16_000, openDescriptors: 100) }
        for (count, limit, open) in [(30, UInt64(64), 5), (5_000, 10_000, 5), (1, 64, 60), (Int.max, UInt64.max, 100), (-1, 64, 5)] {
            #expect(throws: ProfileCreationDescriptorBudgetError.self) { try OwnedProfileDirectory.validateDescriptorBudget(profileCount: count, limit: limit, openDescriptors: open) }
        }
    }
    private func fixture() throws -> AppPaths {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("neantik-owned-directory-" + UUID().uuidString)
        let paths = AppPaths(rootDirectory: root); try paths.prepareBaseDirectories(); return paths
    }
    @Test(arguments: [false, true]) func emptyOwnedPreparationRollsBack(prepared: Bool) throws {
        let paths = try fixture(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let id = UUID(), owned = try OwnedProfileDirectory(paths: paths, profileID: id)
        if prepared { try owned.prepareBrowserData() }
        try owned.removeEmptyOwnedDirectories()
        #expect(!FileManager.default.fileExists(atPath: paths.profileDirectory(for: id).path))
    }
    @Test(arguments: ["profile", "browser", "parent"])
    func foreignDirectoryReplacementIsNotRemoved(kind: String) throws {
        let paths = try fixture(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let id = UUID(), owned = try OwnedProfileDirectory(paths: paths, profileID: id)
        try owned.prepareBrowserData()
        let original = kind == "profile" ? paths.profileDirectory(for: id) : kind == "browser" ? paths.browserDataDirectory(for: id) : paths.profilesDirectory
        let held = paths.rootDirectory.appendingPathComponent("HeldOwnDirectory")
        try FileManager.default.moveItem(at: original, to: held)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let marker = original.appendingPathComponent("preserve")
        try Data("foreign synthetic bytes".utf8).write(to: marker)
        #expect(throws: (any Error).self) { try owned.removeEmptyOwnedDirectories() }
        #expect(try Data(contentsOf: marker) == Data("foreign synthetic bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: held.path))
    }
    @Test(arguments: ["browser-file", "root-file", "symlink", "fifo"])
    func unexpectedChildrenAreRetained(kind: String) throws {
        let paths = try fixture(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let id = UUID(), owned = try OwnedProfileDirectory(paths: paths, profileID: id)
        try owned.prepareBrowserData()
        let marker = (kind == "root-file" ? paths.profileDirectory(for: id) : paths.browserDataDirectory(for: id)).appendingPathComponent("preserve")
        if kind == "symlink" { try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: paths.rootDirectory.appendingPathComponent("ForeignTarget")) }
        else if kind == "fifo" { try #require(mkfifo(marker.path, 0o600) == 0) }
        else { try Data("unexpected synthetic bytes".utf8).write(to: marker) }
        #expect(throws: (any Error).self) { try owned.removeEmptyOwnedDirectories() }
        var value = stat(); #expect(lstat(marker.path, &value) == 0)
        if kind.hasSuffix("file") { #expect(try Data(contentsOf: marker) == Data("unexpected synthetic bytes".utf8)) }
    }
    @Test func preexistingDirectoryAndArbitraryAncestorSymlinkAreRefused() throws {
        let paths = try fixture(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let id = UUID(), owned = try OwnedProfileDirectory(paths: paths, profileID: id)
        try owned.prepareBrowserData()
        #expect(throws: (any Error).self) { _ = try OwnedProfileDirectory(paths: paths, profileID: id) }
        let held = paths.rootDirectory.appendingPathComponent("HeldProfiles")
        try FileManager.default.moveItem(at: paths.profilesDirectory, to: held)
        try FileManager.default.createSymbolicLink(at: paths.profilesDirectory, withDestinationURL: held)
        #expect(throws: (any Error).self) { _ = try OwnedProfileDirectory(paths: paths, profileID: UUID()) }
        #expect(FileManager.default.fileExists(atPath: held.appendingPathComponent(id.uuidString + "/BrowserData").path))
    }
    /// Run only in a separate SDK test helper. Never change the shared test
    /// process's limits or use production data to provoke resource exhaustion.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_OWNED_DIRECTORY_LOW_FD_FIXTURE"] == "1"))
    @MainActor func lowFDImportRefusesBeforeCreatingProfileDirectories() async throws {
        let paths = try fixture(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let store = ProfileStore(paths: paths)
        var limits = rlimit(); try #require(getrlimit(RLIMIT_NOFILE, &limits) == 0)
        let original = limits.rlim_cur; limits.rlim_cur = 64
        try #require(setrlimit(RLIMIT_NOFILE, &limits) == 0)
        defer { limits.rlim_cur = original; _ = setrlimit(RLIMIT_NOFILE, &limits) }
        await #expect(throws: (any Error).self) {
            try await store.insertImportedProfilesOffMainActor((0..<30).map { BrowserProfile(name: "Own limited fixture \($0)") }, folderNames: Array(repeating: nil, count: 30))
        }
        let residual = try FileManager.default.contentsOfDirectory(at: paths.profilesDirectory, includingPropertiesForKeys: nil)
        #expect(residual.isEmpty)
        #expect(store.profiles.isEmpty)
        print("OWNED_LOW_FD_IMPORT_PROOF {\"profileDirectoryResidues\":\(residual.count),\"metadataUnchanged\":\(store.profiles.isEmpty),\"childSoftFDLimit\":64}")
    }
}
