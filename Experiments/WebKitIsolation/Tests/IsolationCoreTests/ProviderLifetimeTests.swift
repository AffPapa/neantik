import Foundation
import Testing
@testable import IsolationCore

private final class Calls: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
@Suite struct ProviderLifetimeTests {
    @Test func stopDuringFactoryNeverPublishesAndCompletesAfterDrain() throws {
        let lifetime = ProviderLifetime<Int>(), completed = Calls()
        let ticket = try lifetime.beginStart()
        // Reentrant stop while factory is outside the lifecycle lock.
        #expect(lifetime.beginStop(completion: { completed.add() }) == nil)
        #expect(throws: IsolationRefusal.revoked) { try lifetime.beginStart() }
        let result = lifetime.completeStart(ticket, resource: 7)
        #expect(!result.installed && lifetime.current == nil && completed.read() == 0)
        let work = try #require(result.cleanup); #expect(work.resource == 7)
        lifetime.completeStop(work); #expect(completed.read() == 1)
        let next = try lifetime.beginStart()
        #expect(lifetime.completeStart(next, resource: 8).installed)
    }
    @Test func concurrentStopsWaitForSameDrainAndRejectRestart() throws {
        let lifetime = ProviderLifetime<Int>(), completed = Calls()
        let ticket = try lifetime.beginStart(); #expect(lifetime.completeStart(ticket, resource: 1).installed)
        let work = try #require(lifetime.beginStop(completion: { completed.add() }))
        #expect(lifetime.beginStop(completion: { completed.add() }) == nil)
        #expect(completed.read() == 0 && lifetime.current == nil)
        #expect(throws: IsolationRefusal.revoked) { try lifetime.beginStart() }
        lifetime.completeStop(work); lifetime.completeStop(work)
        #expect(completed.read() == 2)
    }
    @Test func failedConstructionAfterStopStillCompletesStopOnce() throws {
        let lifetime = ProviderLifetime<Int>(), completed = Calls()
        let ticket = try lifetime.beginStart()
        #expect(lifetime.beginStop(completion: { completed.add() }) == nil)
        let failed = lifetime.completeStart(ticket, resource: nil)
        #expect(!failed.installed)
        lifetime.completeStop(try #require(failed.cleanup)); #expect(completed.read() == 1)
    }
    @Test func idleCallbacksCanReenterAndOldWorkCannotClearNewGeneration() throws {
        let lifetime = ProviderLifetime<Int>(), completed = Calls()
        #expect(lifetime.beginStop(completion: { completed.add(); _ = lifetime.current }) == nil)
        let old = try lifetime.beginStart(); #expect(lifetime.completeStart(old, resource: 1).installed)
        let work = try #require(lifetime.beginStop(completion: { completed.add() }))
        lifetime.completeStop(work)
        let next = try lifetime.beginStart(); #expect(lifetime.completeStart(next, resource: 2).installed)
        lifetime.completeStop(work); #expect(lifetime.current == 2 && completed.read() == 2)
        let stale = lifetime.completeStart(old, resource: 3)
        #expect(!stale.installed && stale.cleanup?.resource == 3)
        lifetime.completeStop(try #require(stale.cleanup)); #expect(lifetime.current == 2)
    }
    @Test func failedStartAndDuplicateStartupCannotOpenAuthority() throws {
        let lifetime = ProviderLifetime<Int>()
        let first = try lifetime.beginStart()
        #expect(throws: IsolationRefusal.revoked) { try lifetime.beginStart() }
        #expect(!lifetime.completeStart(first, resource: nil).installed)
        #expect(lifetime.current == nil)
        let second = try lifetime.beginStart(); #expect(lifetime.completeStart(second, resource: 4).installed)
    }
}

private final class CallbackOrder: @unchecked Sendable {
    private let lock = NSLock(); private var entries: [String] = []
    func append(_ value: String) { lock.lock(); entries.append(value); lock.unlock() }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

extension ProviderLifetimeTests {
    @Test func callbackFenceRejectsDeliberatelyBrokenOrdering() throws {
        func observe(bypassFence: Bool) throws -> [String] {
            let lifetime = ProviderLifetime<Int>(), sequencer = ProviderCallbackSequencer(), order = CallbackOrder()
            let published = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0), stopFinished = DispatchSemaphore(value: 0)
            sequencer.enqueue {
                defer { finished.signal() }
                guard let start = try? lifetime.beginStart() else { order.append("setup-failed"); published.signal(); return }
                let result = lifetime.completeStart(start, resource: 1)
                published.signal()
                guard release.wait(timeout: .now() + 2) == .success else { order.append("timeout"); return }
                order.append(result.installed ? "start-success" : "start-failure")
            }
            let ready = published.wait(timeout: .now() + 2) == .success
            #expect(ready)
            guard ready else { release.signal(); return order.read() }
            let stop: @Sendable () -> Void = {
                if let work = lifetime.beginStop(completion: { order.append("stop-complete"); stopFinished.signal() }) {
                    // An already-drained fake resource isolates callback
                    // ordering from native I/O; it is not kernel evidence.
                    lifetime.completeStop(work)
                }
            }
            if bypassFence {
                stop() // Intentional broken adapter: stop interleaves after publication.
                #expect(stopFinished.wait(timeout: .now() + 2) == .success)
            } else { sequencer.enqueue(stop) }
            release.signal()
            #expect(finished.wait(timeout: .now() + 2) == .success)
            if !bypassFence { #expect(stopFinished.wait(timeout: .now() + 2) == .success) }
            return order.read()
        }
        #expect(try observe(bypassFence: true) == ["stop-complete", "start-success"])
        #expect(try observe(bypassFence: false) == ["start-success", "stop-complete"])
    }
}
