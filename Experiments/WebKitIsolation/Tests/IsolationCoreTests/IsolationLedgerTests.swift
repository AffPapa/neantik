import Foundation
import Testing
@testable import IsolationCore

private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 100
    func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
@Suite struct IsolationLedgerTests {
    private func token(_ byte: UInt8) throws -> ProcessToken {
        try .init(kernelBytes: Data(repeating: byte, count: 32))
    }
    private func scope(profile: UUID = UUID(), session: UUID = UUID(), revision: UInt64 = 1) throws -> IsolationScope {
        try .init(profile: profile, session: session, revision: revision)
    }
    @Test func unknownOwnerAndUDPHaveNoRoute() throws {
        let ledger = IsolationLedger(), owner = try token(1)
        #expect(throws: IsolationRefusal.unknownOwner) { try ledger.acquire(owner, transport: .tcp, cancel: {}) }
        try ledger.registerVerifiedHost(owner, scope: scope(), lifetime: 10)
        #expect(throws: IsolationRefusal.unsupportedTransport) { try ledger.acquire(owner, transport: .udp, cancel: {}) }
        #expect(ledger.activeFlowCount == 0)
    }
    @Test func fullAuditTokenIncludesPIDIncarnation() throws {
        let ledger = IsolationLedger(), bytes = Data(repeating: UInt8(1), count: 32)
        var other = bytes; other[31] = 2
        let a = try ProcessToken(kernelBytes: bytes), reusedPID = try ProcessToken(kernelBytes: other)
        try ledger.registerVerifiedHost(a, scope: scope(), lifetime: 10)
        #expect(throws: IsolationRefusal.unknownOwner) { try ledger.acquire(reusedPID, transport: .tcp, cancel: {}) }
        let valid = try ledger.acquire(a, transport: .tcp, cancel: {})
        #expect(valid.isValid)
    }
    @Test func revokeCancelsOnlyItsProfileAndIsIdempotent() throws {
        let ledger = IsolationLedger(), a = try token(1), b = try token(2)
        let sa = try scope(), sb = try scope(), ca = Counter(), cb = Counter()
        try ledger.registerVerifiedHost(a, scope: sa, lifetime: 10)
        try ledger.registerVerifiedHost(b, scope: sb, lifetime: 10)
        let la = try ledger.acquire(a, transport: .tcp, cancel: { ca.increment() })
        let lb = try ledger.acquire(b, transport: .tcp, cancel: { cb.increment() })
        ledger.revoke(sa); ledger.revoke(sa)
        #expect(!la.isValid && lb.isValid && ca.read() == 1 && cb.read() == 0)
        #expect(ledger.activeFlowCount == 1)
    }
    @Test func expiredLeaseDoesNotReviveThroughHeartbeat() throws {
        let clock = Clock(), count = Counter(), ledger = IsolationLedger(now: { clock.read() })
        let a = try token(1), s = try scope()
        try ledger.registerVerifiedHost(a, scope: s, lifetime: 2)
        let lease = try ledger.acquire(a, transport: .tcp, cancel: { count.increment() })
        clock.set(102)
        #expect(!lease.isValid)
        #expect(throws: IsolationRefusal.expired) { try ledger.heartbeat(a, scope: s, lifetime: 2) }
        ledger.reapExpired(); ledger.reapExpired()
        #expect(count.read() == 1 && ledger.activeFlowCount == 0)
    }
    @Test func heartbeatNeedsSameScopeAndDoesNotGrantNewOwner() throws {
        let clock = Clock(), ledger = IsolationLedger(now: { clock.read() })
        let a = try token(1), s = try scope()
        try ledger.registerVerifiedHost(a, scope: s, lifetime: 2)
        #expect(throws: IsolationRefusal.revoked) { try ledger.heartbeat(token(2), scope: s, lifetime: 2) }
        #expect(throws: IsolationRefusal.revoked) { try ledger.heartbeat(a, scope: scope(), lifetime: 2) }
        clock.set(101); try ledger.heartbeat(a, scope: s, lifetime: 2); clock.set(102)
        let lease = try ledger.acquire(a, transport: .tcp, cancel: {})
        #expect(lease.isValid)
    }
    @Test func staleGenerationAndSessionReplayRefused() throws {
        let ledger = IsolationLedger(), a = try token(1), s = try scope()
        try ledger.registerVerifiedHost(a, scope: s, lifetime: 2); ledger.revoke(s)
        #expect(throws: IsolationRefusal.duplicateOwner) { try ledger.registerVerifiedHost(a, scope: s, lifetime: 2) }
        let stale = try scope(profile: s.profile)
        #expect(throws: IsolationRefusal.staleGeneration) { try ledger.registerVerifiedHost(a, scope: stale, lifetime: 2) }
        let next = try scope(profile: s.profile, revision: 2)
        try ledger.registerVerifiedHost(a, scope: next, lifetime: 2)
        ledger.revoke(s) // old EOF/revoke must not stop the new lifetime
        let lease = try ledger.acquire(a, transport: .tcp, cancel: {})
        #expect(lease.isValid && lease.scope == next)
    }
    @Test func duplicateHostAndProfileCannotBeRebound() throws {
        let ledger = IsolationLedger(), a = try token(1), s = try scope()
        try ledger.registerVerifiedHost(a, scope: s, lifetime: 2)
        #expect(throws: IsolationRefusal.duplicateOwner) { try ledger.registerVerifiedHost(a, scope: scope(), lifetime: 2) }
        #expect(throws: IsolationRefusal.duplicateOwner) { try ledger.registerVerifiedHost(token(2), scope: scope(profile: s.profile, revision: 2), lifetime: 2) }
    }
    @Test func flowCapacityAndReleaseAreBounded() throws {
        let ledger = IsolationLedger(maximumFlows: 1), a = try token(1)
        try ledger.registerVerifiedHost(a, scope: scope(), lifetime: 10)
        let first = try ledger.acquire(a, transport: .tcp, cancel: {})
        #expect(throws: IsolationRefusal.capacity) { try ledger.acquire(a, transport: .tcp, cancel: {}) }
        first.release(); first.release(); #expect(!first.isValid)
        let next = try ledger.acquire(a, transport: .tcp, cancel: {}); #expect(next.isValid)
    }
    @Test func clockRollbackAndNonFiniteValuesFailClosed() throws {
        let clock = Clock(), ledger = IsolationLedger(now: { clock.read() }), count = Counter(), a = try token(1)
        try ledger.registerVerifiedHost(a, scope: scope(), lifetime: 10)
        let lease = try ledger.acquire(a, transport: .tcp, cancel: { count.increment() })
        clock.set(99); #expect(!lease.isValid); ledger.reapExpired()
        #expect(count.read() == 1)
        clock.set(.nan)
        #expect(throws: IsolationRefusal.invalidClock) { try ledger.registerVerifiedHost(token(2), scope: scope(), lifetime: 1) }
    }
    @Test func stopCannotBeReopenedAndCallbacksCanReenter() throws {
        let ledger = IsolationLedger(), a = try token(1), s = try scope(), count = Counter()
        try ledger.registerVerifiedHost(a, scope: s, lifetime: 10)
        let lease = try ledger.acquire(a, transport: .tcp, cancel: { count.increment(); ledger.revoke(s) })
        ledger.stop(); ledger.stop(); #expect(count.read() == 1 && !lease.isValid)
        #expect(throws: IsolationRefusal.revoked) { try ledger.registerVerifiedHost(a, scope: scope(revision: 2), lifetime: 10) }
    }
    @Test func concurrentAcquireAndRevokeNeverLeaveLiveLeases() throws {
        let ledger = IsolationLedger(), a = try token(1), s = try scope()
        try ledger.registerVerifiedHost(a, scope: s, lifetime: 10)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 5) { ledger.revoke(s) }
            else { let lease = try? ledger.acquire(a, transport: .tcp, cancel: {}); lease?.release() }
        }
        ledger.revoke(s); #expect(ledger.activeFlowCount == 0)
        #expect(throws: IsolationRefusal.unknownOwner) { try ledger.acquire(a, transport: .tcp, cancel: {}) }
    }
    @Test func invalidInputsAndReflectionDoNotExposeTokens() throws {
        #expect(throws: IsolationRefusal.invalidToken) { try ProcessToken(kernelBytes: Data(repeating: 1, count: 31)) }
        #expect(throws: IsolationRefusal.invalidToken) { try ProcessToken(kernelBytes: Data(repeating: 0, count: 32)) }
        let a = try token(7), ledger = IsolationLedger()
        #expect(Mirror(reflecting: a).children.isEmpty)
        #expect(String(describing: a) == "ProcessToken(<redacted>)")
        #expect(throws: IsolationRefusal.expired) { try ledger.registerVerifiedHost(a, scope: scope(), lifetime: .infinity) }
        #expect(throws: IsolationRefusal.expired) { try ledger.registerVerifiedHost(a, scope: scope(), lifetime: 16) }
    }
}
