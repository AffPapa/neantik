import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct FingerprintAuditSettlementTests {
    final class Evidence: @unchecked Sendable {
        private let lock = NSLock()
        private var value = BrowserDataProcessInspection.absent
        var directory: URL?
        private var captureGate: DispatchSemaphore?
        private var captureEntered = false
        func blockCapture() { lock.lock(); captureGate = DispatchSemaphore(value: 0); captureEntered = false; lock.unlock() }
        var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return captureEntered }
        func releaseCapture() { lock.lock(); let gate = captureGate; captureGate = nil; lock.unlock(); gate?.signal() }
        var inspection: BrowserDataProcessInspection {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
        func capture() -> BrowserProcessInventory {
            lock.lock(); let gate = captureGate; if gate != nil { captureEntered = true }; lock.unlock()
            if let gate { _ = gate.wait(timeout: .now() + 2) }
            switch inspection {
            case .unknown: return .unavailable
            case .absent: return .init(processes: [:])
            case .found:
                return .init(processes: [34567: .init(executablePath: "/own-fixture/NeAntik Browser", arguments: ["--user-data-dir=" + directory!.path])])
            }
        }
    }
    @MainActor final class Fixture {
        let root: URL, paths: AppPaths, manager: BrowserProcessManager
        let profile = BrowserProfile(name: "Own active audit settlement")
        let reservation: FingerprintAuditLaunchReservation
        let custody: FingerprintAuditDirectoryCustody
        let evidence = Evidence()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("own-audit-settlement-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            paths = AppPaths(rootDirectory: root.appendingPathComponent("metadata"))
            let evidence = self.evidence
            manager = BrowserProcessManager(launchAdmission: .init(observePressure: false, thermalState: { .nominal }), paths: paths,
                processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
                browserDataProcessInspector: { _ in evidence.inspection }, processInventoryProvider: { evidence.capture() },
                potentialRelayOwnerInspector: { .absent })
            reservation = try manager.reserveFingerprintAuditLaunch(startURL: URL(string: "http://127.0.0.1:32123/")!, httpLoopbackPort: 32123)
            custody = try manager.retainFingerprintAuditDirectory(reservation)
            evidence.directory = reservation.dataDirectory
            let browser = root.appendingPathComponent("own-browser")
            try Data("#!/bin/sh\nsleep 0.12\n".utf8).write(to: browser)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browser.path)
            try manager.launch(profile: profile, runtime: .init(name: "Own fixture", executableURL: browser, source: "Synthetic"),
                startURLOverride: URL(string: "http://127.0.0.1:32123/")!, browserDataDirectoryOverride: reservation.dataDirectory,
                fingerprintAuditReservation: reservation, purpose: .fingerprintAudit(httpLoopbackPort: 32123))
            evidence.inspection = .found
            manager.suspendPassiveObservations()
        }
        func terminated() async throws {
            for _ in 0..<100 {
                if manager.processState(for: profile.id) == .recoveryRequired { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CocoaError(.executableRuntimeMismatch)
        }
        func settle(_ reservation: FingerprintAuditLaunchReservation? = nil) async -> Bool {
            await manager.settleFingerprintAuditTermination(profileID: profile.id, reservation: reservation ?? self.reservation)
        }
        func cleanup() {
            manager.suspendPassiveObservations()
            try? custody.discard()
            manager.releaseFingerprintAuditReservation(reservation)
            try? FileManager.default.removeItem(at: root)
        }
    }
    @Test func inactiveOwnedExitRequiresFreshAbsenceAndKeepsPassivePollingSuspended() async throws {
        let f = try Fixture(); defer { f.cleanup() }; try await f.terminated()
        #expect(!(await f.settle()))
        f.evidence.inspection = .unknown
        #expect(!(await f.settle()))
        #expect(FileManager.default.fileExists(atPath: f.paths.lockFile(for: f.profile.id).path))
        f.evidence.inspection = .absent
        #expect(await f.settle())
        #expect(f.manager.processState(for: f.profile.id) == .stopped)
        #expect(!FileManager.default.fileExists(atPath: f.paths.lockFile(for: f.profile.id).path))
    }
    @Test func foreignOrReleasedReservationCannotRetireOwnedLease() async throws {
        let f = try Fixture(); defer { f.cleanup() }; try await f.terminated()
        let other = try f.manager.reserveFingerprintAuditLaunch(startURL: URL(string: "http://127.0.0.1:32124/")!, httpLoopbackPort: 32124)
        defer {
            if let custody = try? f.manager.retainFingerprintAuditDirectory(other) { try? custody.discard() }
            f.manager.releaseFingerprintAuditReservation(other)
        }
        let original = try Data(contentsOf: f.paths.lockFile(for: f.profile.id))
        f.evidence.inspection = .absent
        #expect(!(await f.settle(other)))
        f.manager.releaseFingerprintAuditReservation(f.reservation)
        #expect(!(await f.settle()))
        #expect(try Data(contentsOf: f.paths.lockFile(for: f.profile.id)) == original)
    }
    @Test func changedLeaseAndCancelledWaitNeverDeleteReplacement() async throws {
        let f = try Fixture(); defer { f.cleanup() }; try await f.terminated()
        let lease = f.paths.lockFile(for: f.profile.id)
        let replacement = Data("own replacement lease sentinel".utf8)
        try f.paths.writePrivateFile(replacement, to: lease)
        f.evidence.inspection = .absent
        let cancelled = Task { @MainActor in await f.settle() }; cancelled.cancel()
        #expect(!(await cancelled.value))
        _ = await f.settle()
        #expect(try Data(contentsOf: lease) == replacement)
    }
    @Test(arguments: [false, true])
    func revocationOrCancellationDuringInventoryAwaitCannotCommit(cancel: Bool) async throws {
        let f = try Fixture(); defer { f.evidence.releaseCapture(); f.cleanup() }; try await f.terminated()
        let lease = f.paths.lockFile(for: f.profile.id)
        let original = try Data(contentsOf: lease)
        f.evidence.inspection = .absent; f.evidence.blockCapture()
        let pending = Task { @MainActor in await f.settle() }
        for _ in 0..<100 {
            if f.evidence.didEnter { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.evidence.didEnter)
        if cancel { pending.cancel() }
        else { f.manager.releaseFingerprintAuditReservation(f.reservation) }
        f.evidence.releaseCapture()
        #expect(!(await pending.value))
        #expect(try Data(contentsOf: lease) == original)
    }

}
