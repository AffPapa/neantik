import Darwin
import Foundation
import Testing
@testable import NeAntik

private final class InventorySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BrowserProcessInventory]
    private(set) var count = 0
    private var capturedOnMainThread = false

    init(_ values: [BrowserProcessInventory]) {
        self.values = values
    }

    func capture() -> BrowserProcessInventory {
        lock.lock()
        count += 1
        capturedOnMainThread =
            capturedOnMainThread || Thread.isMainThread
        let value = values.isEmpty ? .unavailable : values.removeFirst()
        lock.unlock()
        return value
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var anyCaptureOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capturedOnMainThread
    }
}

private final class OrderedInventoryGate: @unchecked Sendable {
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    func capture() -> BrowserProcessInventory {
        lock.lock()
        count += 1
        let invocation = count
        lock.unlock()
        if invocation == 1 {
            releaseFirst.wait()
            return .unavailable
        }
        return BrowserProcessInventory(processes: [:])
    }

    var firstHasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count >= 1
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LeaseCreatingInventorySequence:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let paths: AppPaths
    private let profileID: UUID
    private var count = 0

    init(paths: AppPaths, profileID: UUID) {
        self.paths = paths
        self.profileID = profileID
    }

    func capture() -> BrowserProcessInventory {
        lock.lock()
        count += 1
        let invocation = count
        lock.unlock()
        let browserDataPath =
            paths.browserDataDirectory(for: profileID).path
        if invocation == 1 {
            let lease = BrowserProcessLock(
                pid: 0,
                executablePath: "/Applications/NeAntik Browser",
                browserDataPath: browserDataPath,
                createdAt: Date(),
                schemaVersion:
                    BrowserProcessLock.currentSchemaVersion,
                managerPID: pid_t.max,
                phase: .starting
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? paths.writePrivateFile(
                encoder.encode(lease),
                to: paths.lockFile(for: profileID)
            )
            return BrowserProcessInventory(processes: [:])
        }
        let process = BrowserProcessArguments(
            executablePath: "/Applications/NeAntik Browser",
            arguments: [
                "/ignored-argv-zero",
                "--user-data-dir=\(browserDataPath)"
            ]
        )
        return BrowserProcessInventory(
            processes: [getpid(): process]
        )
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class OwnerDeathInventorySequence:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let owner: Process
    private let browserDataPath: String
    private var count = 0

    init(owner: Process, browserDataPath: String) {
        self.owner = owner
        self.browserDataPath = browserDataPath
    }

    func capture() -> BrowserProcessInventory {
        lock.lock()
        count += 1
        let invocation = count
        lock.unlock()
        if invocation == 1 {
            owner.terminate()
            owner.waitUntilExit()
            return BrowserProcessInventory(processes: [:])
        }
        return BrowserProcessInventory(
            processes: [
                getpid(): BrowserProcessArguments(
                    executablePath:
                        "/Applications/NeAntik Browser",
                    arguments: [
                        "--user-data-dir=\(browserDataPath)"
                    ]
                )
            ]
        )
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class PassiveInventoryGate: @unchecked Sendable {
    let releasePassive = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    func capture() -> BrowserProcessInventory {
        lock.lock()
        count += 1
        let invocation = count
        lock.unlock()
        if invocation == 1 {
            return .unavailable
        }
        if invocation == 2 {
            releasePassive.wait()
        }
        return BrowserProcessInventory(processes: [:])
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

struct BrowserProcessInventoryTests {
    @Test
    func parserDecodesStrictUTF8ProcessArguments() {
        let buffer = processArgumentBuffer(
            executable: "/Applications/NeAntik Browser",
            arguments: [
                "/Applications/NeAntik Browser",
                "--user-data-dir=/tmp/Profile/BrowserData"
            ]
        )

        let parsed = BrowserProcessArgumentParser.decode(
            buffer,
            byteCount: buffer.count
        )

        #expect(parsed?.executablePath == "/Applications/NeAntik Browser")
        #expect(
            parsed?.arguments == [
                "/Applications/NeAntik Browser",
                "--user-data-dir=/tmp/Profile/BrowserData"
            ]
        )
    }

    @Test
    func parserRejectsTruncationInvalidUTF8AndArgumentAmplification() {
        let valid = processArgumentBuffer(
            executable: "/browser",
            arguments: ["/browser"]
        )
        #expect(
            BrowserProcessArgumentParser.decode(
                valid,
                byteCount: valid.count - 1
            ) == nil
        )

        var invalidUTF8 = valid
        invalidUTF8[MemoryLayout<Int32>.size] = 0xFF
        #expect(
            BrowserProcessArgumentParser.decode(
                invalidUTF8,
                byteCount: invalidUTF8.count
            ) == nil
        )

        var excessiveCount = valid
        var count = Int32(
            BrowserProcessArgumentParser.maximumArgumentCount + 1
        )
        withUnsafeBytes(of: &count) { bytes in
            excessiveCount.replaceSubrange(
                0..<MemoryLayout<Int32>.size,
                with: bytes
            )
        }
        #expect(
            BrowserProcessArgumentParser.decode(
                excessiveCount,
                byteCount: excessiveCount.count
            ) == nil
        )
    }

    @Test
    func inventoryIsExactAndFailsClosedWhenAnyLiveArgumentsAreUnreadable() {
        let dataPath = "/tmp/NeAntik/Profile/BrowserData"
        let process = BrowserProcessArguments(
            executablePath: "/Applications/NeAntik Browser",
            arguments: [
                "/Applications/NeAntik Browser",
                "--user-data-dir=\(dataPath)"
            ]
        )
        let inventory = BrowserProcessInventory(
            processes: [getpid(): process]
        )
        let lock = BrowserProcessLock(
            pid: getpid(),
            executablePath: process.executablePath,
            browserDataPath: dataPath,
            createdAt: Date()
        )

        #expect(inventory.inspectProcess(lock) == .expected)
        #expect(
            inventory.inspectBrowserDataProcess(
                URL(fileURLWithPath: dataPath)
            ) == .found
        )
        #expect(
            inventory.inspectBrowserDataProcess(
                URL(fileURLWithPath: "/tmp/Other/BrowserData")
            ) == .absent
        )

        let unreadable = BrowserProcessInventory(
            processes: [:],
            unreadableLiveProcessExists: true
        )
        #expect(
            unreadable.inspectBrowserDataProcess(
                URL(fileURLWithPath: dataPath)
            ) == .unknown
        )
        #expect(BrowserProcessInventory.unavailable.inspectProcess(lock) == .unknown)

        let spoofedExecutable = BrowserProcessInventory(
            processes: [
                getpid(): BrowserProcessArguments(
                    executablePath: "/tmp/not-neantik",
                    arguments: [
                        process.executablePath,
                        "--user-data-dir=\(dataPath)"
                    ]
                )
            ]
        )
        #expect(spoofedExecutable.inspectProcess(lock) == .unrelated)

        let relativePath = BrowserProcessInventory(
            processes: [
                getpid(): BrowserProcessArguments(
                    executablePath: process.executablePath,
                    arguments: ["--user-data-dir=relative/Profile"]
                )
            ]
        )
        #expect(
            relativePath.inspectBrowserDataProcess(
                URL(fileURLWithPath: "/tmp/Other/BrowserData")
            ) == .unknown
        )

        let capturedIdentity = BrowserProcessKernelIdentity(
            startSeconds: 100,
            startMicroseconds: 1
        )
        let reusedPID = BrowserProcessInventory(
            processes: [getpid(): process],
            kernelIdentities: [getpid(): capturedIdentity],
            kernelIdentityRevalidator: { _ in
                BrowserProcessKernelIdentity(
                    startSeconds: 101,
                    startMicroseconds: 1
                )
            }
        )
        #expect(reusedPID.inspectProcess(lock) == .unknown)
    }

    @MainActor
    @Test
    func emptyForegroundReconcileDoesNotCaptureProcessInventory() {
        let sequence = InventorySequence([
            BrowserProcessInventory(processes: [:])
        ])
        let manager = BrowserProcessManager(
            paths: AppPaths(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            ),
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .unknown },
            processInventoryProvider: { sequence.capture() }
        )

        manager.reconcile(profiles: [])

        #expect(sequence.captureCount == 0)
    }

    @MainActor
    @Test
    func productionReconcileCapturesOneInventoryForOneHundredProfiles()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profiles = (0..<100).map {
            BrowserProfile(name: "Profile \($0)")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for profile in profiles {
            try paths.prepareProfileDirectories(for: profile.id)
            let lock = BrowserProcessLock(
                pid: pid_t.max,
                executablePath: "/Applications/NeAntik Browser",
                browserDataPath:
                    paths.browserDataDirectory(for: profile.id).path,
                createdAt: Date()
            )
            try paths.writePrivateFile(
                encoder.encode(lock),
                to: paths.lockFile(for: profile.id)
            )
        }
        let sequence = InventorySequence([
            BrowserProcessInventory(processes: [:])
        ])
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .unknown },
            processInventoryProvider: { sequence.capture() }
        )

        manager.reconcile(profiles: profiles)
        #expect(
            profiles.allSatisfy {
                manager.processState(for: $0.id) == .checking
            }
        )
        #expect(await waitUntil {
            profiles.allSatisfy {
                manager.processState(for: $0.id) == .stopped
            }
        })
        #expect(sequence.captureCount == 1)
        #expect(!sequence.anyCaptureOnMainThread)
        #expect(
            profiles.allSatisfy {
                !FileManager.default.fileExists(
                    atPath: paths.lockFile(for: $0.id).path
                )
            }
        )
    }

    @MainActor
    @Test
    func suspendingDuringCaptureInvalidatesThePendingGeneration()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = BrowserProfile(name: "Suspended inventory")
        let gate = OrderedInventoryGate()
        let manager = BrowserProcessManager(
            paths: AppPaths(rootDirectory: root),
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .unknown },
            processInventoryProvider: { gate.capture() }
        )

        manager.reconcile(profiles: [profile])
        #expect(await waitUntil { gate.firstHasStarted })
        manager.suspendPassiveObservations()
        manager.reconcile(profiles: [profile])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(gate.captureCount == 1)
        gate.releaseFirst.signal()
        #expect(await waitUntil {
            manager.processState(for: profile.id) == .stopped
        })
        #expect(gate.captureCount == 2)
    }

    @MainActor
    @Test
    func staleReconcileResultCannotOverwriteNewGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Generation")
        try paths.prepareProfileDirectories(for: profile.id)
        let lock = BrowserProcessLock(
            pid: pid_t.max,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath:
                paths.browserDataDirectory(for: profile.id).path,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(lock),
            to: paths.lockFile(for: profile.id)
        )
        let gate = OrderedInventoryGate()
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .unknown },
            processInventoryProvider: { gate.capture() }
        )

        manager.reconcile(profiles: [profile])
        #expect(await waitUntil { gate.firstHasStarted })
        manager.reconcile(profiles: [profile])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.processState(for: profile.id) == .checking)
        #expect(gate.captureCount == 1)
        gate.releaseFirst.signal()
        #expect(await waitUntil {
            manager.processState(for: profile.id) == .stopped
        })

        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(gate.captureCount == 2)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @MainActor
    @Test
    func inventoryCannotRemoveLeaseCreatedAfterItsAnchorSnapshot()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Concurrent launch")
        try paths.prepareProfileDirectories(for: profile.id)
        let sequence = LeaseCreatingInventorySequence(
            paths: paths,
            profileID: profile.id
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .found },
            processInventoryProvider: { sequence.capture() }
        )

        manager.reconcile(profiles: [profile])

        #expect(await waitUntil {
            sequence.captureCount >= 2 &&
                manager.processState(for: profile.id) ==
                    .recoveryRequired
        })
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @MainActor
    @Test
    func ownerDeathDuringInventoryCannotUseStaleAbsence()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Owner transition")
        try paths.prepareProfileDirectories(for: profile.id)
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["30"]
        try owner.run()
        defer {
            if owner.isRunning {
                owner.terminate()
                owner.waitUntilExit()
            }
        }
        let browserDataPath =
            paths.browserDataDirectory(for: profile.id).path
        let lease = BrowserProcessLock(
            pid: 0,
            executablePath: "/Applications/NeAntik Browser",
            browserDataPath: browserDataPath,
            createdAt: Date(),
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            managerPID: owner.processIdentifier,
            phase: .starting
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(lease),
            to: paths.lockFile(for: profile.id)
        )
        let sequence = OwnerDeathInventorySequence(
            owner: owner,
            browserDataPath: browserDataPath
        )
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { pid in
                Darwin.kill(pid, 0) == 0 || errno == EPERM
            },
            browserDataProcessInspector: { _ in .found },
            processInventoryProvider: { sequence.capture() }
        )

        manager.reconcile(profiles: [profile])

        #expect(await waitUntil {
            sequence.captureCount >= 2 &&
                manager.processState(for: profile.id) ==
                    .recoveryRequired
        })
        #expect(
            FileManager.default.fileExists(
                atPath: paths.lockFile(for: profile.id).path
            )
        )
    }

    @MainActor
    @Test
    func unavailableLeaseAnchorStopsWithoutRetryLoop()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Unavailable anchor")
        let cleanProfile = BrowserProfile(name: "Clean anchor")
        try paths.prepareProfileDirectories(for: profile.id)
        try paths.prepareProfileDirectories(for: cleanProfile.id)
        try Data("protected".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.lockGuardFile(for: profile.id),
            withDestinationURL: outside
        )
        let sequence = InventorySequence([
            BrowserProcessInventory(processes: [:])
        ])
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in false },
            browserDataProcessInspector: { _ in .unknown },
            processInventoryProvider: { sequence.capture() }
        )

        manager.reconcile(profiles: [profile, cleanProfile])

        #expect(await waitUntil {
            manager.processState(for: profile.id) ==
                .recoveryRequired &&
                manager.processState(for: cleanProfile.id) ==
                    .stopped
        })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sequence.captureCount == 1)
    }

    @MainActor
    @Test
    func passiveAndForegroundInventoryUseOneGlobalFlight()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Global single flight")
        try paths.prepareProfileDirectories(for: profile.id)
        try paths.writePrivateFile(
            Data("broken".utf8),
            to: paths.lockFile(for: profile.id)
        )
        let gate = PassiveInventoryGate()
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in false },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in .unknown },
            processInventoryProvider: { gate.capture() }
        )

        manager.reconcile(profiles: [profile])
        #expect(await waitUntil {
            gate.captureCount == 2
        })
        manager.suspendPassiveObservations()
        manager.reconcile(profiles: [profile])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(gate.captureCount == 2)

        gate.releasePassive.signal()
        #expect(await waitUntil {
            gate.captureCount == 3 &&
                manager.processState(for: profile.id) == .stopped
        })
    }

    @MainActor
    @Test
    func onePassiveInventoryTickResolvesManyRecoveryRecords()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profiles = (0..<50).map {
            BrowserProfile(name: "Recovery \($0)")
        }
        for profile in profiles {
            try paths.prepareProfileDirectories(for: profile.id)
            try paths.writePrivateFile(
                Data("broken".utf8),
                to: paths.lockFile(for: profile.id)
            )
        }
        let sequence = InventorySequence([
            .unavailable,
            BrowserProcessInventory(processes: [:])
        ])
        let manager = BrowserProcessManager(
            paths: paths,
            processIdentityInspector: { _ in .unknown },
            processLivenessValidator: { _ in false },
            observationIntervalNanoseconds: 20_000_000,
            browserDataProcessInspector: { _ in .unknown },
            processInventoryProvider: { sequence.capture() }
        )

        manager.reconcile(profiles: profiles)
        #expect(await waitUntil {
            profiles.allSatisfy {
                manager.processState(for: $0.id) == .recoveryRequired
            }
        })
        #expect(await waitUntil {
            profiles.allSatisfy {
                manager.processState(for: $0.id) == .stopped
            }
        })

        #expect(sequence.captureCount == 2)
    }

    private func processArgumentBuffer(
        executable: String,
        arguments: [String]
    ) -> [UInt8] {
        var count = Int32(arguments.count)
        var buffer = withUnsafeBytes(of: &count) {
            Array($0)
        }
        buffer.append(contentsOf: executable.utf8)
        buffer.append(0)
        buffer.append(0)
        for argument in arguments {
            buffer.append(contentsOf: argument.utf8)
            buffer.append(0)
        }
        return buffer
    }

    @MainActor
    private func waitUntil(
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
