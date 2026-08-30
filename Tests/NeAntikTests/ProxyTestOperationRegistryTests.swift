import Foundation
import Testing

@testable import NeAntik

struct ProxyTestOperationRegistryTests {
    @Test
    func commitSnapshotRejectsRevisionAndCredentialRaces() {
        let proxy = ProxyConfiguration(
            kind: .https,
            host: "proxy.example",
            port: 443,
            username: "user"
        )

        #expect(
            ProxyTestCommitPolicy.matchesSnapshot(
                expectedProxy: proxy,
                currentProxy: proxy,
                expectedRevision: 10,
                currentRevision: 10,
                credentialsMatch: true
            )
        )
        #expect(
            !ProxyTestCommitPolicy.matchesSnapshot(
                expectedProxy: proxy,
                currentProxy: proxy,
                expectedRevision: 10,
                currentRevision: 11,
                credentialsMatch: true
            )
        )
        #expect(
            !ProxyTestCommitPolicy.matchesSnapshot(
                expectedProxy: proxy,
                currentProxy: proxy,
                expectedRevision: 10,
                currentRevision: 10,
                credentialsMatch: false
            )
        )
    }

    @Test
    func duplicateClaimFailsUntilCurrentTokenCompletes() throws {
        let profileID = UUID()
        var registry = ProxyTestOperationRegistry()

        let claimedToken = registry.claim(profileID: profileID)
        let token = try #require(claimedToken)
        let duplicateClaim = registry.claim(profileID: profileID)

        #expect(duplicateClaim == nil)
        #expect(registry.isActive(profileID: profileID))
        #expect(registry.isCurrent(token))
        let completed = registry.complete(token)
        #expect(completed)
        #expect(registry.isEmpty)
    }

    @Test
    func currentCancellationReleasesTheProfile() throws {
        let profileID = UUID()
        var registry = ProxyTestOperationRegistry()
        let claimedToken = registry.claim(profileID: profileID)
        let token = try #require(claimedToken)

        let cancelled = registry.cancel(token)
        #expect(cancelled)
        #expect(!registry.isActive(profileID: profileID))
        let duplicateCancel = registry.cancel(token)
        #expect(!duplicateCancel)
    }

    @Test
    func cancellationByProfileIDMakesHeldTokenStale() throws {
        let profileID = UUID()
        var registry = ProxyTestOperationRegistry()
        let claimedToken = registry.claim(profileID: profileID)
        let oldToken = try #require(claimedToken)

        let cancelled = registry.cancel(profileID: profileID)
        let duplicateCancel = registry.cancel(profileID: profileID)
        #expect(cancelled)
        #expect(!duplicateCancel)

        let replacementClaim = registry.claim(profileID: profileID)
        let replacement = try #require(replacementClaim)
        let staleCompletion = registry.complete(oldToken)
        #expect(!staleCompletion)
        #expect(registry.isCurrent(replacement))
    }

    @Test
    func staleCompletionCannotClearReplacementClaim() throws {
        let profileID = UUID()
        var registry = ProxyTestOperationRegistry()
        let initialClaim = registry.claim(profileID: profileID)
        let staleToken = try #require(initialClaim)
        let initialCompletion = registry.complete(staleToken)
        #expect(initialCompletion)

        let replacementClaim = registry.claim(profileID: profileID)
        let replacement = try #require(replacementClaim)

        #expect(replacement != staleToken)
        let staleCompletion = registry.complete(staleToken)
        #expect(!staleCompletion)
        #expect(registry.isCurrent(replacement))
        #expect(registry.activeProfileIDs == Set([profileID]))
    }

    @Test
    func staleCancellationCannotClearReplacementClaim() throws {
        let profileID = UUID()
        var registry = ProxyTestOperationRegistry()
        let initialClaim = registry.claim(profileID: profileID)
        let staleToken = try #require(initialClaim)
        let initialCancellation = registry.cancel(staleToken)
        #expect(initialCancellation)

        let replacementClaim = registry.claim(profileID: profileID)
        let replacement = try #require(replacementClaim)

        let staleCancellation = registry.cancel(staleToken)
        #expect(!staleCancellation)
        #expect(registry.isCurrent(replacement))
    }

    @Test
    func cancelAllEmptiesRegistryWithoutRevalidatingOldTokens() throws {
        let firstID = UUID()
        let secondID = UUID()
        var registry = ProxyTestOperationRegistry()
        let firstClaim = registry.claim(profileID: firstID)
        let oldToken = try #require(firstClaim)
        let secondClaim = registry.claim(profileID: secondID)
        _ = try #require(secondClaim)

        registry.cancelAll()

        #expect(registry.isEmpty)
        #expect(registry.activeProfileIDs.isEmpty)
        let replacementClaim = registry.claim(profileID: firstID)
        let replacement = try #require(replacementClaim)
        let staleCompletion = registry.complete(oldToken)
        #expect(!staleCompletion)
        #expect(registry.isCurrent(replacement))
    }

    @Test
    func oneHundredRapidClaimsForOneProfileYieldOneToken() {
        let profileID = UUID()
        var registry = ProxyTestOperationRegistry()

        let tokens = (0..<100).compactMap { _ in
            registry.claim(profileID: profileID)
        }

        #expect(tokens.count == 1)
        #expect(registry.activeProfileIDs == Set([profileID]))
        #expect(registry.isCurrent(tokens[0]))
    }

    @Test
    func differentProfilesCanBeClaimedIndependently() {
        let profileIDs = (0..<100).map { _ in UUID() }
        var registry = ProxyTestOperationRegistry()

        let tokens = profileIDs.compactMap {
            registry.claim(profileID: $0)
        }

        #expect(tokens.count == profileIDs.count)
        #expect(registry.activeProfileIDs == Set(profileIDs))
    }

    @Test
    func cancellationDuringAsyncPersistenceBlocksTheLaterUICommit() throws {
        let profileID = UUID()
        var registry = ProxyTestOperationRegistry()
        let claimedToken = registry.claim(profileID: profileID)
        let token = try #require(claimedToken)

        // The first check represents ownership immediately before the awaited
        // persistent write. Editing or deleting the profile can revoke that
        // ownership while the write is suspended.
        #expect(registry.isCurrent(token))
        let cancelled = registry.cancel(profileID: profileID)
        #expect(cancelled)

        // The post-await check used by ContentView must reject the stale task
        // before it can put an obsolete health state back into visible UI.
        #expect(!registry.isCurrent(token))
    }

    @Test
    func sharedGateRejectsSecondClaimForSameProfile() async throws {
        let gate = ProxyTestExecutionGate(maximumConcurrentTests: 3)
        let profileID = UUID()
        let first = Task {
            try await gate.run(profileID: profileID) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        try await waitForGate(gate) {
            $0.activeProfileIDs == Set([profileID])
        }

        let duplicate = try await gate.run(profileID: profileID) { 2 }
        #expect(duplicate == nil)

        first.cancel()
        await expectCancellation(first)
        try await waitForGate(gate) { $0.claimedProfileIDs.isEmpty }
    }

    @Test
    func sharedGateNeverRunsMoreThanThreeOperations() async throws {
        let gate = ProxyTestExecutionGate(maximumConcurrentTests: 100)
        let probe = ProxyTestConcurrencyProbe()
        let profileIDs = (0..<12).map { _ in UUID() }

        try await withThrowingTaskGroup(of: Int?.self) { group in
            for profileID in profileIDs {
                group.addTask {
                    try await gate.run(profileID: profileID) {
                        await probe.begin()
                        do {
                            try await Task.sleep(nanoseconds: 20_000_000)
                            await probe.end()
                            return 1
                        } catch {
                            await probe.end()
                            throw error
                        }
                    }
                }
            }
            for try await result in group {
                #expect(result == 1)
            }
        }

        #expect(await probe.peak == 3)
        #expect(await probe.current == 0)
        let snapshot = await gate.snapshot()
        #expect(snapshot.claimedProfileIDs.isEmpty)
        #expect(snapshot.activeProfileIDs.isEmpty)
    }

    @Test
    func cancellationReleasesQueuedClaimAndActivePermitSafely() async throws {
        let gate = ProxyTestExecutionGate(maximumConcurrentTests: 1)
        let activeID = UUID()
        let queuedID = UUID()
        let active = Task {
            try await gate.run(profileID: activeID) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "active"
            }
        }
        try await waitForGate(gate) {
            $0.activeProfileIDs == Set([activeID])
        }

        let queued = Task {
            try await gate.run(profileID: queuedID) { "queued" }
        }
        try await waitForGate(gate) {
            $0.queuedProfileIDs == Set([queuedID])
        }
        queued.cancel()
        await expectCancellation(queued)
        try await waitForGate(gate) {
            !$0.claimedProfileIDs.contains(queuedID)
        }

        let replacement = Task {
            try await gate.run(profileID: queuedID) { "replacement" }
        }
        try await waitForGate(gate) {
            $0.queuedProfileIDs == Set([queuedID])
        }

        active.cancel()
        await expectCancellation(active)
        #expect(try await replacement.value == "replacement")

        let snapshot = await gate.snapshot()
        #expect(snapshot.claimedProfileIDs.isEmpty)
        #expect(snapshot.activeProfileIDs.isEmpty)
        #expect(snapshot.queuedProfileIDs.isEmpty)
    }
}

private actor ProxyTestConcurrencyProbe {
    private(set) var current = 0
    private(set) var peak = 0

    func begin() {
        current += 1
        peak = max(peak, current)
    }

    func end() {
        current -= 1
    }
}

private func waitForGate(
    _ gate: ProxyTestExecutionGate,
    matching predicate: (ProxyTestExecutionSnapshot) -> Bool
) async throws {
    for _ in 0..<2_000 {
        if predicate(await gate.snapshot()) {
            return
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ProxyTestGateTimeoutError()
}

private struct ProxyTestGateTimeoutError: Error {}

private func expectCancellation<Value: Sendable>(
    _ task: Task<Value, Error>
) async {
    switch await task.result {
    case .success:
        Issue.record("Expected task cancellation")
    case let .failure(error):
        #expect(error is CancellationError)
    }
}
