import Foundation
import Testing
@testable import NeAntik

struct ApplicationEnvironmentTests {
    @Test func developmentEnvironmentIsIsolated() {
        let development = NeAntikApplicationEnvironment.resolve(
            bundleIdentifier:
                NeAntikApplicationEnvironment.developmentBundleIdentifier
        )
        let production = NeAntikApplicationEnvironment.resolve(
            bundleIdentifier:
                NeAntikApplicationEnvironment.productionBundleIdentifier
        )

        #expect(development.isDevelopment)
        #expect(!production.isDevelopment)
        #expect(
            development.applicationSupportDirectoryName !=
                production.applicationSupportDirectoryName
        )
        #expect(development.keychainService != production.keychainService)
        #expect(development.legacyKeychainService == nil)
        #expect(
            development.applicationSupportRoot().path.contains(
                "NeAntik Development"
            )
        )
    }

    @Test func disposableRootIsDevelopmentOnly() {
        let values = ["NEANTIK_DEVELOPMENT_DATA_ROOT": "/private/tmp/neantik-ui-fixture"]
        let dev = NeAntikApplicationEnvironment.resolve(bundleIdentifier: nil)
        let production = NeAntikApplicationEnvironment.resolve(bundleIdentifier: NeAntikApplicationEnvironment.productionBundleIdentifier)
        #expect(dev.applicationSupportRoot(environment: values).path == values["NEANTIK_DEVELOPMENT_DATA_ROOT"])
        #expect(production.applicationSupportRoot(environment: values).path != values["NEANTIK_DEVELOPMENT_DATA_ROOT"])
    }

    @Test func disposableBundleRootSurvivesRelaunchWithoutEnvironment() {
        let root = "/private/tmp/neantik-ui-relaunch"
        let dev = NeAntikApplicationEnvironment.resolve(bundleIdentifier: nil)
        let production = NeAntikApplicationEnvironment.resolve(bundleIdentifier: NeAntikApplicationEnvironment.productionBundleIdentifier)
        #expect(dev.applicationSupportRoot(environment: [:], developmentFixtureRoot: root).path == root)
        #expect(production.applicationSupportRoot(environment: [:], developmentFixtureRoot: root).path != root)
        #expect(dev.applicationSupportRoot(environment: [:], developmentFixtureRoot: "/var/lib/production-data").path != "/var/lib/production-data")
    }

    @Test func existingDisposableRootPreservesLexicalPathForSafeCacheMaintenance() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("neantik-dev-fixture." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let dev = NeAntikApplicationEnvironment.resolve(bundleIdentifier: nil)
        let resolved = dev.applicationSupportRoot(environment: [:], developmentFixtureRoot: root.path)
        try #require(resolved.lastPathComponent == root.lastPathComponent)
        try #require(["/private/tmp", "/tmp"].contains(resolved.deletingLastPathComponent().path))
        #expect(resolved.path == root.path)
        let data = root.appendingPathComponent("Profiles/fixture/BrowserData", isDirectory: true)
        let file = data.appendingPathComponent("Default/Cache/item")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: file)
        let resolvedData = resolved.appendingPathComponent("Profiles/fixture/BrowserData", isDirectory: true)
        #expect(try ProfileCacheMaintenance(browserData: resolvedData).estimate().bytes == 5)
    }

    @Test func disposableRootAcceptsOnlyNamedTemporaryRootsWithoutTraversal() {
        let dev = NeAntikApplicationEnvironment.resolve(bundleIdentifier: nil)
        #expect(dev.applicationSupportRoot(environment: [:], developmentFixtureRoot: "/tmp/neantik-dev-fixture.alias").path == "/private/tmp/neantik-dev-fixture.alias")
        for unsafe in ["/private/tmp/neantik-../child", "/private/tmp/neantik-test/../other", "/tmp/../neantik-root", "/private/tmp/neantik-test\n", "/var/tmp/neantik-other"] {
            let resolved = dev.applicationSupportRoot(environment: [:], developmentFixtureRoot: unsafe)
            #expect(resolved.lastPathComponent == "NeAntik Development")
        }
    }

    @Test func releaseAuditStorageBelongsToValidatedAttempt() {
        let request = FingerprintEvidenceReleaseRequest(
            candidateManifestURL: URL(fileURLWithPath: "/private/tmp/neantik-attempt/manifest.json"),
            evidenceOutputURL: URL(fileURLWithPath: "/private/tmp/neantik-attempt/evidence.json"))
        #expect(request.managerDataRoot.path == "/private/tmp/neantik-attempt/manager-data")
    }

    @Test func unknownOrUnbundledExecutableIsIsolatedFromProduction() {
        let environment = NeAntikApplicationEnvironment.resolve(
            bundleIdentifier: "unexpected.bundle"
        )
        #expect(environment.isDevelopment)
        #expect(environment.bundleIdentifier == "app.neantik.desktop.dev")
        #expect(environment.keychainService == "app.neantik.dev.proxy")
        #expect(environment.legacyKeychainService == nil)

        let unbundled = NeAntikApplicationEnvironment.resolve(
            bundleIdentifier: nil
        )
        #expect(unbundled == environment)
    }
}
