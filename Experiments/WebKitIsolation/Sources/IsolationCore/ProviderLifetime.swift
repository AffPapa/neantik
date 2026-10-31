import Foundation

/// Coordinates synchronous framework callbacks with asynchronous native drain.
/// Resource construction and every callback run outside the state lock.
public final class ProviderLifetime<Resource: Sendable>: @unchecked Sendable {
    public struct StartTicket: Sendable { fileprivate let id: UUID }
    public struct StopWork: Sendable {
        fileprivate let generation: UUID?
        public let resource: Resource?
    }
    public struct Publication: Sendable {
        public let installed: Bool
        public let cleanup: StopWork?
    }
    private enum State { case idle, starting(UUID), running(UUID, Resource), stopping(UUID, awaitingStart: Bool) }
    private let lock = NSLock()
    private var state = State.idle
    private var completions: [@Sendable () -> Void] = []
    public init() {}
    public func beginStart() throws -> StartTicket {
        lock.lock(); defer { lock.unlock() }
        guard case .idle = state else { throw IsolationRefusal.revoked }
        let ticket = StartTicket(id: UUID()); state = .starting(ticket.id); return ticket
    }
    /// A nil resource represents failed startup. A resource completed after a
    /// concurrent stop is drained, never published into a new generation.
    public func completeStart(_ ticket: StartTicket, resource: Resource?) -> Publication {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .starting(let id) where id == ticket.id:
            if let resource { state = .running(id, resource); return .init(installed: true, cleanup: nil) }
            state = .idle; return .init(installed: false, cleanup: nil)
        case .stopping(let id, awaitingStart: true) where id == ticket.id:
            state = .stopping(id, awaitingStart: false)
            return .init(installed: false, cleanup: .init(generation: id, resource: resource))
        default:
            return .init(installed: false, cleanup: resource.map { .init(generation: nil, resource: $0) })
        }
    }
    public var current: Resource? {
        lock.lock(); defer { lock.unlock() }
        if case .running(_, let value) = state { return value }; return nil
    }
    public func beginStop(completion: @escaping @Sendable () -> Void) -> StopWork? {
        lock.lock()
        switch state {
        case .idle:
            lock.unlock(); completion(); return nil
        case .starting(let id):
            completions.append(completion); state = .stopping(id, awaitingStart: true)
            lock.unlock(); return nil
        case .running(let id, let value):
            completions.append(completion); state = .stopping(id, awaitingStart: false)
            lock.unlock(); return .init(generation: id, resource: value)
        case .stopping:
            completions.append(completion); lock.unlock(); return nil
        }
    }
    /// Called only after StopWork.resource has drained. Concurrent stop callers
    /// share that drain; none receives an early completion.
    public func completeStop(_ work: StopWork) {
        lock.lock()
        guard let id = work.generation, case .stopping(let currentID, awaitingStart: false) = state, currentID == id else { lock.unlock(); return }
        let callbacks = completions; completions.removeAll(); state = .idle; lock.unlock()
        callbacks.forEach { $0() }
    }
}

/// Framework lifecycle callbacks and completed drains use one FIFO. Resource
/// construction must be nonblocking and must not wait on a framework callback.
/// Reentrant API calls enqueue work instead of recursively taking a lock.
public final class ProviderCallbackSequencer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.neantik.isolation.provider-lifecycle")
    public init() {}
    public func enqueue(_ operation: @escaping @Sendable () -> Void) { queue.async(execute: operation) }
}
