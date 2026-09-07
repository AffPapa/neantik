import Foundation

/// Window-local claims and cancellation for independently owned operations.
struct ProfileOperationOwner {
    private var claims = ProxyTestOperationRegistry()
    private var tasks: [UUID: @Sendable () -> Void] = [:]

    var activeProfileIDs: Set<UUID> { claims.activeProfileIDs }
    func isActive(_ id: UUID) -> Bool { claims.isActive(profileID: id) }
    func isCurrent(_ token: ProxyTestOperationToken) -> Bool { claims.isCurrent(token) }

    mutating func claim(_ id: UUID) -> ProxyTestOperationToken? {
        claims.claim(profileID: id)
    }

    mutating func attach<Result: Sendable>(
        _ task: Task<Result, Never>, to token: ProxyTestOperationToken
    ) {
        guard claims.isCurrent(token) else {
            task.cancel()
            return
        }
        tasks[token.profileID]?()
        tasks[token.profileID] = { task.cancel() }
    }

    mutating func finish(_ token: ProxyTestOperationToken) {
        guard claims.complete(token) else { return }
        tasks[token.profileID] = nil
    }

    mutating func cancel(_ id: UUID) {
        claims.cancel(profileID: id)
        tasks.removeValue(forKey: id)?()
    }

    mutating func cancelAll() {
        claims.cancelAll()
        tasks.values.forEach { $0() }
        tasks.removeAll()
    }

    /// Cancellation propagates to the child, but the waiter still waits for
    /// persistence rollback and execution-permit release before returning.
    static func value<Result: Sendable>(of task: Task<Result, Never>) async -> Result {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
