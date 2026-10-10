import Foundation
import Testing
@testable import NeAntik

#if DEBUG
struct DevelopmentFixtureBackupScopeTests {
    @Test func explicitDisposableScopePersistsAcrossInstancesWithoutSystemKeychain() throws {
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-dev-fixture.backup-scope-" + UUID().uuidString))
        try paths.prepareBaseDirectories(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let environment = NeAntikApplicationEnvironment.resolve(bundleIdentifier: NeAntikApplicationEnvironment.developmentBundleIdentifier)
        try #require(KeychainStore.usesDisposableDevelopmentBackend(environment: environment, paths: paths, fixtureRoot: paths.rootDirectory.path))
        let first = BackupCompatibilityScopeStore.applicationStore(environment: environment, paths: paths, fixtureRoot: paths.rootDirectory.path)
        let digest = try first.digest(createForExport: true)
        let second = BackupCompatibilityScopeStore.applicationStore(environment: environment, paths: paths, fixtureRoot: paths.rootDirectory.path)
        #expect(try second.digest(createForExport: false) == digest)
    }
    @Test func corruptOrSymlinkFixtureScopeIsNotRepaired() throws {
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-dev-fixture.backup-scope-" + UUID().uuidString))
        try paths.prepareBaseDirectories(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let backend = DevelopmentFixtureBackupScope(paths: paths)
        let file = paths.rootDirectory.appendingPathComponent(".browser-data-backup-fixture-scope")
        try paths.writePrivateFile(Data([1]), to: file)
        #expect(throws: (any Error).self) { try BackupCompatibilityScopeStore(backend: backend).digest(createForExport: true) }
        #expect(try Data(contentsOf: file) == Data([1]))
        try FileManager.default.removeItem(at: file)
        let other = paths.rootDirectory.appendingPathComponent("own-target"); try paths.writePrivateFile(Data(repeating: 5, count: 32), to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        #expect(throws: (any Error).self) { try BackupCompatibilityScopeStore(backend: backend).digest(createForExport: true) }
        #expect(try Data(contentsOf: other) == Data(repeating: 5, count: 32))
    }
}
#endif
