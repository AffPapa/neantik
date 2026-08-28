import Foundation
import Testing
@testable import NeAntik

struct ProxyHealthTests {
    @Test
    func successKeepsOnlyCoarsePersistableObservation() throws {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = ProxyTestObservation(
            observedAt: observedAt,
            responseTimeMilliseconds: 482,
            result: ProxyTestResult(
                ipAddress: "203.0.113.77",
                city: "Berlin",
                countryName: "Germany",
                countryCode: "DE",
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE"
            )
        )

        let state = ProxyHealthUpdatePolicy.success(observation)
        let encoded = try JSONEncoder().encode(state)
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(state.latestAttempt.outcome == .succeeded)
        #expect(state.latestAttempt.responseTimeMilliseconds == 482)
        #expect(state.lastSuccess?.locationSummary == "Berlin, Germany")
        #expect(state.lastSuccess?.exitAddressWasObserved == true)
        #expect(state.hasCompleteRouteContext)
        #expect(!text.contains("203.0.113.77"))
        #expect(!text.localizedCaseInsensitiveContains("password"))
        #expect(!text.localizedCaseInsensitiveContains("username"))
    }

    @Test
    func reachableProxyWithoutTimezoneIsNotPresentedAsReady() {
        let state = ProxyHealthUpdatePolicy.success(
            ProxyTestObservation(
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                responseTimeMilliseconds: 80,
                result: ProxyTestResult(
                    ipAddress: "203.0.113.8",
                    city: nil,
                    countryName: "Germany",
                    countryCode: "DE",
                    timezoneIdentifier: nil,
                    localeIdentifier: "de-DE"
                )
            )
        )

        #expect(state.latestAttempt.outcome == .succeeded)
        #expect(!state.hasCompleteRouteContext)
    }

    @Test
    func failureRetainsLastSuccessWithoutInventingLatency() {
        let success = ProxyHealthUpdatePolicy.success(
            ProxyTestObservation(
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                responseTimeMilliseconds: 200,
                result: ProxyTestResult(
                    ipAddress: "2001:db8::1",
                    city: nil,
                    countryName: "Germany",
                    countryCode: "DE",
                    timezoneIdentifier: "Europe/Berlin",
                    localeIdentifier: "de-DE"
                )
            )
        )
        let failedAt = Date(timeIntervalSince1970: 1_800_000_100)

        let result = ProxyHealthUpdatePolicy.failure(
            ProxyProbeError(outcome: .timedOut),
            checkedAt: failedAt,
            previous: success
        )

        #expect(result.latestAttempt.checkedAt == failedAt)
        #expect(result.latestAttempt.outcome == .timedOut)
        #expect(result.latestAttempt.responseTimeMilliseconds == nil)
        #expect(result.lastSuccess == success.lastSuccess)
    }

    @Test
    func cancellationDoesNotOverwriteCompletedState() {
        let previous = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
                outcome: .connectionFailed
            ),
            lastSuccess: nil
        )

        let result = ProxyHealthUpdatePolicy.applying(
            .failure(CancellationError()),
            checkedAt: Date(timeIntervalSince1970: 1_800_000_100),
            previous: previous
        )

        #expect(result == previous)
    }

    @Test
    func responseTimeIsBoundedBeforePersistence() {
        #expect(
            ProxyHealthAttempt(
                checkedAt: Date(),
                outcome: .succeeded,
                responseTimeMilliseconds: -1
            ).responseTimeMilliseconds == nil
        )
        #expect(
            ProxyHealthAttempt(
                checkedAt: Date(),
                outcome: .succeeded,
                responseTimeMilliseconds: 120_001
            ).responseTimeMilliseconds == nil
        )
    }

    @Test
    func privateStoreRoundTripsAndUsesOwnerOnlyPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-proxy-health-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let profileID = UUID()
        let state = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
                outcome: .authenticationRejected
            ),
            lastSuccess: nil
        )
        let store = try ProxyHealthStore(fileURL: fileURL)

        try await store.set(state, for: profileID)
        let reloaded = try ProxyHealthStore(fileURL: fileURL)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )

        #expect(await reloaded.state(for: profileID) == state)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func storeRejectsSymbolicLinkTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-proxy-health-link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = root.appendingPathComponent("proxy-health.json")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        #expect(throws: ProxyHealthStoreError.unsafePath) {
            _ = try ProxyHealthStore(fileURL: link)
        }
    }

    @Test
    func encodedCapacityFailurePreservesPreviousReadableFile() async throws {
        let root = Self.temporaryRoot("encoded-capacity")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let seedID = UUID()
        let seedState = Self.healthState(timestamp: 1_800_000_050)
        let seedStore = try ProxyHealthStore(fileURL: fileURL)
        try await seedStore.set(seedState, for: seedID)
        let previousData = try Data(contentsOf: fileURL)

        let observedAt = Date(timeIntervalSince1970: 1_800_001_000)
        let text = String(repeating: "x", count: 128)
        let largeState = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: observedAt,
                outcome: .succeeded,
                responseTimeMilliseconds: 100
            ),
            lastSuccess: ProxyHealthSuccess(
                observedAt: observedAt,
                responseTimeMilliseconds: 100,
                exitAddressWasObserved: true,
                city: text,
                countryName: text,
                countryCode: text,
                timezoneIdentifier: text,
                localeIdentifier: text
            )
        )
        let oversized = Dictionary(
            uniqueKeysWithValues: (0..<7_000).map { _ in
                (UUID().uuidString, largeState)
            }
        )

        #expect(throws: ProxyHealthStoreError.capacityExceeded) {
            try ProxyHealthStore.persist(oversized, to: fileURL)
        }

        #expect(try Data(contentsOf: fileURL) == previousData)
        let reloaded = try ProxyHealthStore(fileURL: fileURL)
        #expect(await reloaded.state(for: seedID) == seedState)
    }

    @Test
    func twoIndependentStoresMergeWritesWithoutLostUpdates() async throws {
        let root = Self.temporaryRoot("merge")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let firstRepository = try ProxyHealthRepository(fileURL: fileURL)
        let secondRepository = try ProxyHealthRepository(fileURL: fileURL)
        let firstProfileID = UUID()
        let secondProfileID = UUID()
        let firstIdentity = Self.identity(host: "first.example", revision: 4)
        let secondIdentity = Self.identity(host: "second.example", revision: 8)
        let firstState = Self.healthState(timestamp: 1_800_000_100)
        let secondState = Self.healthState(timestamp: 1_800_000_200)

        try await firstRepository.set(
            firstState,
            for: firstProfileID,
            identity: firstIdentity
        )
        try await secondRepository.set(
            secondState,
            for: secondProfileID,
            identity: secondIdentity
        )

        let reloaded = try ProxyHealthRepository(fileURL: fileURL)
        #expect(
            await reloaded.state(
                for: firstProfileID,
                identity: firstIdentity
            ) == firstState
        )
        #expect(
            await reloaded.state(
                for: secondProfileID,
                identity: secondIdentity
            ) == secondState
        )
    }

    @Test
    func pruneReloadsUnderLockAndPreservesIndependentNewerWrites() async throws {
        let root = Self.temporaryRoot("prune-merge")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let staleRepository = try ProxyHealthRepository(fileURL: fileURL)
        let writer = try ProxyHealthRepository(fileURL: fileURL)
        let firstID = UUID()
        let secondID = UUID()
        let deletedID = UUID()
        let firstIdentity = Self.identity(host: "first.example", revision: 1)
        let secondIdentity = Self.identity(host: "second.example", revision: 2)
        let deletedIdentity = Self.identity(host: "deleted.example", revision: 3)
        let firstState = Self.healthState(timestamp: 1_800_000_210)
        let secondState = Self.healthState(timestamp: 1_800_000_220)
        let deletedState = Self.healthState(timestamp: 1_800_000_230)

        try await writer.set(
            firstState,
            for: firstID,
            identity: firstIdentity
        )
        try await writer.set(
            secondState,
            for: secondID,
            identity: secondIdentity
        )
        try await writer.set(
            deletedState,
            for: deletedID,
            identity: deletedIdentity
        )

        let retained = try await staleRepository.records(matching: [
            firstID: firstIdentity,
            secondID: secondIdentity,
        ])

        #expect(retained[firstID]?.state == firstState)
        #expect(retained[secondID]?.state == secondState)
        #expect(retained[deletedID] == nil)
        let reloaded = try ProxyHealthStore(fileURL: fileURL)
        let durable = await reloaded.allRecords()
        #expect(durable.count == 2)
        #expect(durable[firstID]?.identity == firstIdentity)
        #expect(durable[secondID]?.identity == secondIdentity)
        #expect(durable[deletedID] == nil)
    }

    @Test
    func changedProxyIdentityRejectsPersistedStaleHealth() async throws {
        let root = Self.temporaryRoot("identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let profileID = UUID()
        let original = Self.identity(host: "old.example", revision: 10)
        let changedProxy = Self.identity(host: "new.example", revision: 11)
        let changedRevision = Self.identity(host: "old.example", revision: 11)
        let state = Self.healthState(timestamp: 1_800_000_300)
        let store = try ProxyHealthStore(fileURL: fileURL)

        try await store.set(state, for: profileID, identity: original)

        #expect(
            await store.state(for: profileID, matching: original) == state
        )
        #expect(
            await store.state(for: profileID, matching: changedProxy) == nil
        )
        #expect(
            await store.state(for: profileID, matching: changedRevision) == nil
        )
    }

    @Test
    func schemaOneLoadsButRequiresFreshIdentityBeforeValidatedRead() async throws {
        let root = Self.temporaryRoot("migration")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let profileID = UUID()
        let state = Self.healthState(timestamp: 1_800_000_400)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedState = try encoder.encode(state)
        let stateObject = try JSONSerialization.jsonObject(with: encodedState)
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "states": [profileID.uuidString: stateObject],
        ])
        try legacyData.write(to: fileURL)

        let store = try ProxyHealthStore(fileURL: fileURL)
        let identity = Self.identity(host: "legacy.example", revision: 1)

        #expect(await store.state(for: profileID) == state)
        #expect(
            await store.state(for: profileID, matching: identity) == nil
        )

        try await store.set(state, for: profileID, identity: identity)
        let migrated = try ProxyHealthStore(fileURL: fileURL)
        #expect(
            await migrated.state(for: profileID, matching: identity) == state
        )
    }

    @Test @MainActor
    func coordinatorPublishesOnlyHealthMatchingCurrentProfileIdentity() async throws {
        let root = Self.temporaryRoot("coordinator")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let profile = BrowserProfile(
            name: "Proxy",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "current.example",
                port: 8_080,
                username: "user"
            ),
            revision: 12
        )
        var profileAfterContextUpdate = profile
        profileAfterContextUpdate.revision += 1
        let state = Self.healthState(timestamp: 1_800_000_500)
        let coordinator = ProxyHealthCoordinator(fileURL: fileURL)
        let currentIdentity = try #require(
            ProxyHealthIdentity(profile: profileAfterContextUpdate)
        )

        let result = try await coordinator.run(
            profile: profile,
            operationWithCurrentIdentity: { _ in
                ProxyHealthTestCommit(
                    state: state,
                    currentIdentity: currentIdentity
                )
            }
        )

        #expect(result == state)
        #expect(coordinator.state(for: profile) == nil)
        #expect(coordinator.state(for: profileAfterContextUpdate) == state)
        #expect(coordinator.healthByProfileID[profile.id]?.state == state)

        profileAfterContextUpdate.proxy?.host = "changed.example"
        profileAfterContextUpdate.revision += 1
        #expect(coordinator.state(for: profileAfterContextUpdate) == nil)

        await coordinator.reload(profiles: [profileAfterContextUpdate])
        #expect(coordinator.healthByProfileID[profile.id] == nil)
        let prunedStore = try ProxyHealthStore(fileURL: fileURL)
        #expect(await prunedStore.allRecords().isEmpty)
    }

    @Test @MainActor
    func coordinatorRejectsCommitReboundToDifferentProxy() async throws {
        let root = Self.temporaryRoot("changed-during-test")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let profile = BrowserProfile(
            name: "Proxy",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "original.example",
                port: 8_080,
                username: "user"
            ),
            revision: 20
        )
        var changed = profile
        changed.proxy?.host = "changed.example"
        changed.revision += 1
        let changedIdentity = try #require(
            ProxyHealthIdentity(profile: changed)
        )
        let state = Self.healthState(timestamp: 1_800_000_600)
        let coordinator = ProxyHealthCoordinator(fileURL: fileURL)

        let result = try await coordinator.run(
            profile: profile,
            operationWithCurrentIdentity: { _ in
                ProxyHealthTestCommit(
                    state: state,
                    currentIdentity: changedIdentity
                )
            }
        )

        #expect(result == nil)
        #expect(coordinator.healthByProfileID[profile.id] == nil)
        let reloaded = try ProxyHealthStore(fileURL: fileURL)
        #expect(
            await reloaded.state(
                for: profile.id,
                matching: changedIdentity
            ) == nil
        )
    }

    @Test @MainActor
    func coordinatorPublishesOneAppWideInFlightClaim() async throws {
        let root = Self.temporaryRoot("app-wide-in-flight")
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = ProxyHealthCommitBoundaryBarrier()
        let profile = BrowserProfile(
            name: "Proxy",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "current.example",
                port: 8_080,
                username: "user"
            )
        )
        let state = Self.healthState(timestamp: 1_800_000_650)
        let coordinator = ProxyHealthCoordinator(
            fileURL: root.appendingPathComponent("proxy-health.json"),
            executionGate: ProxyTestExecutionGate(),
            commitBoundaryHook: {
                await barrier.suspendAtBoundary()
            }
        )
        let first = Task { @MainActor in
            try await coordinator.run(profile: profile) { _ in state }
        }

        await barrier.waitUntilReached()
        #expect(coordinator.isTesting(profileID: profile.id))
        let duplicate = try await coordinator.run(
            profile: profile
        ) { _ in state }
        #expect(duplicate == nil)
        #expect(coordinator.isTesting(profileID: profile.id))

        await barrier.resume()
        #expect(try await first.value == state)
        #expect(!coordinator.isTesting(profileID: profile.id))
    }

    @Test @MainActor
    func cancellationAtCommitBoundaryRemovesNewRecordAndDoesNotPublish() async throws {
        let root = Self.temporaryRoot("cancel-empty-receipt")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let barrier = ProxyHealthCommitBoundaryBarrier()
        let profile = BrowserProfile(
            name: "Proxy",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "current.example",
                port: 8_080,
                username: "user"
            ),
            revision: 30
        )
        let identity = try #require(ProxyHealthIdentity(profile: profile))
        let state = Self.healthState(timestamp: 1_800_000_700.123_456)
        let coordinator = ProxyHealthCoordinator(
            fileURL: fileURL,
            executionGate: ProxyTestExecutionGate(),
            commitBoundaryHook: {
                await barrier.suspendAtBoundary()
            }
        )
        let task = Task { @MainActor in
            try await coordinator.run(profile: profile) { _ in state }
        }

        await barrier.waitUntilReached()
        let written = try ProxyHealthStore(fileURL: fileURL)
        #expect(
            await written.state(for: profile.id, matching: identity) != nil
        )

        task.cancel()
        await barrier.resume()
        await expectProxyHealthCancellation(task)

        let reloaded = try ProxyHealthStore(fileURL: fileURL)
        #expect(await reloaded.state(for: profile.id) == nil)
        #expect(coordinator.healthByProfileID[profile.id] == nil)
    }

    @Test @MainActor
    func cancellationAtCommitBoundaryRestoresExactPreviousIdentityRecord() async throws {
        let root = Self.temporaryRoot("cancel-exact-receipt")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let profileID = UUID()
        let previousIdentity = Self.identity(
            host: "previous.example",
            revision: 7
        )
        let previousState = Self.healthState(timestamp: 1_800_000_710.234_567)
        let seedStore = try ProxyHealthStore(fileURL: fileURL)
        try await seedStore.set(
            previousState,
            for: profileID,
            identity: previousIdentity
        )
        let persistedSeedStore = try ProxyHealthStore(fileURL: fileURL)
        let persistedPreviousState = try #require(
            await persistedSeedStore.state(
                for: profileID,
                matching: previousIdentity
            )
        )
        let profile = BrowserProfile(
            id: profileID,
            name: "Proxy",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "current.example",
                port: 8_443,
                username: "user"
            ),
            revision: 40
        )
        let currentState = Self.healthState(timestamp: 1_800_000_720.345_678)
        let barrier = ProxyHealthCommitBoundaryBarrier()
        let coordinator = ProxyHealthCoordinator(
            fileURL: fileURL,
            executionGate: ProxyTestExecutionGate(),
            commitBoundaryHook: {
                await barrier.suspendAtBoundary()
            }
        )
        let task = Task { @MainActor in
            try await coordinator.run(profile: profile) { _ in currentState }
        }

        await barrier.waitUntilReached()
        task.cancel()
        await barrier.resume()
        await expectProxyHealthCancellation(task)

        let reloaded = try ProxyHealthStore(fileURL: fileURL)
        #expect(
            await reloaded.state(
                for: profileID,
                matching: previousIdentity
            ) == persistedPreviousState
        )
        #expect(coordinator.healthByProfileID[profileID] == nil)
    }

    @Test
    func cancellationRestoreDoesNotOverwriteNewerIndependentStoreWrite() async throws {
        let root = Self.temporaryRoot("cancel-cas")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("proxy-health.json")
        let profileID = UUID()
        let firstStore = try ProxyHealthStore(fileURL: fileURL)
        let secondStore = try ProxyHealthStore(fileURL: fileURL)
        let cancelledRecord = ProxyHealthRecord(
            identity: Self.identity(host: "cancelled.example", revision: 1),
            state: Self.healthState(timestamp: 1_800_000_730.456_789)
        )
        let newerIdentity = Self.identity(host: "newer.example", revision: 2)
        let newerState = Self.healthState(timestamp: 1_800_000_740)

        let replacement = try await firstStore.replaceRecord(
            cancelledRecord,
            for: profileID
        )
        try await secondStore.set(
            newerState,
            for: profileID,
            identity: newerIdentity
        )
        let persistedCancelledRecord = try #require(
            replacement.persistedRecord
        )
        let restored = try await firstStore.restoreRecord(
            replacement.previousRecord,
            replacing: persistedCancelledRecord,
            for: profileID
        )

        #expect(!restored)
        let reloaded = try ProxyHealthStore(fileURL: fileURL)
        #expect(
            await reloaded.state(
                for: profileID,
                matching: newerIdentity
            ) == newerState
        )
    }

    private static func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-proxy-health-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private static func identity(
        host: String,
        revision: UInt64
    ) -> ProxyHealthIdentity {
        ProxyHealthIdentity(
            proxy: ProxyConfiguration(
                kind: .http,
                host: host,
                port: 8_080,
                username: "user"
            ),
            profileRevision: revision
        )
    }

    private static func healthState(timestamp: TimeInterval) -> ProxyHealthState {
        ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: Date(timeIntervalSince1970: timestamp),
                outcome: .connectionFailed
            ),
            lastSuccess: nil
        )
    }
}

private actor ProxyHealthCommitBoundaryBarrier {
    private var reached = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendAtBoundary() async {
        reached = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private func expectProxyHealthCancellation(
    _ task: Task<ProxyHealthState?, Error>
) async {
    switch await task.result {
    case .success:
        Issue.record("Expected proxy-health task cancellation")
    case let .failure(error):
        #expect(error is CancellationError)
    }
}
