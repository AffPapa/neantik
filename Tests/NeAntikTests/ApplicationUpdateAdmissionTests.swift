import Foundation
import Testing
@testable import NeAntik

@MainActor
@Suite(.serialized)
struct ApplicationUpdateAdmissionTests {
    @Test func staleTokensCannotReleaseAnUpdateOrAnotherWorker() throws {
        let gate = ApplicationUpdateAdmission()
        let first = try gate.beginActivity(), second = try gate.beginActivity()
        #expect(throws: ApplicationUpdateAdmissionError.self) { try gate.acquireUpdate() }
        gate.finishActivity(first); gate.finishActivity(first)
        #expect(gate.activeCount == 1)
        #expect(throws: ApplicationUpdateAdmissionError.self) { try gate.acquireUpdate() }
        gate.finishActivity(second)
        let update = try gate.acquireUpdate()
        gate.releaseUpdate(first)
        #expect(throws: ApplicationUpdateAdmissionError.self) { try gate.beginActivity() }
        #expect(throws: ApplicationUpdateAdmissionError.self) { try gate.acquireUpdate() }
        gate.releaseUpdate(update)
        let next = try gate.acquireUpdate(); gate.releaseUpdate(update)
        #expect(gate.isUpdating)
        gate.releaseUpdate(next)
        let worker = try gate.beginActivity(); gate.finishActivity(worker)
    }

    @Test func updateRefusesRealMetadataWritesRefreshAndLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-update-metadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ApplicationUpdateAdmission(), paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths, updateAdmission: gate)
        let profile = try store.upsert(BrowserProfile(name: "Synthetic update fixture"))
        let bytes = try Data(contentsOf: paths.profilesFile)
        let update = try gate.acquireUpdate()
        var changed = profile; changed.name = "Must not be written"
        #expect(throws: ApplicationUpdateAdmissionError.self) { try store.upsert(changed) }
        #expect(throws: ApplicationUpdateAdmissionError.self) { try store.createFolder(named: "Must not be created") }
        #expect(throws: ApplicationUpdateAdmissionError.self) { try store.validateLaunchSnapshot(profile) }
        #expect(!store.markLaunched(profile.id))
        await #expect(throws: ApplicationUpdateAdmissionError.self) { try await store.refreshExternalMetadata(force: true) }
        await #expect(throws: ApplicationUpdateAdmissionError.self) {
            try await store.insertImportedProfilesOffMainActor([BrowserProfile(name: "Refused")], folderNames: [nil])
        }
        #expect(try Data(contentsOf: paths.profilesFile) == bytes)
        gate.releaseUpdate(update)
        #expect(try store.upsert(changed).name == changed.name)
        try await store.refreshExternalMetadata(force: true)
    }

    @Test func cancelledProxyPersistenceStaysBusyUntilActualRollbackCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-update-proxy-write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ApplicationUpdateAdmission(), point = UpdateProxyCommitPoint()
        let profile = BrowserProfile(name: "Synthetic proxy", proxy: ProxyConfiguration(kind: .http, host: "proxy.example", port: 8080, username: "fixture"))
        let file = root.appendingPathComponent("proxy-health.json")
        let coordinator = ProxyHealthCoordinator(fileURL: file, updateAdmission: gate,
            executionGate: ProxyTestExecutionGate(), commitBoundaryHook: { await point.hold() })
        let state = ProxyHealthState(latestAttempt: ProxyHealthAttempt(checkedAt: Date(), outcome: .connectionFailed), lastSuccess: nil)
        let operation = Task { @MainActor in try await coordinator.run(profile: profile) { _ in state } }
        for _ in 0..<2_000 { if await point.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await point.entered)
        #expect(gate.activeCount == 1)
        let persisted = try ProxyHealthStore(fileURL: file)
        #expect(await persisted.state(for: profile.id) != nil)
        operation.cancel()
        #expect(throws: ApplicationUpdateAdmissionError.self) { try gate.acquireUpdate() }
        await point.release(); _ = await operation.result
        #expect(gate.activeCount == 0)
        let reloaded = try ProxyHealthStore(fileURL: file)
        #expect(await reloaded.state(for: profile.id) == nil)
        let update = try gate.acquireUpdate(); gate.releaseUpdate(update)
    }
    @Test func cancelledImportRetainsActivityUntilRealRollbackAndPublicationReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-update-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let point = PausedUpdateImport(); defer { point.release() }
        let gate = ApplicationUpdateAdmission(), paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths, updateAdmission: gate, beforeBackgroundImportOrganizationPersist: { try point.pause() })
        let operation = Task { @MainActor in
            try await store.insertImportedProfilesOffMainActor([BrowserProfile(name: "Paused synthetic import")], folderNames: ["QA"])
        }
        for _ in 0..<2_000 {
            if point.hasEntered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(point.hasEntered)
        #expect(gate.activeCount == 1)
        operation.cancel()
        #expect(throws: ApplicationUpdateAdmissionError.self) { try gate.acquireUpdate() }
        point.release()
        _ = await operation.result
        #expect(gate.activeCount == 0)
        let update = try gate.acquireUpdate(); gate.releaseUpdate(update)
        let reread = ProfileStore(paths: paths, updateAdmission: gate)
        #expect(reread.hasTrustedMetadata)
    }
}
private final class PausedUpdateImport: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func pause() throws {
        lock.lock(); entered = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
    }
    func release() { semaphore.signal() }
}

private actor UpdateProxyCommitPoint {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
