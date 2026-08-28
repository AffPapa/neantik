import Combine
import Foundation

/// Durable identity-aware access to proxy health records.
actor ProxyHealthRepository {
    private let store: ProxyHealthStore

    init(fileURL: URL) throws {
        store = try ProxyHealthStore(fileURL: fileURL)
    }

    func state(
        for profileID: UUID,
        identity: ProxyHealthIdentity
    ) async -> ProxyHealthState? {
        await store.state(for: profileID, matching: identity)
    }

    func records(
        matching identities: [UUID: ProxyHealthIdentity]
    ) async throws -> [UUID: ProxyHealthRecord] {
        try await store.prune(retaining: identities)
    }

    func set(
        _ state: ProxyHealthState,
        for profileID: UUID,
        identity: ProxyHealthIdentity
    ) async throws {
        try await store.set(
            state,
            for: profileID,
            identity: identity
        )
    }

    func replace(
        _ record: ProxyHealthRecord,
        for profileID: UUID
    ) async throws -> ProxyHealthRecordReplacement {
        try await store.replaceRecord(record, for: profileID)
    }

    @discardableResult
    func restore(
        _ previousRecord: ProxyHealthRecord?,
        replacing expectedRecord: ProxyHealthRecord,
        for profileID: UUID
    ) async throws -> Bool {
        try await store.restoreRecord(
            previousRecord,
            replacing: expectedRecord,
            for: profileID
        )
    }

    func remove(profileID: UUID) async throws {
        try await store.set(nil, for: profileID)
    }
}

struct ProxyHealthTestCommit: Equatable, Sendable {
    let state: ProxyHealthState
    let currentIdentity: ProxyHealthIdentity

    init(
        state: ProxyHealthState,
        currentIdentity: ProxyHealthIdentity
    ) {
        self.state = state
        self.currentIdentity = currentIdentity
    }
}

private struct ProxyHealthPersistenceReceipt: Sendable {
    let previousRecord: ProxyHealthRecord?
    let writtenRecord: ProxyHealthRecord
}

private enum ProxyHealthTestExecutionResult: Sendable {
    case stale
    case committed(
        ProxyHealthTestCommit,
        receipt: ProxyHealthPersistenceReceipt
    )
}

struct ProxyHealthCancellationRollbackError: LocalizedError, Sendable {
    let rollbackDescription: String

    var errorDescription: String? {
        "Проверка прокси отменена, но предыдущее состояние не удалось " +
            "восстановить: \(rollbackDescription)"
    }
}

/// One app-scoped observable proxy-health state for every SwiftUI surface.
///
/// Callers must pass the current profile whenever they read or run a test.
/// Published records retain their producing identity, so an old result remains
/// unobservable as soon as the proxy configuration or profile revision changes.
@MainActor
final class ProxyHealthCoordinator: ObservableObject {
    @Published private(set) var healthByProfileID:
        [UUID: ProxyHealthRecord] = [:]
    @Published private(set) var testingProfileIDs: Set<UUID> = []
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private var repository: ProxyHealthRepository?
    private let executionGate: ProxyTestExecutionGate
    private let commitBoundaryHook: @Sendable () async -> Void

    init(
        fileURL: URL,
        executionGate: ProxyTestExecutionGate = .appShared,
        commitBoundaryHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.fileURL = fileURL
        self.executionGate = executionGate
        self.commitBoundaryHook = commitBoundaryHook
    }

    func reload(profiles: [BrowserProfile]) async {
        let repository: ProxyHealthRepository
        do {
            repository = try resolvedRepository()
        } catch {
            healthByProfileID = [:]
            lastError = error.localizedDescription
            return
        }
        let identities = Dictionary(
            uniqueKeysWithValues: profiles.compactMap { profile in
                ProxyHealthIdentity(profile: profile).map {
                    (profile.id, $0)
                }
            }
        )
        do {
            healthByProfileID = try await repository.records(
                matching: identities
            )
            lastError = nil
        } catch {
            healthByProfileID = [:]
            lastError = error.localizedDescription
        }
    }

    func state(for profile: BrowserProfile) -> ProxyHealthState? {
        guard let identity = ProxyHealthIdentity(profile: profile),
              let record = healthByProfileID[profile.id],
              record.identity == identity
        else {
            return nil
        }
        return record.state
    }

    func isTesting(profileID: UUID) -> Bool {
        testingProfileIDs.contains(profileID)
    }

    /// Runs one identity-bound test operation, or returns `nil` when the same
    /// profile already owns an active or queued claim.
    func run(
        profile: BrowserProfile,
        operation: @escaping @MainActor @Sendable (ProxyHealthState?) async throws ->
            ProxyHealthState
    ) async throws -> ProxyHealthState? {
        guard let initialIdentity = ProxyHealthIdentity(profile: profile) else {
            healthByProfileID[profile.id] = nil
            return nil
        }
        return try await run(
            profileID: profile.id,
            initialIdentity: initialIdentity
        ) { previous in
            ProxyHealthTestCommit(
                state: try await operation(previous),
                currentIdentity: initialIdentity
            )
        }
    }

    /// Variant for operations that persist profile-derived proxy context and
    /// therefore advance the profile revision before health is committed.
    func run(
        profile: BrowserProfile,
        operationWithCurrentIdentity operation:
            @escaping @MainActor @Sendable (ProxyHealthState?) async throws ->
                ProxyHealthTestCommit
    ) async throws -> ProxyHealthState? {
        guard let initialIdentity = ProxyHealthIdentity(profile: profile) else {
            healthByProfileID[profile.id] = nil
            return nil
        }
        return try await run(
            profileID: profile.id,
            initialIdentity: initialIdentity,
            operation: operation
        )
    }

    private func run(
        profileID: UUID,
        initialIdentity: ProxyHealthIdentity,
        operation: @escaping @MainActor @Sendable (ProxyHealthState?) async throws ->
            ProxyHealthTestCommit
    ) async throws -> ProxyHealthState? {
        guard !testingProfileIDs.contains(profileID) else { return nil }
        testingProfileIDs.insert(profileID)
        defer { testingProfileIDs.remove(profileID) }
        let repository = try resolvedRepository()
        let commitBoundaryHook = self.commitBoundaryHook
        let executionResult = try await executionGate.run(
            profileID: profileID
        ) {
            let previous = await repository.state(
                for: profileID,
                identity: initialIdentity
            )
            let commit = try await operation(previous)
            try Task.checkCancellation()
            guard commit.currentIdentity.proxy == initialIdentity.proxy else {
                return ProxyHealthTestExecutionResult.stale
            }
            let writtenRecord = ProxyHealthRecord(
                identity: commit.currentIdentity,
                state: commit.state
            )
            let replacement = try await repository.replace(
                writtenRecord,
                for: profileID
            )
            guard let persistedRecord = replacement.persistedRecord else {
                throw ProxyHealthStoreError.unsafePath
            }
            let receipt = ProxyHealthPersistenceReceipt(
                previousRecord: replacement.previousRecord,
                writtenRecord: persistedRecord
            )
            await commitBoundaryHook()
            if Task.isCancelled {
                try await Self.restoreAfterCancellation(
                    receipt,
                    profileID: profileID,
                    repository: repository
                )
                throw CancellationError()
            }
            return ProxyHealthTestExecutionResult.committed(
                commit,
                receipt: receipt
            )
        }
        guard case let .committed(result, receipt)? = executionResult else {
            return nil
        }
        if Task.isCancelled {
            try await Self.restoreAfterCancellation(
                receipt,
                profileID: profileID,
                repository: repository
            )
            throw CancellationError()
        }
        healthByProfileID[profileID] = ProxyHealthRecord(
            identity: result.currentIdentity,
            state: result.state
        )
        lastError = nil
        return result.state
    }

    private nonisolated static func restoreAfterCancellation(
        _ receipt: ProxyHealthPersistenceReceipt,
        profileID: UUID,
        repository: ProxyHealthRepository
    ) async throws {
        do {
            _ = try await repository.restore(
                receipt.previousRecord,
                replacing: receipt.writtenRecord,
                for: profileID
            )
        } catch {
            throw ProxyHealthCancellationRollbackError(
                rollbackDescription: error.localizedDescription
            )
        }
    }

    func remove(profileID: UUID) async throws {
        let repository = try resolvedRepository()
        try await repository.remove(profileID: profileID)
        healthByProfileID[profileID] = nil
        lastError = nil
    }

    private func resolvedRepository() throws -> ProxyHealthRepository {
        if let repository { return repository }
        let created = try ProxyHealthRepository(fileURL: fileURL)
        repository = created
        return created
    }
}
