import Foundation

/// Shared GUI/MCP route observation commit. Manual checks never rewrite context.
@MainActor
struct ProfileProxyOperations {
    let store: ProfileStore
    let keychain: KeychainStore
    let invalidateObservation: (UUID) -> Void

    func commit(profileID: UUID, expectedProxy: ProxyConfiguration, expectedRevision: UInt64,
                previous: ProxyHealthState?, commitsLaunchContext: Bool) async throws -> ProxyHealthTestCommit {
        var didCommitContext = false
        let checkedAt = Date()
        let next: ProxyHealthState
        let password = try keychain.proxyPassword(
            profileID: profileID
        ) ?? ""
        do {
            let observation = try await ProxyTester().probe(
                configuration: expectedProxy,
                password: password
            )
            try Task.checkCancellation()
            let currentPassword = try keychain.proxyPassword(
                profileID: profileID
            ) ?? ""
            try await store.refreshExternalMetadata(force: true)
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
            let currentPassword = try keychain.proxyPassword(
                profileID: profileID
            ) ?? ""
            try await store.refreshExternalMetadata(force: true)
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
