import Foundation
import Testing
@testable import NeAntik

struct LiveBrowserProcessManagerIntegrationTests {
    @Test
    @MainActor
    func ordinaryPackagedProfileLaunchesAndStops() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEANTIK_RUN_LIVE_BROWSER_MANAGER"] == "1" else {
            return
        }
        guard let appPath = environment["NEANTIK_LIVE_AUDIT_APP"],
              !appPath.isEmpty
        else {
            Issue.record("NEANTIK_LIVE_AUDIT_APP is required.")
            return
        }

        let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
        let runtimeExecutable = appURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent("NeAntik Browser.app")
            .appendingPathComponent("Contents/MacOS/NeAntik Browser")
        guard FileManager.default.isExecutableFile(
            atPath: runtimeExecutable.path
        ) else {
            Issue.record("Packaged NeAntik runtime is unavailable.")
            return
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "neantik-live-browser-manager-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let paths = AppPaths(rootDirectory: temporaryRoot)
        try paths.prepareBaseDirectories()
        let profile = BrowserProfile(
            name: "Ordinary manager smoke",
            startURL: "http://127.0.0.1:9",
            identity: BrowserIdentity(seed: 21)
        )
        try paths.prepareProfileDirectories(for: profile.id)

        let runtime = BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: runtimeExecutable,
            source: "Packaged live integration test",
            flavor: .fingerprintChromium
        )
        let preflight = BrowserRuntimePreflightValidator.validate(runtime)
        #expect(preflight.isReady)

        let manager = BrowserProcessManager(paths: paths)
        defer {
            manager.stop(profileID: profile.id)
        }
        try manager.launch(
            profile: profile,
            runtime: runtime,
            additionalArguments: [
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=0",
                "--disable-background-networking",
                "--disable-component-update",
                "--disable-sync",
            ]
        )

        let portFile = paths.browserDataDirectory(for: profile.id)
            .appendingPathComponent("DevToolsActivePort")
        var browserBecameReady = false
        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: portFile.path),
               manager.processState(for: profile.id) == .managed
            {
                browserBecameReady = true
                break
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        #expect(browserBecameReady)
        #expect(manager.processState(for: profile.id) == .managed)

        manager.stop(profileID: profile.id)
        var browserStopped = false
        for _ in 0..<160 {
            if manager.processState(for: profile.id) == .stopped {
                browserStopped = true
                break
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        #expect(browserStopped)
        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }
}
