import Foundation
import Testing
@testable import NeAntik

struct ManagerStartupProbeTests {
    @Test func acceptsOnlyBoundedTemporaryJSONPath() {
        #expect(
            ManagerStartupProbe.validatedOutputURL(
                "/private/tmp/neantik-startup-run/ready.json"
            ) != nil
        )
        #expect(
            ManagerStartupProbe.validatedOutputURL(
                "/Users/alice/Desktop/ready.json"
            ) == nil
        )
        #expect(
            ManagerStartupProbe.validatedOutputURL(
                "/private/tmp/neantik-startup-run/../secret.json"
            ) == nil
        )
        #expect(
            ManagerStartupProbe.validatedOutputURL(
                "/private/tmp/neantik-startup-run/ready.txt"
            ) == nil
        )
    }

    @Test func isolationRequiresPrivateSiblingDataRootAndUniqueService() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "neantik-startup-\(UUID().uuidString)",
                isDirectory: true
            )
        let dataRoot = root.appendingPathComponent("data-0", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = [
            ManagerStartupProbe.readyEnvironmentKey:
                root.appendingPathComponent("ready-0.json").path,
            ManagerStartupProbe.dataRootEnvironmentKey: dataRoot.path,
            ManagerStartupProbe.keychainServiceEnvironmentKey:
                "app.neantik.dev.startup.test.0",
        ]
        let validatedReady = ManagerStartupProbe.validatedOutputURL(
            environment[ManagerStartupProbe.readyEnvironmentKey]!
        )
        let validatedRoot = ManagerStartupProbe.validatedDataRoot(
            environment[ManagerStartupProbe.dataRootEnvironmentKey]!
        )
        #expect(validatedReady != nil)
        #expect(validatedRoot != nil)
        #expect(
            ManagerStartupProbe.validatedKeychainService(
                environment[
                    ManagerStartupProbe.keychainServiceEnvironmentKey
                ]!
            )
        )
        #expect(
            validatedReady?.deletingLastPathComponent()
                .resolvingSymlinksInPath().path ==
                validatedRoot?.deletingLastPathComponent()
                    .resolvingSymlinksInPath().path
        )
        let configuration = ManagerStartupProbe.isolationConfiguration(
            environment: environment,
            bundleIdentifier:
                NeAntikApplicationEnvironment.developmentBundleIdentifier
        )
        #expect(configuration?.dataRoot == dataRoot.standardizedFileURL)

        #expect(
            ManagerStartupProbe.isolationConfiguration(
                environment: environment.merging([
                    ManagerStartupProbe.keychainServiceEnvironmentKey:
                        "app.neantik.dev.proxy",
                ]) { _, replacement in replacement },
                bundleIdentifier:
                    NeAntikApplicationEnvironment.developmentBundleIdentifier
            ) == nil
        )
    }
}
