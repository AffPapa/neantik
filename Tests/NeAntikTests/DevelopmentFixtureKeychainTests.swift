import Foundation
import Testing
@testable import NeAntik

struct DevelopmentFixtureKeychainTests {
    @Test func productionAndNonfixtureRootsCannotSelectDisposableBackend() {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-dev-fixture.synthetic", isDirectory: true)
        let paths = AppPaths(rootDirectory: root)
        let production = NeAntikApplicationEnvironment.resolve(bundleIdentifier: "app.neantik.desktop")
        let development = NeAntikApplicationEnvironment.resolve(bundleIdentifier: "app.neantik.desktop.dev")
        #expect(!KeychainStore.usesDisposableDevelopmentBackend(environment: production, paths: paths, fixtureRoot: root.path))
        #if DEBUG
        #expect(KeychainStore.usesDisposableDevelopmentBackend(environment: development, paths: AppPaths(rootDirectory: URL(fileURLWithPath: root.path, isDirectory: false)), fixtureRoot: root.path))
        #endif
        #expect(!KeychainStore.usesDisposableDevelopmentBackend(environment: development, paths: paths, fixtureRoot: nil))
        #expect(!KeychainStore.usesDisposableDevelopmentBackend(environment: development, paths: paths, fixtureRoot: "/private/tmp/neantik-dev-fixture.other"))
        #expect(!KeychainStore.usesDisposableDevelopmentBackend(environment: development, paths: AppPaths(rootDirectory: URL(fileURLWithPath: "/not-a-temp-fixture")), fixtureRoot: "/not-a-temp-fixture"))
        #expect(KeychainStore.disposableBrowserArguments(environment: production, paths: paths, fixtureRoot: root.path).isEmpty)
        #expect(KeychainStore.disposableBrowserArguments(environment: development, paths: paths, fixtureRoot: nil).isEmpty)
        #expect(KeychainStore.disposableBrowserArguments(environment: development, paths: paths, fixtureRoot: "/private/tmp/neantik-dev-fixture.other").isEmpty)
        #if DEBUG
        #expect(KeychainStore.disposableBrowserArguments(environment: development, paths: paths, fixtureRoot: root.path) == ["--use-mock-keychain"])
        #endif
    }

    @Test func disposableBackendKeepsOnlySyntheticSecretsInMemory() throws {
        #if DEBUG
        let root = URL(fileURLWithPath: "/private/tmp/neantik-dev-fixture.synthetic", isDirectory: true)
        let environment = NeAntikApplicationEnvironment.resolve(bundleIdentifier: "app.neantik.desktop.dev")
        let paths = AppPaths(rootDirectory: root)
        try #require(KeychainStore.usesDisposableDevelopmentBackend(environment: environment, paths: paths, fixtureRoot: root.path))
        let first = KeychainStore.applicationStore(environment: environment, paths: paths, fixtureRoot: root.path)
        let profile = UUID()
        try first.saveProxyPassword("synthetic-password", profileID: profile)
        #expect(try first.proxyPassword(profileID: profile) == "synthetic-password")
        let nextProcessFixture = KeychainStore.applicationStore(environment: environment, paths: paths, fixtureRoot: root.path)
        #expect(try nextProcessFixture.proxyPassword(profileID: profile) == nil)
        try first.deleteProxyPassword(profileID: profile)
        #expect(try first.proxyPassword(profileID: profile) == nil)
        #endif
    }
}
