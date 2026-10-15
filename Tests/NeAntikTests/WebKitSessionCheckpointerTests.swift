import Foundation
import Testing
@testable import NeAntik

private actor OwnedCheckpointWrites {
    var snapshots: [WebKitSessionSnapshot] = []
    var active = 0
    var maximumActive = 0
    private var first: CheckedContinuation<Void, Never>?
    private let blockFirst: Bool
    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }
    func write(_ snapshot: WebKitSessionSnapshot) async -> Bool {
        snapshots.append(snapshot); active += 1; maximumActive = max(maximumActive, active)
        if blockFirst, snapshots.count == 1 {
            await withCheckedContinuation { first = $0 }
        }
        active -= 1
        return true
    }
    func releaseFirst() { first?.resume(); first = nil }
    var firstIsWaiting: Bool { first != nil }
}

private actor OwnedCheckpointClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { sleepers.count }
    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { sleepers.append($0) }
    }
    func advance() { if !sleepers.isEmpty { sleepers.removeFirst().resume() } }
    func releaseAll() { while !sleepers.isEmpty { advance() } }
}

@Suite(.serialized) @MainActor struct WebKitSessionCheckpointerTests {
    private func snapshot(_ id: UUID, _ name: String) throws -> WebKitSessionSnapshot {
        try .capture(profileID: id, urls: ["https://example.com/" + name], selectedIndex: 0)
    }
    private func settled(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await predicate())
    }

    @Test func closeCancelsDelayedAutosaveAndRejectsLaterScheduling() async throws {
        let id = UUID(), writes = OwnedCheckpointWrites()
        let writer = WebKitSessionCheckpointer(profileID: id, delay: .seconds(60), write: { await writes.write($0) })
        let old = try snapshot(id, "old"), final = try snapshot(id, "final")
        #expect(writer.schedule(old))
        #expect(await writer.finish(final))
        #expect(!writer.schedule(old))
        #expect(await writes.snapshots == [final])
        #expect(await writes.maximumActive == 1)
    }

    @Test func inFlightAutosaveDrainsBeforeLatestFinalWrite() async throws {
        let id = UUID(), writes = OwnedCheckpointWrites(blockFirst: true)
        let writer = WebKitSessionCheckpointer(profileID: id, delay: .zero, write: { await writes.write($0) })
        let first = try snapshot(id, "first"), middle = try snapshot(id, "middle"), final = try snapshot(id, "final")
        writer.schedule(first)
        try await settled { await writes.firstIsWaiting }
        writer.schedule(middle)
        let close = Task { await writer.finish(final) }
        try await settled { writer.isFinishing }
        #expect(await writes.active == 1)
        await writes.releaseFirst()
        #expect(await close.value)
        #expect(await writes.snapshots == [first, final])
        #expect(await writes.maximumActive == 1)
    }

    @Test func eventsCoalesceAndSameSnapshotDoesNotWriteAgain() async throws {
        let id = UUID(), writes = OwnedCheckpointWrites()
        let writer = WebKitSessionCheckpointer(profileID: id, delay: .milliseconds(5), write: { await writes.write($0) })
        let final = try snapshot(id, "last")
        for n in 0..<40 { writer.schedule(try snapshot(id, "tab\(n)")) }
        writer.schedule(final)
        try await settled { await writes.snapshots.count == 1 }
        #expect(await writes.snapshots == [final])
        writer.schedule(final)
        // Wait beyond this test's debounce to distinguish dedup from another
        // scheduled write. No network, WebKit process or ordinary profile.
        try await Task.sleep(for: .milliseconds(20))
        #expect(await writes.snapshots.count == 1)
        // Final close deliberately revalidates file custody even if unchanged.
        #expect(await writer.finish(final))
        #expect(await writes.snapshots == [final, final])
    }

    @Test func laterEventsCannotPostponeTheFirstCheckpointWindow() async throws {
        let id = UUID(), clock = OwnedCheckpointClock(), writes = OwnedCheckpointWrites()
        let writer = WebKitSessionCheckpointer(profileID: id,
            wait: { await clock.sleep($0) }, write: { await writes.write($0) })
        writer.schedule(try snapshot(id, "first"))
        try await settled { await clock.waiting == 1 }
        let latest = try snapshot(id, "latest")
        writer.schedule(try snapshot(id, "middle")); writer.schedule(latest)
        // Release only the original window. A resetting debounce would have
        // cancelled it and cannot produce this checkpoint until a later tick.
        await clock.advance()
        try await settled { await writes.snapshots.count == 1 }
        #expect(await writes.snapshots == [latest])
        #expect(await writer.finish(latest))
        await clock.releaseAll()
    }

    @Test func foreignOrInvalidSnapshotNeverReachesDiskWriter() async throws {
        let id = UUID(), writes = OwnedCheckpointWrites()
        let writer = WebKitSessionCheckpointer(profileID: id, delay: .zero, write: { await writes.write($0) })
        let foreign = try snapshot(UUID(), "foreign")
        let invalid = WebKitSessionSnapshot(schemaVersion: 1, profileID: id, urls: [], selectedIndex: 0, unavailableCount: 0)
        for value in [foreign, invalid] {
            #expect(!writer.schedule(value))
            #expect(!(await writer.finish(value)))
        }
        #expect(!writer.isFinishing)
        #expect(await writes.snapshots.isEmpty)
        #expect(await writer.finish(try snapshot(id, "own")))
    }

    @Test func failedAutosaveRetainsDiskStateAndCloseCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-checkpoint-owned-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WebKitSessionStore(paths: AppPaths(rootDirectory: root)), id = UUID()
        let old = try snapshot(id, "old"), failed = try snapshot(id, "failed"), final = try snapshot(id, "final")
        try store.save(old)
        var failing = store
        failing.beforeCommit = { throw WebKitSessionError.unavailable }
        let failingStore = failing
        var outcomes: [Bool] = []
        let writer = WebKitSessionCheckpointer(profileID: id, delay: .zero, write: { value in
            do {
                try (value == failed ? failingStore : store).save(value)
                return true
            } catch { return false }
        }, onAutosave: { outcomes.append($0) })
        writer.schedule(failed)
        try await settled { outcomes == [false] }
        #expect(try store.load(for: id) == old)
        #expect(!(await writer.finish(failed)))
        #expect(try store.load(for: id) == old)
        #expect(await writer.finish(final))
        #expect(try store.load(for: id) == final)
        #expect(outcomes == [false], "Final writes report through finish, never late autosave callbacks")
    }
}
