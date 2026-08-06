import Darwin
import Foundation
import Testing
@testable import NeAntik

@MainActor
struct BrowserProcessManagerTests {
    @Test
    func browserDataArgumentMatchingIsExact() {
        let expected = "/tmp/NeAntik/Profile A/BrowserData"

        #expect(
            BrowserProcessManager.arguments(
                ["browser", "--user-data-dir=\(expected)"],
                useBrowserDataPath: expected
            )
        )
        #expect(
            BrowserProcessManager.arguments(
                ["browser", "--user-data-dir", expected],
                useBrowserDataPath: expected
            )
        )
        #expect(
            !BrowserProcessManager.arguments(
                ["browser", "--user-data-dir=\(expected)-other"],
                useBrowserDataPath: expected
            )
        )
        #expect(
            !BrowserProcessManager.arguments(
                [
                    "browser",
                    "--description=--user-data-dir=\(expected)"
                ],
                useBrowserDataPath: expected
            )
        )
    }

    @Test
    func tracksProcessAndRemovesLockAfterExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 0.15\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )

        let paths = AppPaths(rootDirectory: root.appendingPathComponent("data"))
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let profile = BrowserProfile(name: "Process")
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )

        try manager.launch(profile: profile, runtime: runtime)

        #expect(manager.runningProfileIDs.contains(profile.id))
        #expect(manager.processState(for: profile.id) == .managed)
        #expect(FileManager.default.fileExists(atPath: paths.lockFile(for: profile.id).path))
        let lockData = try Data(contentsOf: paths.lockFile(for: profile.id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lock = try decoder.decode(
            BrowserProcessLock.self,
            from: lockData
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.lockFile(for: profile.id).path
        )
        #expect(lock.browserDataPath == paths.browserDataDirectory(for: profile.id).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        for _ in 0..<30 {
            if !manager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(!FileManager.default.fileExists(atPath: paths.lockFile(for: profile.id).path))
    }

    @Test
    func launchRecreatesMissingProfileDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 0.15\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )

        let paths = AppPaths(rootDirectory: root.appendingPathComponent("data"))
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let profile = BrowserProfile(name: "Новый профиль")
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )

        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )
        )

        try manager.launch(profile: profile, runtime: runtime)

        #expect(
            FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: paths.browserDataDirectory(for: profile.id).path
            )
        )
        #expect(manager.runningProfileIDs.contains(profile.id))

        for _ in 0..<30 {
            if !manager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(!manager.runningProfileIDs.contains(profile.id))
    }

    @Test
    func temporaryAuditLaunchDoesNotLeaveSyntheticProfileDirectory()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 0.1\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )

        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let profile = BrowserProfile(name: "Временная проверка")
        let temporaryBrowserData =
            try manager.reserveFingerprintAuditDataDirectory()
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )

        try manager.launch(
            profile: profile,
            runtime: runtime,
            browserDataDirectoryOverride: temporaryBrowserData,
            purpose: .fingerprintAudit(httpLoopbackPort: 32_123)
        )

        #expect(
            FileManager.default.fileExists(
                atPath: temporaryBrowserData.path
            )
        )

        for _ in 0..<30 {
            if !manager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )
        )
    }

    @Test
    func freshAuditDirectoryAllowsUnknownInventoryWithoutWeakeningProfiles()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 0.1\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .unknown }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )
        let auditProfile = BrowserProfile(name: "Audit")
        let auditDirectory =
            try manager.reserveFingerprintAuditDataDirectory()

        try manager.launch(
            profile: auditProfile,
            runtime: runtime,
            browserDataDirectoryOverride: auditDirectory,
            purpose: .fingerprintAudit(httpLoopbackPort: 32_123)
        )
        #expect(manager.runningProfileIDs.contains(auditProfile.id))

        let normalProfile = BrowserProfile(name: "Normal")
        #expect(throws: NeAntikError.self) {
            try manager.launch(
                profile: normalProfile,
                runtime: runtime
            )
        }
    }

    @Test
    func freshAuditDirectoryStillRejectsKnownOccupant() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .found }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )
        let profile = BrowserProfile(name: "Occupied audit")
        let auditDirectory =
            try manager.reserveFingerprintAuditDataDirectory()

        #expect(throws: NeAntikError.self) {
            try manager.launch(
                profile: profile,
                runtime: runtime,
                browserDataDirectoryOverride: auditDirectory,
                purpose: .fingerprintAudit(httpLoopbackPort: 32_123)
            )
        }
    }

    @Test
    func reconcilesOnlyTheExactProfileProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 3\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )

        let paths = AppPaths(rootDirectory: root.appendingPathComponent("data"))
        let firstManager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let profile = BrowserProfile(name: "Reconcile")
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )
        try firstManager.launch(profile: profile, runtime: runtime)

        let restoredManager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { lock in
                lock.pid > 0 &&
                    (Darwin.kill(lock.pid, 0) == 0 || errno == EPERM) &&
                    lock.executablePath == fakeBrowser.path &&
                    lock.browserDataPath ==
                        paths.browserDataDirectory(for: profile.id).path
            },
            browserDataProcessInspector: { _ in .absent }
        )
        restoredManager.reconcile(profiles: [profile])
        #expect(restoredManager.runningProfileIDs.contains(profile.id))
        #expect(
            restoredManager.processState(for: profile.id) ==
                .externalVerified
        )

        restoredManager.stop(profileID: profile.id)
        for _ in 0..<30 {
            if !restoredManager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(!restoredManager.runningProfileIDs.contains(profile.id))
        #expect(restoredManager.processState(for: profile.id) == .stopped)
    }

    @Test
    func removesLockPointingAtAnUnrelatedLivePID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Stale")
        try paths.prepareProfileDirectories(for: profile.id)

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["2"]
        try unrelated.run()
        defer {
            if unrelated.isRunning {
                unrelated.terminate()
            }
        }

        let lock = BrowserProcessLock(
            pid: unrelated.processIdentifier,
            executablePath: "/bin/sleep",
            browserDataPath: paths.browserDataDirectory(for: profile.id).path,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(lock),
            to: paths.lockFile(for: profile.id)
        )

        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in true },
            browserDataProcessInspector: { _ in .absent }
        )
        manager.reconcile(profiles: [profile])

        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
        #expect(unrelated.isRunning)
    }

    @Test
    func rejectsInvalidPersistedProxyBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = BrowserProfile(
            name: "Invalid proxy",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example, EXCLUDE attacker.example",
                port: 8_080,
                username: ""
            )
        )
        let runtime = BrowserRuntime(
            name: "Never launched",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            source: "Test"
        )
        let manager = BrowserProcessManager(
            paths: AppPaths(rootDirectory: root)
        )

        #expect(throws: NeAntikError.self) {
            try manager.launch(profile: profile, runtime: runtime)
        }
        #expect(!manager.runningProfileIDs.contains(profile.id))
    }

    @Test
    func keepsExternalProfileLockedUntilProcessActuallyExits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Slow stop")
        try paths.prepareProfileDirectories(for: profile.id)
        let lock = BrowserProcessLock(
            pid: 42,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath: paths.browserDataDirectory(for: profile.id).path,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(lock),
            to: paths.lockFile(for: profile.id)
        )

        var isAlive = true
        var sentSignal: Int32?
        let restored = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: {
                $0.pid == lock.pid &&
                    $0.executablePath == lock.executablePath &&
                    $0.browserDataPath == lock.browserDataPath
            },
            processLivenessValidator: { _ in isAlive },
            processSignaler: { _, signal in
                sentSignal = signal
                return 0
            },
            browserDataProcessInspector: { _ in .absent }
        )
        restored.reconcile(profiles: [profile])
        #expect(restored.runningProfileIDs.contains(profile.id))
        #expect(
            restored.processState(for: profile.id) == .externalVerified
        )

        restored.stop(profileID: profile.id)
        #expect(sentSignal == SIGTERM)
        #expect(restored.runningProfileIDs.contains(profile.id))
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(restored.runningProfileIDs.contains(profile.id))

        isAlive = false
        for _ in 0..<10 {
            if !restored.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(!restored.runningProfileIDs.contains(profile.id))
        #expect(restored.processState(for: profile.id) == .stopped)
    }

    @Test
    func observesNaturalExitOfReconciledProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Observed")
        try paths.prepareProfileDirectories(for: profile.id)
        let lock = BrowserProcessLock(
            pid: 84,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath: paths.browserDataDirectory(for: profile.id).path,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(lock),
            to: paths.lockFile(for: profile.id)
        )
        var isAlive = true
        let restored = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .expected },
            processLivenessValidator: { _ in isAlive },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in .absent }
        )

        restored.reconcile(profiles: [profile])
        #expect(restored.runningProfileIDs.contains(profile.id))
        isAlive = false

        for _ in 0..<100 {
            if !restored.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!restored.runningProfileIDs.contains(profile.id))
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @Test
    func unknownLiveProcessFailsClosedUntilItExits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Unknown")
        try paths.prepareProfileDirectories(for: profile.id)
        let lock = BrowserProcessLock(
            pid: 126,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath: paths.browserDataDirectory(for: profile.id).path,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(lock),
            to: paths.lockFile(for: profile.id)
        )
        var isAlive = true
        var signalWasSent = false
        let restored = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in isAlive },
            processSignaler: { _, _ in
                signalWasSent = true
                return 0
            },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in .absent }
        )

        restored.reconcile(profiles: [profile])
        #expect(restored.runningProfileIDs.contains(profile.id))
        #expect(
            restored.processState(for: profile.id) ==
                .externalUnverified
        )
        #expect(restored.lastError != nil)
        restored.stop(profileID: profile.id)
        #expect(!signalWasSent)
        #expect(restored.runningProfileIDs.contains(profile.id))

        isAlive = false
        for _ in 0..<20 {
            if !restored.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!restored.runningProfileIDs.contains(profile.id))
        #expect(restored.processState(for: profile.id) == .stopped)
    }

    @Test
    func corruptLockAndUnknownScanFailClosedWithoutChangingBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Corrupt unknown")
        try paths.prepareProfileDirectories(for: profile.id)
        let corruptData = Data("{not-json".utf8)
        try paths.writePrivateFile(
            corruptData,
            to: paths.lockFile(for: profile.id)
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .unknown }
        )

        manager.reconcile(profiles: [profile])

        #expect(manager.runningProfileIDs.contains(profile.id))
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        #expect(
            try Data(contentsOf: paths.lockFile(for: profile.id)) ==
                corruptData
        )
        let runtime = BrowserRuntime(
            name: "Must not launch",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            source: "Test"
        )
        #expect(throws: NeAntikError.self) {
            try manager.launch(profile: profile, runtime: runtime)
        }
    }

    @Test
    func corruptLockUnlocksOnlyAfterPositiveAbsentEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Corrupt observed")
        try paths.prepareProfileDirectories(for: profile.id)
        try paths.writePrivateFile(
            Data("broken".utf8),
            to: paths.lockFile(for: profile.id)
        )
        var inspection = BrowserDataProcessInspection.found
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in inspection }
        )

        manager.reconcile(profiles: [profile])
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
        inspection = .absent
        for _ in 0..<20 {
            if !manager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @Test
    func passiveRecoveryObservationSuspendsUntilForegroundReconcile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Suspended recovery")
        try paths.prepareProfileDirectories(for: profile.id)
        let browserData = paths.browserDataDirectory(for: profile.id)
        let marker = browserData.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        try paths.writePrivateFile(
            Data("broken".utf8),
            to: paths.lockFile(for: profile.id)
        )
        var inspection = BrowserDataProcessInspection.found
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in inspection }
        )

        manager.reconcile(profiles: [profile])
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        manager.suspendPassiveObservations()
        inspection = .absent
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        #expect(FileManager.default.fileExists(atPath: marker.path))

        manager.reconcile(profiles: [profile])

        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func managedExitCannotRestartPassivePollingWhileSuspended() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 0.12\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let profile = BrowserProfile(name: "Suspended managed exit")
        try paths.prepareProfileDirectories(for: profile.id)
        let marker = paths.browserDataDirectory(for: profile.id)
            .appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        var inspection = BrowserDataProcessInspection.absent
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in inspection }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )

        try manager.launch(profile: profile, runtime: runtime)
        inspection = .found
        manager.suspendPassiveObservations()
        for _ in 0..<100 {
            if manager.processState(for: profile.id) == .recoveryRequired {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )

        inspection = .absent
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        #expect(FileManager.default.fileExists(atPath: marker.path))

        manager.reconcile(profiles: [profile])

        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func corruptStaleLockIsRemovedAfterPositiveAbsentEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Corrupt stale")
        try paths.prepareProfileDirectories(for: profile.id)
        try paths.writePrivateFile(
            Data("broken".utf8),
            to: paths.lockFile(for: profile.id)
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )

        manager.reconcile(profiles: [profile])

        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @Test
    func symlinkedLockFailsClosedAndDoesNotChangeTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Symlink lock")
        try paths.prepareProfileDirectories(for: profile.id)
        let protectedData = Data("outside-must-stay".utf8)
        try protectedData.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.lockFile(for: profile.id),
            withDestinationURL: outside
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )

        manager.reconcile(profiles: [profile])

        #expect(manager.runningProfileIDs.contains(profile.id))
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        #expect(try Data(contentsOf: outside) == protectedData)
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: paths.lockFile(for: profile.id).path
        )
        #expect(destination == outside.path)
    }

    @Test
    func symlinkedCoordinationGuardFailsClosedWithoutChangingTarget()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Symlink guard")
        try paths.prepareProfileDirectories(for: profile.id)
        let protectedData = Data("guard-target".utf8)
        try protectedData.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.lockGuardFile(for: profile.id),
            withDestinationURL: outside
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )

        manager.reconcile(profiles: [profile])

        #expect(manager.runningProfileIDs.contains(profile.id))
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        #expect(try Data(contentsOf: outside) == protectedData)
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: paths.lockGuardFile(for: profile.id).path
        )
        #expect(destination == outside.path)
    }

    @Test
    func mismatchedBrowserDataPathNeverDeletesLockOnUnknownScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Wrong path")
        try paths.prepareProfileDirectories(for: profile.id)
        let lock = BrowserProcessLock(
            pid: 912,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath: root.appendingPathComponent("OtherData").path,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lockData = try encoder.encode(lock)
        try paths.writePrivateFile(
            lockData,
            to: paths.lockFile(for: profile.id)
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .unknown }
        )

        manager.reconcile(profiles: [profile])

        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        #expect(
            try Data(contentsOf: paths.lockFile(for: profile.id)) ==
                lockData
        )
    }

    @Test
    func atomicLeasePreventsSecondManagerFromLaunchingProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let launchMarker = root.appendingPathComponent("launches.txt")
        try Data().write(to: launchMarker)
        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data(
                "#!/bin/sh\necho launch >> '\(launchMarker.path)'\nsleep 1\n".utf8
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let profile = BrowserProfile(name: "Atomic")
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )
        let first = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let second = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .expected },
            processLivenessValidator: { _ in true },
            browserDataProcessInspector: { _ in .found }
        )

        try first.launch(profile: profile, runtime: runtime)
        #expect(throws: NeAntikError.self) {
            try second.launch(profile: profile, runtime: runtime)
        }
        for _ in 0..<100 {
            let data = try Data(contentsOf: launchMarker)
            if !data.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let launches = try String(
            contentsOf: launchMarker,
            encoding: .utf8
        )
        #expect(
            launches.components(separatedBy: "launch").count - 1 == 1
        )
        #expect(
            second.processState(for: profile.id) == .externalVerified
        )
        first.stop(profileID: profile.id)
        for _ in 0..<20 {
            if !first.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test
    func oldTerminationCannotDeleteReplacementOwnersLease() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 0.25\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let profile = BrowserProfile(name: "Owner replacement")
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        try manager.launch(profile: profile, runtime: runtime)

        let replacementOwner = UUID()
        let replacement = BrowserProcessLock(
            pid: 777,
            executablePath: fakeBrowser.path,
            browserDataPath:
                paths.browserDataDirectory(for: profile.id).path,
            createdAt: Date(),
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: replacementOwner,
            managerPID: 777,
            phase: .running
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(replacement),
            to: paths.lockFile(for: profile.id)
        )

        for _ in 0..<100 {
            if !manager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let persistedData = try Data(
            contentsOf: paths.lockFile(for: profile.id)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            BrowserProcessLock.self,
            from: persistedData
        )
        #expect(persisted.ownerToken == replacementOwner)
    }

    @Test
    func threeManagerRecoveryCannotDeleteNewOwnersLease() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let profile = BrowserProfile(name: "Three managers")
        try paths.prepareProfileDirectories(for: profile.id)
        let corruptData = Data("stale-corrupt-lock".utf8)
        try paths.writePrivateFile(
            corruptData,
            to: paths.lockFile(for: profile.id)
        )

        var firstInspection = BrowserDataProcessInspection.found
        let first = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .expected },
            processLivenessValidator: { _ in true },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in firstInspection }
        )
        first.reconcile(profiles: [profile])
        #expect(
            first.processState(for: profile.id) == .recoveryRequired
        )

        let second = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        second.reconcile(profiles: [profile])
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )

        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            // A loaded full-suite run can delay the three-manager
            // hand-off for more than one second. Keep the fake owner alive
            // until the test explicitly stops it so scheduler pressure
            // cannot remove the lease before the final assertion.
            contents: Data("#!/bin/sh\nsleep 10\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let third = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )
        try third.launch(profile: profile, runtime: runtime)
        let thirdLeaseData = try Data(
            contentsOf: paths.lockFile(for: profile.id)
        )

        firstInspection = .absent
        for _ in 0..<100 {
            if first.processState(for: profile.id) == .externalVerified {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(
            first.processState(for: profile.id) == .externalVerified
        )
        #expect(
            try Data(contentsOf: paths.lockFile(for: profile.id)) ==
                thirdLeaseData
        )
        third.stop(profileID: profile.id)
    }

    @Test
    func startingLeaseReclassifiesWhenOwnerPublishesRunningLease()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Starting transition")
        try paths.prepareProfileDirectories(for: profile.id)
        let owner = UUID()
        let createdAt = Date()
        let starting = BrowserProcessLock(
            pid: 0,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath:
                paths.browserDataDirectory(for: profile.id).path,
            createdAt: createdAt,
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: owner,
            managerPID: 42,
            phase: .starting
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.withProcessLockGuard(for: profile.id) {
            try paths.writePrivateFile(
                encoder.encode(starting),
                to: paths.lockFile(for: profile.id)
            )
        }
        let restored = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .expected },
            processLivenessValidator: { _ in true },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in .absent }
        )
        restored.reconcile(profiles: [profile])
        #expect(
            restored.processState(for: profile.id) == .recoveryRequired
        )

        let running = BrowserProcessLock(
            pid: 84,
            executablePath: starting.executablePath,
            browserDataPath: starting.browserDataPath,
            createdAt: createdAt,
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: owner,
            managerPID: 42,
            phase: .running
        )
        try paths.withProcessLockGuard(for: profile.id) {
            try paths.writePrivateFile(
                encoder.encode(running),
                to: paths.lockFile(for: profile.id)
            )
        }

        for _ in 0..<30 {
            if restored.processState(for: profile.id) == .externalVerified {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(
            restored.processState(for: profile.id) == .externalVerified
        )
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @Test
    func reusedManagerPIDCannotKeepStaleStartingLeaseForever() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Reused manager PID")
        try paths.prepareProfileDirectories(for: profile.id)
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let starting = BrowserProcessLock(
            pid: 0,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath:
                paths.browserDataDirectory(for: profile.id).path,
            createdAt: createdAt,
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: UUID(),
            managerPID: 42,
            phase: .starting
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.withProcessLockGuard(for: profile.id) {
            try paths.writePrivateFile(
                encoder.encode(starting),
                to: paths.lockFile(for: profile.id)
            )
        }
        let restored = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in true },
            browserDataProcessInspector: { _ in .absent },
            startingLeaseTimeout: 30,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        restored.reconcile(profiles: [profile])

        #expect(restored.processState(for: profile.id) == .stopped)
        #expect(!restored.runningProfileIDs.contains(profile.id))
        #expect(restored.lastError == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockGuardFile(for: profile.id).path
            )
        )
    }

    @Test
    func futureStartingLeaseFromLiveManagerRemainsBlocked() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Future starting lease")
        try paths.prepareProfileDirectories(for: profile.id)
        let starting = BrowserProcessLock(
            pid: 0,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath:
                paths.browserDataDirectory(for: profile.id).path,
            createdAt: Date(timeIntervalSince1970: 2_000),
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: UUID(),
            managerPID: 42,
            phase: .starting
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(starting),
            to: paths.lockFile(for: profile.id)
        )
        let restored = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in true },
            browserDataProcessInspector: { _ in .absent },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        restored.reconcile(profiles: [profile])

        #expect(
            restored.processState(for: profile.id) == .recoveryRequired
        )
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @Test
    func transientDeletionTombstoneAutoReconcilesAfterRollback()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Rolled back deletion")
        try paths.prepareProfileDirectories(for: profile.id)
        try paths.writePrivateFile(
            Data("deleted-v1".utf8),
            to: paths.profileDeletionTombstone(for: profile.id)
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in .absent }
        )

        manager.reconcile(profiles: [profile])
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )

        try paths.withProcessLockGuard(for: profile.id) {
            try FileManager.default.removeItem(
                at: paths.profileDeletionTombstone(for: profile.id)
            )
        }
        for _ in 0..<30 {
            if manager.processState(for: profile.id) == .stopped {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(manager.lastError == nil)
    }

    @Test
    func legacyGuardInsideProfileIsIgnoredAndPreserved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let protectedTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: protectedTarget)
        }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Legacy guard")
        try paths.prepareProfileDirectories(for: profile.id)
        let protectedData = Data("preserve".utf8)
        try protectedData.write(to: protectedTarget)
        let legacyGuard = paths.profileDirectory(for: profile.id)
            .appendingPathComponent(".neantik.lock.guard")
        try FileManager.default.createSymbolicLink(
            at: legacyGuard,
            withDestinationURL: protectedTarget
        )

        try paths.withProcessLockGuard(for: profile.id) {}

        #expect(try Data(contentsOf: protectedTarget) == protectedData)
        #expect(
            FileManager.default.fileExists(
                atPath: legacyGuard.path
            )
        )
        #expect(
            paths.lockGuardFile(for: profile.id)
                .deletingLastPathComponent() ==
                paths.processLocksDirectory
        )
    }

    @Test
    func staleManagerCannotDeleteProfileLaunchedBySecondManager()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let store = ProfileStore(paths: paths)
        let profile = try store.upsert(
            BrowserProfile(name: "Cross-manager delete")
        )
        let marker = paths.browserDataDirectory(for: profile.id)
            .appendingPathComponent("cookies-marker")
        try Data("browser-data".utf8).write(to: marker)
        var keychainSecret: String? = "proxy-secret"

        let staleManager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        staleManager.reconcile(profiles: [profile])
        #expect(staleManager.processState(for: profile.id) == .stopped)

        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 2\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let liveManager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )
        try liveManager.launch(profile: profile, runtime: runtime)

        #expect(throws: BrowserProfileDeletionBlockedError.self) {
            try store.delete(
                profile,
                processManager: staleManager
            ) { _ in
                keychainSecret = nil
            }
        }

        #expect(store.profile(withID: profile.id) != nil)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(keychainSecret == "proxy-secret")
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
        liveManager.stop(profileID: profile.id)
        for _ in 0..<30 {
            if !liveManager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test
    func deletionFailsClosedForFoundUnknownAndUnsafeEvidence() throws {
        for inspection in [
            BrowserDataProcessInspection.found,
            .unknown
        ] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = AppPaths(rootDirectory: root)
            let store = ProfileStore(paths: paths)
            let profile = try store.upsert(
                BrowserProfile(name: "Blocked deletion")
            )
            let marker = paths.browserDataDirectory(for: profile.id)
                .appendingPathComponent("cookies-marker")
            try Data("browser-data".utf8).write(to: marker)
            var keychainSecret: String? = "proxy-secret"
            var inspectedURL: URL?
            let manager = BrowserProcessManager(
                paths: paths,
                processIdentityValidator: { _ in false },
                browserDataProcessInspector: { url in
                    inspectedURL = url
                    return inspection
                }
            )

            #expect(throws: BrowserProfileDeletionBlockedError.self) {
                try store.delete(
                    profile,
                    processManager: manager
                ) { _ in
                    keychainSecret = nil
                }
            }

            #expect(
                inspectedURL?.standardizedFileURL ==
                    paths.browserDataDirectory(for: profile.id)
                        .standardizedFileURL
            )
            #expect(store.profile(withID: profile.id) != nil)
            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(keychainSecret == "proxy-secret")
        }

        let unsafeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unsafeRoot) }
        let unsafePaths = AppPaths(rootDirectory: unsafeRoot)
        let unsafeStore = ProfileStore(paths: unsafePaths)
        let unsafeProfile = try unsafeStore.upsert(
            BrowserProfile(name: "Unsafe lease deletion")
        )
        let unsafeMarker = unsafePaths.browserDataDirectory(
            for: unsafeProfile.id
        ).appendingPathComponent("cookies-marker")
        try Data("browser-data".utf8).write(to: unsafeMarker)
        try FileManager.default.createDirectory(
            at: unsafePaths.lockFile(for: unsafeProfile.id),
            withIntermediateDirectories: false
        )
        var unsafeSecret: String? = "proxy-secret"
        let unsafeManager = BrowserProcessManager(
            paths: unsafePaths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )

        #expect(throws: BrowserProfileDeletionBlockedError.self) {
            try unsafeStore.delete(
                unsafeProfile,
                processManager: unsafeManager
            ) { _ in
                unsafeSecret = nil
            }
        }
        #expect(unsafeStore.profile(withID: unsafeProfile.id) != nil)
        #expect(FileManager.default.fileExists(atPath: unsafeMarker.path))
        #expect(unsafeSecret == "proxy-secret")
    }

    @Test
    func missingLeaseRequiresPositiveBrowserDataAbsence() throws {
        for inspection in [
            BrowserDataProcessInspection.found,
            .unknown
        ] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let launchMarker = root.appendingPathComponent("launched")
            let fakeBrowser = root.appendingPathComponent("fake-browser")
            FileManager.default.createFile(
                atPath: fakeBrowser.path,
                contents: Data(
                    "#!/bin/sh\ntouch '\(launchMarker.path)'\n".utf8
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fakeBrowser.path
            )
            let paths = AppPaths(
                rootDirectory: root.appendingPathComponent("data")
            )
            let profile = BrowserProfile(name: "Missing lease")
            let manager = BrowserProcessManager(
                paths: paths,
                processIdentityValidator: { _ in false },
                browserDataProcessInspector: { _ in inspection }
            )
            let runtime = BrowserRuntime(
                name: "Fake Chromium",
                executableURL: fakeBrowser,
                source: "Test"
            )

            #expect(throws: NeAntikError.self) {
                try manager.launch(profile: profile, runtime: runtime)
            }
            #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: paths.lockFile(for: profile.id).path
                )
            )
        }
    }

    @Test
    func mainExitRetainsLeaseUntilHelpersAreAbsent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 0.15\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let profile = BrowserProfile(name: "Helper lifetime")
        var inspection = BrowserDataProcessInspection.absent
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in inspection }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )

        try manager.launch(profile: profile, runtime: runtime)
        inspection = .found
        for _ in 0..<100 {
            if manager.processState(for: profile.id) == .recoveryRequired {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(manager.processState(for: profile.id) == .recoveryRequired)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
        #expect(throws: NeAntikError.self) {
            try manager.launch(profile: profile, runtime: runtime)
        }

        inspection = .absent
        for _ in 0..<100 {
            if manager.processState(for: profile.id) == .stopped {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @Test
    func lateTerminationCallbackCannotEraseHelperRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let exitedMarker = root.appendingPathComponent("exited")
        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data(
                "#!/bin/sh\nsleep 0.05\ntouch '\(exitedMarker.path)'\n"
                    .utf8
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let profile = BrowserProfile(name: "Late callback")
        var inspection = BrowserDataProcessInspection.absent
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in inspection }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )

        try manager.launch(profile: profile, runtime: runtime)
        inspection = .found
        for _ in 0..<200 where
            !FileManager.default.fileExists(atPath: exitedMarker.path)
        {
            usleep(10_000)
        }
        #expect(
            FileManager.default.fileExists(atPath: exitedMarker.path)
        )
        usleep(100_000)
        manager.stop(profileID: profile.id)
        await Task.yield()
        await Task.yield()

        #expect(manager.processState(for: profile.id) == .recoveryRequired)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )

        inspection = .absent
        for _ in 0..<100 {
            if manager.processState(for: profile.id) == .stopped {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @Test
    func externalProcessIsManualStopOnlyWithoutBirthIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Manual external stop")
        try paths.prepareProfileDirectories(for: profile.id)
        let lock = BrowserProcessLock(
            pid: 42,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath:
                paths.browserDataDirectory(for: profile.id).path,
            createdAt: Date(),
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: UUID(),
            managerPID: 84,
            phase: .running
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(lock),
            to: paths.lockFile(for: profile.id)
        )
        var signalCount = 0
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .expected },
            processLivenessValidator: { _ in true },
            processSignaler: { _, _ in
                signalCount += 1
                return 0
            },
            browserDataProcessInspector: { _ in .found },
            allowsExternalProcessSignaling: false
        )

        manager.reconcile(profiles: [profile])
        manager.stop(profileID: profile.id)

        #expect(manager.processState(for: profile.id) == .externalManualOnly)
        #expect(signalCount == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @Test
    func legacyLockDecodesAsRunningWithoutOwner() throws {
        let createdAt = "2026-07-30T00:00:00Z"
        let data = Data(
            """
            {
              "pid": 42,
              "executablePath": "/Applications/NeAntik Browser",
              "browserDataPath": "/tmp/BrowserData",
              "createdAt": "\(createdAt)"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lock = try decoder.decode(BrowserProcessLock.self, from: data)

        #expect(lock.schemaVersion == 1)
        #expect(lock.ownerToken == nil)
        #expect(lock.managerPID == nil)
        #expect(lock.phase == .running)
        #expect(lock.pid == 42)
    }

    @Test
    func refusesToStartWhenLockPathIsUnsafe() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data("#!/bin/sh\nsleep 0.3\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )

        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let profile = BrowserProfile(name: "Lock failure")
        try paths.prepareProfileDirectories(for: profile.id)
        try FileManager.default.createDirectory(
            at: paths.lockFile(for: profile.id),
            withIntermediateDirectories: false
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            managedProcessTerminator: { _ in }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )

        #expect(throws: NeAntikError.self) {
            try manager.launch(profile: profile, runtime: runtime)
        }
        #expect(manager.runningProfileIDs.contains(profile.id))
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(manager.runningProfileIDs.contains(profile.id))
        #expect(
            manager.processState(for: profile.id) == .recoveryRequired
        )
    }

    @Test
    func rejectsSymlinkedLogWithoutChangingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outsideLog = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideLog)
        }

        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Symlink log")
        try paths.prepareProfileDirectories(for: profile.id)
        let protectedData = Data("do-not-change".utf8)
        try protectedData.write(to: outsideLog)
        try FileManager.default.createSymbolicLink(
            at: paths.logFile(for: profile.id),
            withDestinationURL: outsideLog
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let runtime = BrowserRuntime(
            name: "Never launched",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            source: "Test"
        )

        #expect(throws: (any Error).self) {
            try manager.launch(profile: profile, runtime: runtime)
        }
        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(try Data(contentsOf: outsideLog) == protectedData)
    }

    @Test
    func browserOutputDoesNotEnterManagerDiagnosticLog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fakeBrowser = root.appendingPathComponent("fake-browser")
        FileManager.default.createFile(
            atPath: fakeBrowser.path,
            contents: Data(
                "#!/bin/sh\necho 'https://private.example/path' >&2\n".utf8
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBrowser.path
        )
        let paths = AppPaths(
            rootDirectory: root.appendingPathComponent("data")
        )
        let profile = BrowserProfile(name: "Private log")
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let runtime = BrowserRuntime(
            name: "Fake Chromium",
            executableURL: fakeBrowser,
            source: "Test"
        )

        try manager.launch(profile: profile, runtime: runtime)
        for _ in 0..<20 {
            if !manager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        var text = ""
        for _ in 0..<50 {
            text = (
                try? String(
                    contentsOf: paths.logFile(for: profile.id),
                    encoding: .utf8
                )
            ) ?? ""
            if text.contains("browser_exit") {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!text.contains("private.example"))
        #expect(text.contains("browser_launch"))
        #expect(text.contains("browser_exit"))
    }
}
