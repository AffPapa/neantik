import Foundation

/// Holds accepted connections until the private owner has bound the exact
/// browser session. Waiting does not read browser bytes or dial an upstream.
/// Opening is irreversible; this object cannot be reused for another session.
actor ProxyRelayBindingGate {
    enum Failure: Error { case closed, timeout, invalidLimit, alreadyBound }
    private enum State { case waiting, bound, closed }
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let deadline: Task<Void, Never>
    }
    private var state: State = .waiting
    private var waiters: [UUID: Waiter] = [:]
    private let maximumWaiters: Int

    init(maximumWaiters: Int = 8) throws {
        guard (1...64).contains(maximumWaiters) else { throw Failure.invalidLimit }
        self.maximumWaiters = maximumWaiters
    }

    func wait(timeout: TimeInterval = 5) async throws {
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw Failure.invalidLimit }
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                switch state {
                case .bound: continuation.resume()
                case .closed: continuation.resume(throwing: Failure.closed)
                case .waiting:
                    guard waiters.count < maximumWaiters else { continuation.resume(throwing: Failure.invalidLimit); return }
                    let deadline = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                        catch { return }
                        await self?.expire(id)
                    }
                    waiters[id] = Waiter(continuation: continuation, deadline: deadline)
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    /// The owner must install validated immutable authority BEFORE opening.
    func open() throws {
        guard case .waiting = state else {
            if case .bound = state { throw Failure.alreadyBound }
            throw Failure.closed
        }
        state = .bound
        let pending = waiters; waiters.removeAll()
        for waiter in pending.values { waiter.deadline.cancel(); waiter.continuation.resume() }
    }

    func close() {
        state = .closed
        let pending = waiters; waiters.removeAll()
        for waiter in pending.values { waiter.deadline.cancel(); waiter.continuation.resume(throwing: Failure.closed) }
    }
    func pendingCount() -> Int { waiters.count }
    private func cancel(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.deadline.cancel(); waiter.continuation.resume(throwing: CancellationError())
    }
    private func expire(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: Failure.timeout)
    }
}
