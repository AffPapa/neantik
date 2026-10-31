import Foundation
import Testing
@testable import NeAntik

@MainActor
struct RuntimePreferenceStoreTests {
    @Test
    func persistsExplicitRuntimeFlavor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let defaults = try #require(
            UserDefaults(suiteName: "NeAntikTests.\(UUID().uuidString)")
        )
        let store = RuntimePreferenceStore(
            paths: paths,
            defaults: defaults
        )

        try store.select(
            path: "/Applications/Fingerprint Chromium.app",
            flavor: .fingerprintChromium
        )

        let reloaded = RuntimePreferenceStore(
            paths: paths,
            defaults: defaults
        )
        #expect(
            reloaded.preference?.path ==
                "/Applications/Fingerprint Chromium.app"
        )
        #expect(reloaded.preference?.flavor == .fingerprintChromium)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.runtimePreferenceFile.path
        )
        #expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
    }

    @Test
    func migratesLegacyFingerprintToggle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "NeAntikTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            "/Applications/Legacy Chromium.app",
            forKey: "customBrowserPath"
        )
        defaults.set(true, forKey: "customBrowserFingerprintMode")

        let store = RuntimePreferenceStore(
            paths: AppPaths(rootDirectory: root),
            defaults: defaults
        )

        #expect(
            store.preference?.path ==
                "/Applications/Legacy Chromium.app"
        )
        #expect(store.preference?.flavor == .fingerprintChromium)
    }

    @Test
    func rollsBackSelectionWhenPersistenceFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let defaults = try #require(
            UserDefaults(suiteName: "NeAntikTests.\(UUID().uuidString)")
        )
        let store = RuntimePreferenceStore(
            paths: paths,
            defaults: defaults
        )
        try FileManager.default.createDirectory(
            at: paths.runtimePreferenceFile,
            withIntermediateDirectories: false
        )

        #expect(throws: (any Error).self) {
            try store.select(
                path: "/Applications/Chromium.app",
                flavor: .standard
            )
        }
        #expect(store.preference == nil)
    }
}
