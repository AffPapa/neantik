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
