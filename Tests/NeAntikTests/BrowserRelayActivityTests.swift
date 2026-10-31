import Foundation
import Testing
@testable import NeAntik

struct BrowserRelayActivityTests {
    private final class Clock: @unchecked Sendable {
        let lock = NSLock(); var value: UInt64 = 1_000_000_000
        func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: UInt64) { lock.lock(); self.value = value; lock.unlock() }
    }
    @Test func noActivityIsNotTransportOrRequestSuccess() {
        let s = BrowserRelayActivity().snapshot()
        #expect(s.admittedConnections == 0 && s.upstreamTunnels == 0 && s.successRepliesSent == 0)
        #expect(s.sequence == 0 && s.lastEnd == nil && s.lastFailure == nil && s.lastEventAgeMilliseconds == nil)
    }
    @Test func tunnelAndReplySendAreDistinctAndExactlyOnce() throws {
        let ledger = BrowserRelayActivity(), ticket = try #require(ledger.begin())
        ledger.replySent(ticket) // cannot send a reply for a missing upstream tunnel
        #expect(ledger.snapshot().successRepliesSent == 0)
        ledger.established(ticket); ledger.established(ticket)
        #expect(ledger.snapshot().upstreamTunnels == 1 && ledger.snapshot().successRepliesSent == 0)
        ledger.replySent(ticket); ledger.replySent(ticket)
        ledger.finish(ticket, as: .completed); ledger.finish(ticket, as: .streamFailed)
        let s = ledger.snapshot()
        #expect(s.sequence == 4 && s.admittedConnections == 1 && s.successRepliesSent == 1)
        #expect(s.completedConnections == 1 && s.failedConnections == 0 && s.activeConnections == 0)
        #expect(s.lastFailure == nil)
    }
    @Test func concurrentCancellationDoesNotEraseConcreteFailure() async {
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            let concrete = BrowserRelayActivity.End.failure(ProxyRelayTransportError.posixFailure(54), during: .streamFailed)
            let refusal = BrowserRelayActivity.End.failure(ProxyRelayTransportError.authorizationRejected, during: .upstreamNegotiationFailed)
            let cancelled = BrowserRelayActivity.End.failure(CancellationError(), during: .streamFailed)
            return (concrete, refusal, cancelled)
        }.value
        #expect(result.0 == .streamFailed && result.1 == .admissionRevoked && result.2 == .cancelled)
    }
    @Test func anotherRelayTicketCannotConferEvidence() throws {
        let first = BrowserRelayActivity(), second = BrowserRelayActivity()
        let ticket = try #require(first.begin())
        second.established(ticket); second.replySent(ticket); second.finish(ticket, as: .completed)
        #expect(second.snapshot().sequence == 0)
        #expect(first.snapshot().activeConnections == 1)
    }
    @Test func laterSuccessDoesNotErasePreviousFailureOrImplyAllStreamsHealthy() throws {
        let ledger = BrowserRelayActivity(), failing = try #require(ledger.begin()), healthy = try #require(ledger.begin())
        ledger.finish(failing, as: .upstreamNegotiationFailed)
        let failureSequence = ledger.snapshot().sequence
        ledger.established(healthy); ledger.replySent(healthy); ledger.finish(healthy, as: .completed)
        let s = ledger.snapshot()
        #expect(s.lastEnd == .completed && s.lastFailure == .upstreamNegotiationFailed)
        #expect(s.lastFailureSequence == failureSequence && s.failedConnections == 1 && s.completedConnections == 1)
    }
    @Test func stoppingListenerRefusesNewTicketsWithoutPretendingPendingStreamsDrained() throws {
        let ledger = BrowserRelayActivity(), ticket = try #require(ledger.begin())
        ledger.listenerDidStop(); let stoppedSequence = ledger.snapshot().sequence
        ledger.listenerDidStop()
        #expect(ledger.begin() == nil && ledger.snapshot().sequence == stoppedSequence)
        #expect(ledger.snapshot().listenerStopped && ledger.snapshot().activeConnections == 1)
        ledger.finish(ticket, as: .cancelled)
        #expect(ledger.snapshot().activeConnections == 0 && ledger.snapshot().cancelledConnections == 1)
        #expect(ledger.snapshot().lastFailure == nil)
    }
    @Test func quietTimeIsAgeOfEventAndNeverAutomaticFailure() throws {
        let clock = Clock(), ledger = BrowserRelayActivity(clock: { clock.now() })
        let ticket = try #require(ledger.begin()); ledger.established(ticket)
        clock.set(91_000_000_000)
        let s = ledger.snapshot()
        #expect(s.lastEventAgeMilliseconds == 90_000 && s.activeConnections == 1 && s.failedConnections == 0)
        #expect(ledger.snapshot().sequence == s.sequence)
        clock.set(0)
        #expect(ledger.snapshot().lastEventAgeMilliseconds == 0) // defensive injected clock rollback
    }
    @Test func snapshotHasOnlyFixedAllowlistedScalars() throws {
        let data = try JSONEncoder().encode(BrowserRelayActivity().snapshot())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "sequence", "admittedConnections", "upstreamTunnels", "successRepliesSent", "completedConnections", "failedConnections", "cancelledConnections", "activeConnections", "listenerStopped", "countersSaturated"])
        let string = String(decoding: data, as: UTF8.self)
        for forbidden in ["host", "destination", "password", "url", "processID", "profileID", "payload"] { #expect(!string.contains(forbidden)) }
    }
    @Test func boundedCountersDeclareLossOfExactnessAndDoNotOverflow() throws {
        let ledger = BrowserRelayActivity(counterLimit: 2)
        for _ in 0..<3 { let ticket = try #require(ledger.begin()); ledger.finish(ticket, as: .completed) }
        let s = ledger.snapshot()
        #expect(s.admittedConnections == 2 && s.completedConnections == 2 && s.sequence == 2 && s.countersSaturated)
        #expect(s.activeConnections == 0)
    }
    @Test func activeStateIsBoundedAndFreedTicketPermitsAnotherConnection() throws {
        let ledger = BrowserRelayActivity()
        let tickets = try (0..<64).map { _ in try #require(ledger.begin()) }
        #expect(ledger.begin() == nil && ledger.snapshot().activeConnections == 64)
        ledger.finish(tickets[0], as: .completed)
        #expect(ledger.begin() != nil && ledger.snapshot().activeConnections == 64)
    }
    @Test func concurrentExactlyOnceFinishesRetainInvariants() async {
        let ledger = BrowserRelayActivity()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    guard let ticket = ledger.begin() else { Issue.record("Bounded concurrent stream refused"); return }
                    ledger.established(ticket); ledger.replySent(ticket)
                    ledger.finish(ticket, as: .completed); ledger.finish(ticket, as: .streamFailed)
                }
            }
        }
        let s = ledger.snapshot()
        #expect(s.admittedConnections == 32 && s.upstreamTunnels == 32 && s.successRepliesSent == 32)
        #expect(s.completedConnections == 32 && s.failedConnections == 0 && s.activeConnections == 0 && s.sequence == 128)
    }
}
