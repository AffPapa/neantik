import Darwin
import Foundation

/// Opt-in QA breadcrumbs for an MCP proxy check. The closed vocabulary cannot
/// contain a profile identifier, endpoint, credential, or raw error.
enum ProxyAuditPhase: String, CaseIterable {
    case engineInitBegin = "engine_init_begin"
    case engineInitDone = "engine_init_done"
    case metadataInitialBegin = "metadata_initial_begin"
    case metadataInitialDone = "metadata_initial_done"
    case stoppedVerifyBegin = "stopped_verify_begin"
    case stoppedVerifyDone = "stopped_verify_done"
    case healthRunBegin = "health_run_begin"
    case healthRunDone = "health_run_done"
    case credentialInitialBegin = "credential_initial_begin"
    case credentialInitialDone = "credential_initial_done"
    case networkProbeBegin = "network_probe_begin"
    case networkProbeDone = "network_probe_done"
    case metadataRevalidateBegin = "metadata_revalidate_begin"
    case metadataRevalidateDone = "metadata_revalidate_done"
    case credentialRevalidateBegin = "credential_revalidate_begin"
    case credentialRevalidateDone = "credential_revalidate_done"
    case responseBegin = "response_begin"
    case responseDone = "response_done"

    static let enabled = ProcessInfo.processInfo.environment["NEANTIK_MCP_QA_PHASES"] == "1"

    var frame: String { "NEANTIK_MCP_QA phase=\(rawValue)\n" }

    static func mark(_ phase: Self) {
        guard enabled else { return }
        phase.frame.withCString { pointer in
            _ = Darwin.write(STDERR_FILENO, pointer, strlen(pointer))
        }
    }
}

/// Shared GUI/MCP route observation commit. Manual checks never rewrite context.
@MainActor
struct ProfileProxyOperations {
    let store: ProfileStore
    let keychain: KeychainStore
    let invalidateObservation: (UUID) -> Void
    var probe: (ProxyConfiguration, String) async throws -> ProxyTestObservation = { configuration, password in
        try await ProxyTester().probe(configuration: configuration, password: password)
    }
    var refreshMetadata: (ProfileStore) async throws -> Void = { store in
        try await store.refreshExternalMetadata(force: true)
    }

    func commit(profileID: UUID, expectedProxy: ProxyConfiguration, expectedRevision: UInt64,
                previous: ProxyHealthState?, commitsLaunchContext: Bool) async throws -> ProxyHealthTestCommit {
        var didCommitContext = false
        let checkedAt = Date()
        let next: ProxyHealthState
        ProxyAuditPhase.mark(.credentialInitialBegin)
        let password = expectedProxy.username.isEmpty ? "" :
            (try keychain.proxyPasswordWithoutMigration(profileID: profileID) ?? "")
        ProxyAuditPhase.mark(.credentialInitialDone)
        do {
            ProxyAuditPhase.mark(.networkProbeBegin)
            let observation = try await probe(expectedProxy, password)
            ProxyAuditPhase.mark(.networkProbeDone)
            try Task.checkCancellation()
            ProxyAuditPhase.mark(.metadataRevalidateBegin)
            try await refreshMetadata(store)
            ProxyAuditPhase.mark(.metadataRevalidateDone)
            // Refresh can suspend while cancellation or a credential edit is
            // delivered. No context is durable yet: recheck both before writing.
            try Task.checkCancellation()
            ProxyAuditPhase.mark(.credentialRevalidateBegin)
            let currentPassword = expectedProxy.username.isEmpty ? "" :
                (try keychain.proxyPasswordWithoutMigration(profileID: profileID) ?? "")
            try Task.checkCancellation()
            ProxyAuditPhase.mark(.credentialRevalidateDone)
            guard let currentProfile = store.profile(withID: profileID),
                  ProxyTestCommitPolicy.matchesSnapshot(
                      expectedProxy: expectedProxy,
                      currentProxy: currentProfile.proxy,
                      expectedRevision: expectedRevision,
                      currentRevision: currentProfile.revision,
                      credentialsMatch: currentPassword == password
                  )
            else {
                throw CancellationError()
            }
            if commitsLaunchContext {
                var prepared = currentProfile
                prepared.identity = prepared.identity.replacingProxyContext(
                    timezoneIdentifier: observation.result.timezoneIdentifier,
                    localeIdentifier: observation.result.localeIdentifier,
                    evidence: .from(observation.source, observedAt: observation.observedAt))
                _ = try store.upsert(prepared)
                didCommitContext = true
                invalidateObservation(profileID)
            }
            // Manual checks record observations only. The launch preparation
            // owns route-derived profile context. Keeping this operation in one
            // health file makes cancellation rollback complete and predictable.
            next = ProxyHealthUpdatePolicy.success(observation)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProxyProbeError {
            ProxyAuditPhase.mark(.metadataRevalidateBegin)
            try await refreshMetadata(store)
            ProxyAuditPhase.mark(.metadataRevalidateDone)
            try Task.checkCancellation()
            ProxyAuditPhase.mark(.credentialRevalidateBegin)
            let currentPassword = expectedProxy.username.isEmpty ? "" :
                (try keychain.proxyPasswordWithoutMigration(profileID: profileID) ?? "")
            try Task.checkCancellation()
            ProxyAuditPhase.mark(.credentialRevalidateDone)
            guard let currentProfile = store.profile(withID: profileID),
                  ProxyTestCommitPolicy.matchesSnapshot(
                      expectedProxy: expectedProxy,
                      currentProxy: currentProfile.proxy,
                      expectedRevision: expectedRevision,
                      currentRevision: currentProfile.revision,
                      credentialsMatch: currentPassword == password
                  )
            else {
                throw CancellationError()
            }
            next = ProxyHealthUpdatePolicy.failure(
                error,
                checkedAt: checkedAt,
                previous: previous
            )
        } catch {
            throw error
        }

        guard let currentProfile = store.profile(withID: profileID),
              currentProfile.proxy == expectedProxy,
              let currentIdentity = ProxyHealthIdentity(
                  profile: currentProfile
              )
        else {
            throw CancellationError()
        }
        return ProxyHealthTestCommit(
            state: next,
            currentIdentity: currentIdentity,
            hasDurableProfileCommit: didCommitContext
        )
    }

}
