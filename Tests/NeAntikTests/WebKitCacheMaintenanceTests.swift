import Foundation
import Testing
import WebKit
@testable import NeAntik

@MainActor private final class OwnedCacheCallback {
    var started = false
    private var completion: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { completion = $0; started = true } }
    func finish() { completion?.resume(); completion = nil }
}

@Suite(.serialized) @MainActor struct WebKitCacheMaintenanceTests {
    private func fixture() throws -> (URL, AppPaths, ProfileStore, BrowserProfile, BrowserProcessManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-cache-owned-\(UUID())").resolvingSymlinksInPath()
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let profile = try store.upsert(BrowserProfile(name: "Owned WK cache", startupMode: .restoreSession, engine: .webkit))
        // These contract tests exercise lease ordering, not the host's live
        // memory-pressure state. Keep admission deterministic; production
        // managers continue using the shared OS observer.
        let admission = ManagerLaunchAdmission(observePressure: false)
        let manager = BrowserProcessManager(launchAdmission: admission, paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent }, validatesPersistedProfiles: true)
        return (root, paths, store, profile, manager)
    }
    private func started(_ gate: OwnedCacheCallback) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.started)
    }

    @Test func onlyHTTPMemoryAndDiskTypesAreAdmitted() {
        #expect(WebKitCacheMaintenance.dataTypes == [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache])
        #expect(WebKitCacheMaintenance.dataTypes.isDisjoint(with: [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeFetchCache]))
    }

    @Test func cancellationBeforeDispatchDoesNotCallBackend() async throws {
        let (root, paths, _, profile, manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var called = false
        let task = Task { try await manager.clearWebKitCache(profile: profile) { _ in called = true } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!called && !manager.hasPendingWebKitWork && manager.webKitMaintenanceProfileIDs.isEmpty)
        let lease = try paths.acquireWebKitSessionGuard(for: profile.id); lease.release()
    }

    @Test func cancellationAfterDispatchRetainsBothFencesUntilCallbackAndQuitWaits() async throws {
        let (root, paths, store, profile, manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let count = ApplicationUpdateAdmission.shared.activeCount, gate = OwnedCacheCallback()
        let task = Task { try await manager.clearWebKitCache(profile: profile) { id in #expect(id == profile.id); await gate.wait() } }
        defer { gate.finish() }
        try await started(gate); task.cancel()
        #expect(manager.processState(for: profile.id) == .checking && manager.hasPendingWebKitWork)
        #expect(ApplicationUpdateAdmission.shared.activeCount == count + 1)
        #expect(throws: ApplicationUpdateAdmissionError.busy) { try ApplicationUpdateAdmission.shared.acquireUpdate() }
        #expect(throws: ProfileProcessBusyError.self) { try paths.acquireWebKitSessionGuard(for: profile.id) }
        #expect(throws: ProfileProcessBusyError.self) { try paths.acquireWebKitMetadataGuard(for: profile.id) }
        var edited = profile; edited.name = "Must not commit"
        #expect(throws: ProfileProcessBusyError.self) { try store.upsert(edited) }
        let second = BrowserProcessManager(launchAdmission: ManagerLaunchAdmission(observePressure: false), paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent })
        #expect(throws: ProfileProcessBusyError.self) { try second.launchWebKitProfile(profile) }
        var drained = false
        let quit = Task { drained = await manager.drainWebKitForQuit() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!drained && manager.hasPendingWebKitWork)
        gate.finish(); try await task.value; await quit.value
        #expect(drained && !manager.hasPendingWebKitWork && manager.processState(for: profile.id) == .stopped)
        #expect(ApplicationUpdateAdmission.shared.activeCount == count)
        let process = try paths.acquireWebKitSessionGuard(for: profile.id); process.release()
        let metadata = try paths.acquireWebKitMetadataGuard(for: profile.id); metadata.release()
    }

    @Test func staleSnapshotMissingProfileAndWrongEngineRefuseBeforeDispatch() async throws {
        let (root, _, store, profile, manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var updated = profile; updated.name = "Own new revision"; _ = try store.upsert(updated)
        var calls = 0
        await #expect(throws: BrowserProfileRevisionConflictError.self) { try await manager.clearWebKitCache(profile: profile) { _ in calls += 1 } }
        var missing = profile; missing.id = UUID()
        await #expect(throws: BrowserProfileDeletedError.self) { try await manager.clearWebKitCache(profile: missing) { _ in calls += 1 } }
        var chromium = profile; chromium.engine = .chromium
        await #expect(throws: WebKitCacheMaintenanceError.wrongEngine) { try await manager.clearWebKitCache(profile: chromium) { _ in calls += 1 } }
        #expect(calls == 0 && manager.webKitMaintenanceProfileIDs.isEmpty)
    }

    @Test(arguments: ["metadata", "lease", "tombstone"])
    func heldMetadataLeaseAndTombstoneRefuse(type: String) async throws {
        let (root, paths, _, profile, manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var metadata: PrivateFileGuardLease?
        if type == "metadata" { metadata = try paths.acquireWebKitMetadataGuard(for: profile.id) }
        if type == "lease" { try paths.writePrivateFile(Data(), to: paths.lockFile(for: profile.id)) }
        if type == "tombstone" { try paths.writePrivateFile(Data(), to: paths.profileDeletionTombstone(for: profile.id)) }
        defer { metadata?.release() }
        var called = false
        do { try await manager.clearWebKitCache(profile: profile) { _ in called = true }; Issue.record("Unsafe admission unexpectedly succeeded") }
        catch { #expect(error is ProfileProcessBusyError || error is BrowserProfileDeletionBlockedError || error is BrowserProfileDeletedError) }
        #expect(!called && !manager.hasPendingWebKitWork)
    }

    @Test func revisionChangedWhileWaitingForProcessGuardRefusesDispatch() async throws {
        let (root, paths, store, profile, manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let held = try paths.acquireWebKitSessionGuard(for: profile.id)
        defer { held.release() }
        var called = false
        let task = Task { try await manager.clearWebKitCache(profile: profile) { _ in called = true } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !manager.webKitMaintenanceProfileIDs.contains(profile.id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(manager.webKitMaintenanceProfileIDs.contains(profile.id))
        var changed = profile; changed.name = "Own changed during acquisition"
        _ = try store.upsert(changed)
        held.release()
        await #expect(throws: BrowserProfileRevisionConflictError.self) { try await task.value }
        #expect(!called && !manager.hasPendingWebKitWork)
    }

    @Test(arguments: ["process-hardlink", "metadata-hardlink", "pending-restore"])
    func unsafeGuardAndPendingRestoreNeverReachBackend(type: String) async throws {
        let (root, paths, _, profile, manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        if type == "pending-restore" {
            try paths.writePrivateFile(Data(), to: root.appendingPathComponent(BrowserDataRestoreTransaction.activeName))
        } else {
            let lease = type == "metadata-hardlink" ? try paths.acquireWebKitMetadataGuard(for: profile.id) : try paths.acquireWebKitSessionGuard(for: profile.id)
            lease.release()
            let guardURL = type == "metadata-hardlink" ? paths.lockGuardFile(for: profile.id).appendingPathExtension("webkit") : paths.lockGuardFile(for: profile.id)
            try FileManager.default.linkItem(at: guardURL, to: root.appendingPathComponent("own-guard-link"))
        }
        var called = false
        do { try await manager.clearWebKitCache(profile: profile) { _ in called = true }; Issue.record("Unsafe admission unexpectedly succeeded") }
        catch { #expect(!(error is CancellationError)) }
        #expect(!called && !manager.hasPendingWebKitWork)
    }

    @Test(arguments: [false, true]) func replacedGuardAfterCallbackIsReportedAsPotentiallyCompleted(metadata: Bool) async throws {
        let (root, paths, _, profile, manager) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let guardURL = metadata ? paths.lockGuardFile(for: profile.id).appendingPathExtension("webkit") : paths.lockGuardFile(for: profile.id)
        var called = false
        await #expect(throws: WebKitCacheMaintenanceError.authorityChangedAfterCompletion) {
            try await manager.clearWebKitCache(profile: profile) { _ in
                called = true
                do {
                    try FileManager.default.moveItem(at: guardURL, to: root.appendingPathComponent("held-guard"))
                    try paths.writePrivateFile(Data(), to: guardURL)
                } catch { Issue.record("Owned replacement fixture failed: \(error)") }
            }
        }
        #expect(called && !manager.hasPendingWebKitWork)
    }
}
