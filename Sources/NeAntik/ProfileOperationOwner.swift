import Foundation

/// Window-local claims and optional dedicated tasks. Bulk child operations
/// borrow their parent's task; they still own a generation-bound claim.
struct ProfileOperationOwner {
    private var claims = ProxyTestOperationRegistry()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var activeProfileIDs: Set<UUID> { claims.activeProfileIDs }
    func isActive(_ id: UUID) -> Bool { claims.isActive(profileID: id) }
    func isCurrent(_ token: ProxyTestOperationToken) -> Bool { claims.isCurrent(token) }

    mutating func claim(_ id: UUID) -> ProxyTestOperationToken? {
        claims.claim(profileID: id)
    }

    mutating func attach(_ task: Task<Void, Never>, to token: ProxyTestOperationToken) {
        guard claims.isCurrent(token) else {
            task.cancel()
            return
        }
        tasks[token.profileID]?.cancel()
        tasks[token.profileID] = task
    }

    mutating func finish(_ token: ProxyTestOperationToken) {
        guard claims.complete(token) else { return }
        tasks[token.profileID] = nil
    }

    mutating func cancel(_ id: UUID) {
        claims.cancel(profileID: id)
        tasks.removeValue(forKey: id)?.cancel()
    }

    mutating func cancelAll() {
        claims.cancelAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
