import AppKit
import Darwin
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
        let storageOrigin = environment["NEANTIK_LIVE_STORAGE_ORIGIN"].flatMap(URL.init(string:))
        if let storageOrigin {
            try #require(storageOrigin.scheme == "http" && storageOrigin.host == "127.0.0.1")
            try #require(storageOrigin.port != nil && storageOrigin.user == nil && storageOrigin.password == nil)
        }
        let profile = BrowserProfile(
            name: "Ordinary manager smoke",
            startURL: storageOrigin?.absoluteString ?? "http://127.0.0.1:9",
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
                "--remote-allow-origins=http://neantik.local",
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
        try #require(browserBecameReady)
        if let storageOrigin {
            // A ready debug socket can precede the first page navigation.
            var written = false
            for _ in 0..<40 {
                if try await OwnedStorageRecoveryProbe.check(portFile: portFile, origin: storageOrigin, write: true) {
                    written = true
                    break
                }
                try await Task.sleep(nanoseconds: 125_000_000)
            }
            try #require(written)
            // localStorage acknowledgement is not a disk durability barrier.
            // Establish and independently reread a cleanly persisted baseline
            // before the crash scenario. Immediate-write loss is tracked in
            // the audit report rather than hidden by a timed flush assumption.
            if environment["NEANTIK_TEST_APP_QUIT"] == "1" {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let lease = try decoder.decode(BrowserProcessLock.self,
                    from: Data(contentsOf: paths.lockFile(for: profile.id)))
                try #require(lease.managerPID == getpid())
                try #require(lease.browserDataPath == paths.browserDataDirectory(for: profile.id).path)
                try #require(DarwinBrowserProcessInventoryProvider().capture().inspectProcess(lease) == .expected)
                let application = try #require(NSRunningApplication(processIdentifier: lease.pid))
                try #require(application.terminate())
            } else {
                manager.stop(profileID: profile.id)
            }
            for _ in 0..<160 {
                if manager.processState(for: profile.id) == .stopped { break }
                try await Task.sleep(nanoseconds: 125_000_000)
            }
            try #require(manager.processState(for: profile.id) == .stopped)
            if FileManager.default.fileExists(atPath: portFile.path) {
                try FileManager.default.removeItem(at: portFile)
            }
            try manager.launch(profile: profile, runtime: runtime, additionalArguments: [
                "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
                "--remote-allow-origins=http://neantik.local",
                "--disable-background-networking", "--disable-component-update", "--disable-sync",
            ])
            for _ in 0..<80 {
                if FileManager.default.fileExists(atPath: portFile.path) { break }
                try await Task.sleep(nanoseconds: 125_000_000)
            }
            var baselineRead = false
            for _ in 0..<40 {
                if try await OwnedStorageRecoveryProbe.check(portFile: portFile, origin: storageOrigin, write: false) {
                    baselineRead = true
                    break
                }
                try await Task.sleep(nanoseconds: 125_000_000)
            }
            try #require(baselineRead)
        }
        #expect(manager.processState(for: profile.id) == .managed)

        // Exercise real manager exclusion with the packaged runtime, not a
        // fake process inspector. Rejected launches must preserve the lease.
        let leaseBefore = try Data(contentsOf: paths.lockFile(for: profile.id))
        let startedBefore = try #require(manager.startedAt(for: profile.id))
        do {
            try manager.launch(profile: profile, runtime: runtime)
            Issue.record("The same manager accepted a duplicate launch.")
        } catch NeAntikError.profileAlreadyRunning {
            // Expected: only one browser may own this profile.
        }
        #expect(manager.startedAt(for: profile.id) == startedBefore)
        #expect(try Data(contentsOf: paths.lockFile(for: profile.id)) == leaseBefore)

        let competingManager = BrowserProcessManager(paths: paths)
        do {
            try competingManager.launch(profile: profile, runtime: runtime)
            competingManager.stop(profileID: profile.id)
            Issue.record("A competing manager accepted the locked profile.")
        } catch NeAntikError.profileAlreadyRunning {
            // Expected: the on-disk lease also excludes another manager.
        }
        #expect(manager.processState(for: profile.id) == .managed)
        #expect(manager.startedAt(for: profile.id) == startedBefore)
        #expect(try Data(contentsOf: paths.lockFile(for: profile.id)) == leaseBefore)

        // Simulate a browser crash only after independently verifying that
        // the lease still identifies our newly created synthetic profile.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lease = try decoder.decode(BrowserProcessLock.self, from: leaseBefore)
        try #require(lease.managerPID == getpid())
        try #require(lease.pid > 1 && lease.pid != getpid())
        try #require(lease.executablePath == runtimeExecutable.standardizedFileURL.path)
        try #require(lease.browserDataPath == paths.browserDataDirectory(for: profile.id).path)
        let sentinel = paths.browserDataDirectory(for: profile.id)
            .appendingPathComponent("owned-recovery-sentinel.txt")
        let sentinelBytes = Data("synthetic crash recovery marker".utf8)
        try sentinelBytes.write(to: sentinel, options: .atomic)
        try #require(
            DarwinBrowserProcessInventoryProvider().capture().inspectProcess(lease) == .expected
        )
        try #require(Darwin.kill(lease.pid, SIGKILL) == 0)
        for _ in 0..<160 {
            if manager.processState(for: profile.id) == .stopped { break }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        try #require(manager.processState(for: profile.id) == .stopped)
        #expect(manager.lastBrowserExit?.classification == .crashOrSignal)
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(!FileManager.default.fileExists(atPath: paths.lockFile(for: profile.id).path))

        // Avoid treating the previous process's DevTools marker as readiness.
        if FileManager.default.fileExists(atPath: portFile.path) {
            try FileManager.default.removeItem(at: portFile)
        }
        try manager.launch(profile: profile, runtime: runtime, additionalArguments: [
            "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
            "--remote-allow-origins=http://neantik.local",
            "--disable-background-networking", "--disable-component-update", "--disable-sync",
        ])
        var restarted = false
        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: portFile.path),
               manager.processState(for: profile.id) == .managed {
                restarted = true
                break
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        try #require(restarted)
        if let storageOrigin {
            var readReady = false
            for _ in 0..<40 {
                if try await OwnedStorageRecoveryProbe.check(portFile: portFile, origin: storageOrigin, write: false) {
                    readReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 125_000_000)
            }
            try #require(readReady)
        }
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        let newLease = try decoder.decode(
            BrowserProcessLock.self, from: Data(contentsOf: paths.lockFile(for: profile.id))
        )
        #expect(newLease.ownerToken != lease.ownerToken)
        #expect(newLease.browserDataPath == lease.browserDataPath)

        manager.stop(profileID: profile.id)
        var browserStopped = false
        for _ in 0..<160 {
            if manager.processState(for: profile.id) == .stopped {
                browserStopped = true
                break
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        try #require(browserStopped)
        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )

        let browserData = paths.browserDataDirectory(for: profile.id)
        var dataIsUnused = false
        for _ in 0..<40 {
            if DarwinBrowserProcessInventoryProvider().capture()
                .inspectBrowserDataProcess(browserData) == .absent {
                dataIsUnused = true
                break
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        try #require(dataIsUnused)
        let snapshots = AtomicProfileSnapshotStore(rootDirectory: temporaryRoot)
        let snapshot = try snapshots.create(
            profileID: profile.id, browserData: browserData,
            runtimeVersion: "153.0.8010.36"
        )
        let changedBytes = Data("synthetic later state".utf8)
        try changedBytes.write(to: sentinel, options: .atomic)
        let laterSnapshot = try snapshots.create(
            profileID: profile.id, browserData: browserData,
            runtimeVersion: "153.0.8010.36"
        )
        #expect(try snapshots.restore(
            snapshot: snapshot, to: browserData, profileID: profile.id
        ) == "153.0.8010.36")
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(try Data(contentsOf: laterSnapshot.appendingPathComponent(
            "owned-recovery-sentinel.txt"
        )) == changedBytes)
        if FileManager.default.fileExists(atPath: portFile.path) {
            try FileManager.default.removeItem(at: portFile)
        }
        try manager.launch(profile: profile, runtime: runtime, additionalArguments: [
            "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
            "--remote-allow-origins=http://neantik.local",
            "--disable-background-networking", "--disable-component-update", "--disable-sync",
        ])
        var restoredProfileReady = false
        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: portFile.path),
               manager.processState(for: profile.id) == .managed {
                restoredProfileReady = true
                break
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        try #require(restoredProfileReady)
        if let storageOrigin {
            var readReady = false
            for _ in 0..<40 {
                if try await OwnedStorageRecoveryProbe.check(portFile: portFile, origin: storageOrigin, write: false) {
                    readReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 125_000_000)
            }
            try #require(readReady)
        }
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        manager.stop(profileID: profile.id)
        for _ in 0..<160 {
            if manager.processState(for: profile.id) == .stopped { break }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        try #require(manager.processState(for: profile.id) == .stopped)
    }
}
