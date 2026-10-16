import Foundation

public enum IsolationRefusal: Error, Equatable {
    case invalidScope, invalidToken, invalidClock, duplicateOwner, staleGeneration
    case capacity, unknownOwner, expired, revoked, unsupportedTransport
}

/// Kernel audit token, including PID version. A PID, UID, signing ID, or an
/// Apple signature alone cannot select a profile. This value is not a proof
/// of signature validity; the trusted registration adapter verifies that.
public struct ProcessToken: Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    private let bytes: Data
    public init(kernelBytes: Data) throws {
        guard kernelBytes.count == 32, kernelBytes.contains(where: { $0 != 0 }) else {
            throw IsolationRefusal.invalidToken
        }
        bytes = kernelBytes
    }
    public var description: String { "ProcessToken(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct IsolationScope: Hashable, Sendable {
    public let profile: UUID
    public let session: UUID
    public let revision: UInt64
    public init(profile: UUID, session: UUID, revision: UInt64) throws {
        let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        guard profile != zero, session != zero, revision > 0 else { throw IsolationRefusal.invalidScope }
        self.profile = profile; self.session = session; self.revision = revision
    }
}

public enum FlowTransport: Sendable { case tcp, udp }

/// Trusted provider control plane registers signed, dedicated profile hosts.
/// The flow plane can only acquire already registered ownership. There is no
/// Direct decision and no auto-registration from untrusted flow metadata.
/// Callbacks run outside the lock so teardown can safely call release().
public final class IsolationLedger: @unchecked Sendable {
    private struct Binding { let scope: IsolationScope; var expires: TimeInterval }
    private struct Flow { let token: ProcessToken; let scope: IsolationScope; let cancel: @Sendable () -> Void }
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private let maximumOwners: Int, maximumFlows: Int
    private var lastTime: TimeInterval = 0
    private var bindings: [ProcessToken: Binding] = [:]
    // Tombstones survive revoke/expiry during the provider lifetime, preventing
    // stale registration replay. Capacity is bounded; provider restart needs
    // new enrollment, not reuse of these in-memory records.
    private var revisions: [UUID: UInt64] = [:]
    private var sessions: Set<UUID> = []
    private var flows: [UUID: Flow] = [:]
    private var stopped = false
    public init(maximumOwners: Int = 64, maximumFlows: Int = 128,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maximumOwners = min(256, max(1, maximumOwners))
        self.maximumFlows = min(1024, max(1, maximumFlows)); self.now = now
    }
    private func time() throws -> TimeInterval {
        let value = now()
        guard value.isFinite, value >= lastTime, value >= 0 else { throw IsolationRefusal.invalidClock }
        lastTime = value; return value
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    public func registerVerifiedHost(_ token: ProcessToken, scope: IsolationScope, lifetime: TimeInterval) throws {
        try locked {
            guard !stopped else { throw IsolationRefusal.revoked }
            let stamp = try time()
            guard lifetime.isFinite, lifetime > 0, lifetime <= 15, (stamp + lifetime).isFinite else { throw IsolationRefusal.expired }
            guard bindings[token] == nil, !bindings.values.contains(where: { $0.scope.profile == scope.profile }),
                  !sessions.contains(scope.session) else { throw IsolationRefusal.duplicateOwner }
            guard scope.revision > revisions[scope.profile, default: 0] else { throw IsolationRefusal.staleGeneration }
            guard bindings.count < maximumOwners,
                  revisions[scope.profile] != nil || revisions.count < maximumOwners,
                  sessions.count < maximumOwners * 4 else { throw IsolationRefusal.capacity }
            bindings[token] = .init(scope: scope, expires: stamp + lifetime)
            revisions[scope.profile] = scope.revision; sessions.insert(scope.session)
        }
    }
    public func heartbeat(_ token: ProcessToken, scope: IsolationScope, lifetime: TimeInterval) throws {
        try locked {
            guard !stopped, var binding = bindings[token], binding.scope == scope else { throw IsolationRefusal.revoked }
            let stamp = try time()
            guard stamp < binding.expires, lifetime.isFinite, lifetime > 0, lifetime <= 15,
                  (stamp + lifetime).isFinite else { throw IsolationRefusal.expired }
            binding.expires = stamp + lifetime; bindings[token] = binding
        }
    }
    public func acquire(_ token: ProcessToken, transport: FlowTransport,
                        cancel: @escaping @Sendable () -> Void) throws -> FlowLease {
        try locked {
            guard !stopped else { throw IsolationRefusal.revoked }
            guard transport == .tcp else { throw IsolationRefusal.unsupportedTransport }
            guard let binding = bindings[token] else { throw IsolationRefusal.unknownOwner }
            guard try time() < binding.expires else { throw IsolationRefusal.expired }
            guard flows.count < maximumFlows else { throw IsolationRefusal.capacity }
            let id = UUID(); flows[id] = .init(token: token, scope: binding.scope, cancel: cancel)
            return .init(id: id, scope: binding.scope, ledger: self)
        }
    }
    fileprivate func permits(_ id: UUID, scope: IsolationScope) -> Bool {
        locked {
            guard !stopped, let flow = flows[id], flow.scope == scope,
                  let binding = bindings[flow.token], binding.scope == scope,
                  let stamp = try? time(), stamp < binding.expires else { return false }
            return true
        }
    }
    fileprivate func release(_ id: UUID) { locked { _ = flows.removeValue(forKey: id) } }
    public func revoke(_ scope: IsolationScope) {
        let callbacks: [@Sendable () -> Void] = locked {
            bindings = bindings.filter { $0.value.scope != scope }
            let ids = flows.filter { $0.value.scope == scope }.map(\.key)
            return ids.compactMap { flows.removeValue(forKey: $0)?.cancel }
        }
        callbacks.forEach { $0() }
    }
    /// A provider timer must invoke this even when no new flow arrives. It
    /// closes active idle streams; checking only new requests is insufficient.
    public func reapExpired() {
        let callbacks: [@Sendable () -> Void] = locked {
            let stamp = try? time()
            let removed = Set(bindings.filter { stamp == nil || $0.value.expires <= stamp! }.map(\.key))
            removed.forEach { bindings.removeValue(forKey: $0) }
            let ids = flows.filter { removed.contains($0.value.token) }.map(\.key)
            return ids.compactMap { flows.removeValue(forKey: $0)?.cancel }
        }
        callbacks.forEach { $0() }
    }
    public func stop() {
        let callbacks: [@Sendable () -> Void] = locked {
            stopped = true; bindings.removeAll()
            let result = flows.values.map(\.cancel); flows.removeAll(); return result
        }
        callbacks.forEach { $0() }
    }
    public var activeFlowCount: Int { locked { flows.count } }
}

/// Non-Codable and redacted; possessing a stale lease never refreshes it.
public final class FlowLease: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    public let scope: IsolationScope
    private let id: UUID
    private let ledger: IsolationLedger
    fileprivate init(id: UUID, scope: IsolationScope, ledger: IsolationLedger) {
        self.id = id; self.scope = scope; self.ledger = ledger
    }
    public var isValid: Bool { ledger.permits(id, scope: scope) }
    public func release() { ledger.release(id) }
    deinit { release() }
    public var description: String { "FlowLease(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
