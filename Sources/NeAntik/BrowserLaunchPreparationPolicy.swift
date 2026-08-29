import Foundation

/// Decides whether Start can use the profile immediately or must first
/// refresh the proxy-derived route context.
///
/// The policy deliberately requires the persisted profile evidence and the
/// identity-bound health record to describe the same successful observation.
/// A retained older success after a newer failure is never launch-ready.
enum BrowserLaunchPreparationDecision: Equatable, Sendable {
    case launchImmediately
    case prepareProxyContext
}

enum BrowserLaunchPreparationPolicy {
    /// A manually completed check can feed an immediate launch, but a route
    /// observation is never reused for a later browser session.
    static let maximumTrustedProxyObservationAge: TimeInterval = 30

    /// The visible Start action never reuses a manual proxy check. Direct
    /// profiles need no network work; every proxied browser session gets a
    /// fresh automatic observation immediately before process launch.
    static func resolveForUserStart(
        profile: BrowserProfile
    ) -> BrowserLaunchPreparationDecision {
        profile.proxy == nil ? .launchImmediately : .prepareProxyContext
    }

    static func resolve(
        profile: BrowserProfile,
        proxyHealth: ProxyHealthState?,
        now: Date = Date()
    ) -> BrowserLaunchPreparationDecision {
        guard profile.proxy != nil else {
            return .launchImmediately
        }
        guard let evidence = profile.identity.proxyContextEvidence,
              evidence.isFresh(relativeTo: now),
              let proxyHealth,
              proxyHealth.latestAttempt.outcome == .succeeded,
              let success = proxyHealth.lastSuccess,
              success.observedAt == evidence.observedAt,
              success.exitAddressWasObserved,
              success.timezoneIdentifier != nil,
              success.localeIdentifier != nil,
              profile.identity.timezoneIdentifier ==
                success.timezoneIdentifier,
              profile.identity.localeIdentifier == success.localeIdentifier
        else {
            return .prepareProxyContext
        }
        let observationAge = now.timeIntervalSince(success.observedAt)
        let observationIsNewerThanLastLaunch =
            profile.lastLaunchedAt.map {
                success.observedAt > $0
            } ?? true
        guard observationAge >= -5 * 60,
              observationAge <= maximumTrustedProxyObservationAge,
              observationIsNewerThanLastLaunch
        else {
            return .prepareProxyContext
        }
        return .launchImmediately
    }

    static func receipt(
        profile: BrowserProfile,
        proxyHealth: ProxyHealthState?,
        now: Date = Date()
    ) -> BrowserLaunchPreparationReceipt? {
        guard let proxy = profile.proxy,
              resolve(
                  profile: profile,
                  proxyHealth: proxyHealth,
                  now: now
              ) == .launchImmediately,
              let observedAt = proxyHealth?.lastSuccess?.observedAt
        else {
            return nil
        }
        return BrowserLaunchPreparationReceipt(
            profileID: profile.id,
            profileRevision: profile.revision,
            proxy: proxy,
            evidenceObservedAt: observedAt,
            issuedAt: now
        )
    }
}

/// Short-lived capability required at the normal process-launch boundary for
/// a proxy-bound profile. Future API/MCP/SDK adapters cannot bypass the same
/// preparation gate by calling the process manager directly.
struct BrowserLaunchPreparationReceipt: Equatable, Sendable {
    static let maximumAge: TimeInterval = 30

    let profileID: UUID
    let profileRevision: UInt64
    let proxy: ProxyConfiguration
    let evidenceObservedAt: Date
    let issuedAt: Date

    fileprivate init(
        profileID: UUID,
        profileRevision: UInt64,
        proxy: ProxyConfiguration,
        evidenceObservedAt: Date,
        issuedAt: Date
    ) {
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.proxy = proxy
        self.evidenceObservedAt = evidenceObservedAt
        self.issuedAt = issuedAt
    }

    var consumptionKey: BrowserLaunchPreparationConsumptionKey {
        BrowserLaunchPreparationConsumptionKey(
            profileID: profileID,
            profileRevision: profileRevision,
            evidenceObservedAt: evidenceObservedAt
        )
    }

    func authorizes(
        _ profile: BrowserProfile,
        now: Date = Date()
    ) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        let evidenceAge = now.timeIntervalSince(evidenceObservedAt)
        let observationIsNewerThanLastLaunch =
            profile.lastLaunchedAt.map { evidenceObservedAt > $0 } ?? true
        return age >= -5 * 60 &&
            age <= Self.maximumAge &&
            evidenceAge >= -5 * 60 &&
            evidenceAge <=
                BrowserLaunchPreparationPolicy
                    .maximumTrustedProxyObservationAge &&
            observationIsNewerThanLastLaunch &&
            profile.id == profileID &&
            profile.revision == profileRevision &&
            profile.proxy == proxy &&
            profile.identity.proxyContextEvidence?.observedAt ==
                evidenceObservedAt
    }
}

struct BrowserLaunchPreparationConsumptionKey: Hashable, Sendable {
    let profileID: UUID
    let profileRevision: UInt64
    let evidenceObservedAt: Date
}
