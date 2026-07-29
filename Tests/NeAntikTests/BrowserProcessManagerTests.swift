import Darwin
import Foundation
import Testing
@testable import NeAntik

@MainActor
struct BrowserProcessManagerTests {
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
        let manager = BrowserProcessManager(paths: paths)
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
        let firstManager = BrowserProcessManager(paths: paths)
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
            }
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
            processLivenessValidator: { _ in true }
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
            }
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
            observationIntervalNanoseconds: 20_000_000
        )

        restored.reconcile(profiles: [profile])
        #expect(restored.runningProfileIDs.contains(profile.id))
        isAlive = false

        for _ in 0..<20 {
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
            observationIntervalNanoseconds: 20_000_000
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
    func keepsStartedProcessTrackedWhenLockWriteFails() async throws {
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

        for _ in 0..<20 {
            if !manager.runningProfileIDs.contains(profile.id) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(!manager.runningProfileIDs.contains(profile.id))
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
        let manager = BrowserProcessManager(paths: paths)
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
        let manager = BrowserProcessManager(paths: paths)
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

        let text = try String(
            contentsOf: paths.logFile(for: profile.id),
            encoding: .utf8
        )
        #expect(!text.contains("private.example"))
        #expect(text.contains("browser_launch"))
        #expect(text.contains("browser_exit"))
    }
}
