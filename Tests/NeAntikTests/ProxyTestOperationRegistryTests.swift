import Foundation
import Testing

@testable import NeAntik

struct ProxyTestOperationRegistryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [0, 1, 2]) @MainActor
    func ownedChildCancellationWaitsForExitAndPreventsHealthPublication(
        cancelParent: Bool, boundary: Int
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-owned-proxy-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("health.json")
        let profile = BrowserProfile(name: "Test", proxy: ProxyConfiguration(
            kind: .http, host: "proxy.example", port: 8080, username: ""
        ))
        let barrier = OwnedProxyBoundaryBarrier()
        let gate = ProxyTestExecutionGate()
        let coordinator = ProxyHealthCoordinator(
            fileURL: fileURL, executionGate: gate,
            commitBoundaryHook: {
                if boundary == 2 {
                    await barrier.suspend()
                }
            }
        )
        var owner = ProfileOperationOwner()
        let claim = owner.claim(profile.id)
        let token = try #require(claim)
        let siblingClaim = owner.claim(UUID())
        let sibling = try #require(siblingClaim)
        let child = Task { @MainActor in
            defer { owner.finish(token) }
            do {
                let result = try await coordinator.run(profile: profile) { _ in
                    if boundary != 2 {
                        await barrier.suspend()
                    }
                    // A non-cooperative probe may return success or a mapped
                    // ProxyProbeError even after cancellation was requested.
                    do {
                        if boundary == 1 {
                            throw ProxyProbeError(outcome: .connectionFailed)
                        }
                        return ProxyHealthUpdatePolicy.success(ProxyTestObservation(
                            observedAt: Date(), responseTimeMilliseconds: 12,
                            result: ProxyTestResult(
                                ipAddress: "203.0.113.1", city: nil,
                                countryName: nil, countryCode: nil,
                                timezoneIdentifier: "UTC", localeIdentifier: "en-US"
                            )
                        ))
                    } catch let error as ProxyProbeError {
                        return ProxyHealthUpdatePolicy.failure(
                            error, checkedAt: Date(), previous: nil
                        )
                    }
                } != nil
                await barrier.completed(error: nil)
                return result
            } catch {
                await barrier.completed(error: String(describing: error))
                return false
            }
        }
        owner.attach(child, to: token)
        var waiterExited = false
        let waiter = Task { @MainActor in
            let result = await ProfileOperationOwner.value(of: child)
            waiterExited = true
            return result
        }
        do {
            try await barrier.waitUntilReached()
        } catch {
            child.cancel()
            waiter.cancel()
            await barrier.resume()
            throw error
        }
        if cancelParent { waiter.cancel() } else { owner.cancel(profile.id) }
        let pending = await gate.snapshot()
        #expect(pending.activeProfileIDs.contains(profile.id))
        #expect(!waiterExited)
        #expect(owner.isCurrent(sibling))
        await barrier.resume()
        #expect(await waiter.value == false)
        #expect(child.isCancelled)
        let finished = await gate.snapshot()
        #expect(finished.claimedProfileIDs.isEmpty)
        #expect(!coordinator.isTesting(profileID: profile.id))
        #expect(coordinator.healthByProfileID[profile.id] == nil)
        let reloaded = try ProxyHealthStore(fileURL: fileURL)
        #expect(await reloaded.state(for: profile.id) == nil)
    }

    @Test @MainActor
    func cancelledQueuedLaunchCannotClaimProxyBeforeReplacement() async throws {
        var launches = ProfileOperationOwner()
        var proxies = ProfileOperationOwner()
        let id = UUID()
        let oldClaim = launches.claim(id)
        let old = try #require(oldClaim)
        var oldClaimedProxy = false
        let queued = Task { @MainActor in
            defer { launches.finish(old) }
            guard !Task.isCancelled, launches.isCurrent(old) else { return }
            oldClaimedProxy = proxies.claim(id) != nil
        }
        launches.attach(queued, to: old)
        // No suspension: cancellation and replacement happen before queued work runs.
        launches.cancel(id)
        let replacementClaim = launches.claim(id)
        let replacement = try #require(replacementClaim)
        await queued.value
        #expect(!oldClaimedProxy)
        #expect(launches.isCurrent(replacement))
        let proxyClaim = proxies.claim(id)
        #expect(proxyClaim != nil)
        launches.finish(replacement)
    }

    @Test
    func windowOwnerStaleCompletionCannotClearReplacementTask() throws {
        var owner = ProfileOperationOwner()
        let id = UUID()
        let oldClaim = owner.claim(id)
        let old = try #require(oldClaim)
        owner.cancel(id)
        let currentClaim = owner.claim(id)
        let current = try #require(currentClaim)
        let task = Task<Void, Never> { }
        owner.attach(task, to: current)
        owner.finish(old)
        #expect(owner.isCurrent(current))
        #expect(!task.isCancelled)
        owner.cancel(id)
        #expect(task.isCancelled)
        #expect(owner.activeProfileIDs.isEmpty)
    }

    @Test
    func windowOwnerRejectsStaleAttachmentAndKeepsBorrowedClaimsIndependent() throws {
        var owner = ProfileOperationOwner()
        let firstClaim = owner.claim(UUID())
        let first = try #require(firstClaim)
        let borrowedClaim = owner.claim(UUID())
        let borrowed = try #require(borrowedClaim)
        owner.cancel(first.profileID)
        let staleTask = Task<Void, Never> { }
        owner.attach(staleTask, to: first)
        #expect(staleTask.isCancelled)
        #expect(owner.isCurrent(borrowed))
        owner.cancelAll()
        owner.finish(borrowed)
        #expect(owner.activeProfileIDs.isEmpty)
    }

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

private actor OwnedProxyBoundaryBarrier {
    private var reached = false
    private var released = false
    private var finished = false
    private var completionError: String?
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        reached = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func completed(error: String?) {
        finished = true
        completionError = error
    }

    func waitUntilReached() async throws {
        for _ in 0..<2_000 {
            if reached { return }
            if finished {
                throw BoundaryFailure(reason: completionError ?? "Operation exited before boundary")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw BoundaryFailure(reason: "Timed out waiting for operation boundary")
    }

    func resume() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private struct BoundaryFailure: Error {
        let reason: String
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
