import Foundation

/// Opaque ownership token for one claimed profile proxy test.
///
/// A token is bound to both the profile and the exact claim generation. This
/// lets an older task finish safely without clearing a newer replacement.
struct ProxyTestOperationToken: Hashable, Sendable {
    let profileID: UUID
    fileprivate let generation: UInt64
}

/// Pure single-flight state for profile proxy tests.
///
/// This type deliberately owns no tasks and performs no I/O. Callers claim a
/// profile synchronously before starting work, then complete or cancel using
/// the returned token.
struct ProxyTestOperationRegistry: Equatable, Sendable {
    private var activeTokens: [UUID: ProxyTestOperationToken] = [:]
    private var nextGeneration: UInt64 = 0

    var activeProfileIDs: Set<UUID> {
        Set(activeTokens.keys)
    }

    var isEmpty: Bool {
        activeTokens.isEmpty
    }

    func isActive(profileID: UUID) -> Bool {
        activeTokens[profileID] != nil
    }

    func isCurrent(_ token: ProxyTestOperationToken) -> Bool {
        activeTokens[token.profileID] == token
    }

    mutating func claim(profileID: UUID) -> ProxyTestOperationToken? {
        guard activeTokens[profileID] == nil else { return nil }

        nextGeneration &+= 1
        let token = ProxyTestOperationToken(
            profileID: profileID,
            generation: nextGeneration
        )
        activeTokens[profileID] = token
        return token
    }

    @discardableResult
    mutating func complete(_ token: ProxyTestOperationToken) -> Bool {
        clearIfCurrent(token)
    }

    @discardableResult
    mutating func cancel(_ token: ProxyTestOperationToken) -> Bool {
        clearIfCurrent(token)
    }

    /// Cancels whichever claim currently owns the profile.
    ///
    /// This is intended for synchronous profile teardown paths that do not
    /// retain a second token map. A task holding the removed token becomes
    /// stale immediately and cannot clear a later replacement claim.
    @discardableResult
    mutating func cancel(profileID: UUID) -> Bool {
        activeTokens.removeValue(forKey: profileID) != nil
    }

    mutating func cancelAll() {
        activeTokens.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private mutating func clearIfCurrent(
        _ token: ProxyTestOperationToken
    ) -> Bool {
        guard isCurrent(token) else { return false }
        activeTokens[token.profileID] = nil
        return true
    }
}

/// Final publication gate for an asynchronous proxy test.
///
/// Operation ownership is local to one window, while `ProfileStore` is shared.
/// Revalidating the exact proxy revision therefore prevents another window's
/// edit from being overwritten by a result that was suspended in persistence.
struct ProxyTestCommitPolicy {
    static func matchesSnapshot(
        expectedProxy: ProxyConfiguration,
        currentProxy: ProxyConfiguration?,
        expectedRevision: UInt64,
        currentRevision: UInt64,
        credentialsMatch: Bool
    ) -> Bool {
        expectedProxy == currentProxy &&
            expectedRevision == currentRevision &&
            credentialsMatch
    }
}

struct ProxyTestExecutionSnapshot: Equatable, Sendable {
    let claimedProfileIDs: Set<UUID>
    let activeProfileIDs: Set<UUID>
    let queuedProfileIDs: Set<UUID>
}

/// App-scoped execution gate for every proxy-test entry point.
///
/// A profile is claimed before it can enter the queue, so a second window
/// cannot enqueue the same profile. Active permits are released only after the
/// operation exits; cancelling an active task therefore cannot temporarily
/// exceed the global concurrency limit if its operation is slow to unwind.
actor ProxyTestExecutionGate {
    static let globalMaximumConcurrentTests = 3
    static let appShared = ProxyTestExecutionGate()

    private struct Token: Hashable, Sendable {
        let profileID: UUID
        let generation: UInt64
    }

    private let maximumConcurrentTests: Int
    private var nextGeneration: UInt64 = 0
    private var claims: [UUID: Token] = [:]
    private var activeTokens: Set<Token> = []
    private var waitOrder: [Token] = []
    private var waiters: [Token: CheckedContinuation<Void, Never>] = [:]

    init(maximumConcurrentTests: Int = 3) {
        self.maximumConcurrentTests = min(
            max(1, maximumConcurrentTests),
            Self.globalMaximumConcurrentTests
        )
    }

    func snapshot() -> ProxyTestExecutionSnapshot {
        ProxyTestExecutionSnapshot(
            claimedProfileIDs: Set(claims.keys),
            activeProfileIDs: Set(activeTokens.map(\.profileID)),
            queuedProfileIDs: Set(waitOrder.map(\.profileID))
        )
    }

    func run<Result: Sendable>(
        profileID: UUID,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result? {
        guard let token = claim(profileID: profileID) else { return nil }

        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                await waitForPermit(token)
                try Task.checkCancellation()
                let result = try await operation()
                release(token)
                return result
            } onCancel: {
                Task {
                    await self.cancelWaitingClaim(token)
                }
            }
        } catch {
            release(token)
            throw error
        }
    }

    private func claim(profileID: UUID) -> Token? {
        guard claims[profileID] == nil else { return nil }
        nextGeneration &+= 1
        let token = Token(
            profileID: profileID,
            generation: nextGeneration
        )
        claims[profileID] = token
        return token
    }

    private func waitForPermit(_ token: Token) async {
        guard claims[token.profileID] == token else { return }
        if activeTokens.count < maximumConcurrentTests {
            activeTokens.insert(token)
            return
        }

        await withCheckedContinuation { continuation in
            guard claims[token.profileID] == token else {
                continuation.resume()
                return
            }
            waitOrder.append(token)
            waiters[token] = continuation
        }
    }

    private func cancelWaitingClaim(_ token: Token) {
        guard claims[token.profileID] == token,
              !activeTokens.contains(token)
        else {
            return
        }
        claims[token.profileID] = nil
        waitOrder.removeAll { $0 == token }
        waiters.removeValue(forKey: token)?.resume()
    }

    private func release(_ token: Token) {
        guard claims[token.profileID] == token else { return }
        claims[token.profileID] = nil
        activeTokens.remove(token)
        waitOrder.removeAll { $0 == token }
        waiters.removeValue(forKey: token)?.resume()
        promoteWaiters()
    }

    private func promoteWaiters() {
        while activeTokens.count < maximumConcurrentTests,
              !waitOrder.isEmpty
        {
            let token = waitOrder.removeFirst()
            guard claims[token.profileID] == token,
                  let continuation = waiters.removeValue(forKey: token)
            else {
                continue
            }
            activeTokens.insert(token)
            continuation.resume()
        }
    }
}
