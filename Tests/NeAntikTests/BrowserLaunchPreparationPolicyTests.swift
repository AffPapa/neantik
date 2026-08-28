import Foundation
import Testing
@testable import NeAntik

struct BrowserLaunchPreparationPolicyTests {
    @Test
    func visibleStartAlwaysPreparesAProxyAndNeverProbesDirect() {
        let direct = BrowserProfile(name: "Direct")
        let proxied = BrowserProfile(
            name: "Proxy",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: ""
            )
        )

        #expect(
            BrowserLaunchPreparationPolicy.resolveForUserStart(
                profile: direct
            ) == .launchImmediately
        )
        #expect(
            BrowserLaunchPreparationPolicy.resolveForUserStart(
                profile: proxied
            ) == .prepareProxyContext
        )
    }

    private let proxy = ProxyConfiguration(
        kind: .https,
        host: "proxy.example",
        port: 443,
        username: ""
    )

    @Test
    func directProfileNeverNeedsAnExternalPreparationProbe() {
        let decision = BrowserLaunchPreparationPolicy.resolve(
            profile: BrowserProfile(name: "Direct"),
            proxyHealth: nil
        )

        #expect(decision == .launchImmediately)
    }

    @Test
    func matchingFreshSuccessfulEvidenceLaunchesImmediately() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = proxiedProfile(evidenceObservedAt: observedAt)
        let health = successfulHealth(observedAt: observedAt)

        let decision = BrowserLaunchPreparationPolicy.resolve(
            profile: profile,
            proxyHealth: health,
            now: observedAt.addingTimeInterval(10)
        )

        #expect(decision == .launchImmediately)
    }

    @Test
    func observationUsedByAPreviousBrowserSessionIsRechecked() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var profile = proxiedProfile(evidenceObservedAt: observedAt)
        profile.lastLaunchedAt = observedAt.addingTimeInterval(1)

        #expect(
            BrowserLaunchPreparationPolicy.resolve(
                profile: profile,
                proxyHealth: successfulHealth(observedAt: observedAt),
                now: observedAt.addingTimeInterval(2)
            ) == .prepareProxyContext
        )
    }

    @Test
    func receiptIsShortLivedAndBoundToTheExactProfileRevision() throws {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var profile = proxiedProfile(evidenceObservedAt: observedAt)
        profile.revision = 12
        let now = observedAt.addingTimeInterval(30)
        let receipt = try #require(
            BrowserLaunchPreparationPolicy.receipt(
                profile: profile,
                proxyHealth: successfulHealth(observedAt: observedAt),
                now: now
            )
        )
        let secondReceipt = try #require(
            BrowserLaunchPreparationPolicy.receipt(
                profile: profile,
                proxyHealth: successfulHealth(observedAt: observedAt),
                now: now
            )
        )

        #expect(receipt.authorizes(profile, now: now))
        #expect(receipt.consumptionKey == secondReceipt.consumptionKey)
        profile.revision += 1
        #expect(!receipt.authorizes(profile, now: now))
        profile.revision -= 1
        #expect(
            !receipt.authorizes(
                profile,
                now: now.addingTimeInterval(
                    BrowserLaunchPreparationReceipt.maximumAge + 1
                )
            )
        )
    }

    @Test(arguments: [
        ProxyPreparationScenario.missingEvidence,
        .missingHealth,
        .staleEvidence,
        .mismatchedObservation,
        .latestAttemptFailed,
        .missingDerivedTimezone,
        .profileContextMismatch
    ])
    func incompleteOrUnsafeProxyEvidenceRequiresPreparation(
        scenario: ProxyPreparationScenario
    ) {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var profile = proxiedProfile(evidenceObservedAt: observedAt)
        var health: ProxyHealthState? = successfulHealth(
            observedAt: observedAt
        )
        var now = observedAt.addingTimeInterval(60)

        switch scenario {
        case .missingEvidence:
            profile.identity = BrowserIdentity(seed: profile.identity.seed)
        case .missingHealth:
            health = nil
        case .staleEvidence:
            now = observedAt.addingTimeInterval(
                BrowserLaunchPreparationPolicy
                    .maximumTrustedProxyObservationAge + 1
            )
        case .mismatchedObservation:
            health = successfulHealth(
                observedAt: observedAt.addingTimeInterval(1)
            )
        case .latestAttemptFailed:
            health = ProxyHealthState(
                latestAttempt: ProxyHealthAttempt(
                    checkedAt: observedAt.addingTimeInterval(10),
                    outcome: .timedOut
                ),
                lastSuccess: health?.lastSuccess
            )
        case .missingDerivedTimezone:
            health = successfulHealth(
                observedAt: observedAt,
                timezoneIdentifier: nil
            )
        case .profileContextMismatch:
            profile.identity = profile.identity.replacingProxyContext(
                timezoneIdentifier: "Asia/Tokyo",
                localeIdentifier: "ja-JP",
                evidence: .ipAPI(observedAt: observedAt)
            )
        }

        #expect(
            BrowserLaunchPreparationPolicy.resolve(
                profile: profile,
                proxyHealth: health,
                now: now
            ) == .prepareProxyContext
        )
    }

    private func proxiedProfile(
        evidenceObservedAt: Date
    ) -> BrowserProfile {
        BrowserProfile(
            name: "Proxy",
            proxy: proxy,
            identity: BrowserIdentity(
                seed: 123,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE",
                proxyContextEvidence: .ipAPI(
                    observedAt: evidenceObservedAt
                )
            )
        )
    }

    private func successfulHealth(
        observedAt: Date,
        timezoneIdentifier: String? = "Europe/Berlin"
    ) -> ProxyHealthState {
        ProxyHealthUpdatePolicy.success(
            ProxyTestObservation(
                observedAt: observedAt,
                responseTimeMilliseconds: 84,
                result: ProxyTestResult(
                    ipAddress: "203.0.113.7",
                    city: "Berlin",
                    countryName: "Germany",
                    countryCode: "DE",
                    timezoneIdentifier: timezoneIdentifier,
                    localeIdentifier: "de-DE"
                )
            )
        )
    }
}

enum ProxyPreparationScenario: CaseIterable, Sendable {
    case missingEvidence
    case missingHealth
    case staleEvidence
    case mismatchedObservation
    case latestAttemptFailed
    case missingDerivedTimezone
    case profileContextMismatch
}
