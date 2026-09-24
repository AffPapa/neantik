import Foundation
import Testing
@testable import NeAntik

struct ProxyCheckSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var identity: ProxyHealthIdentity {
        ProxyHealthIdentity(
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: "user"
            ),
            profileRevision: 7
        )
    }

    @Test
    func distinguishesNeverCheckedFreshAndStale() {
        #expect(summary(record: nil).status == .neverChecked)
        #expect(summary(record: record(at: now.addingTimeInterval(-60))).status == .currentSuccess)
        #expect(summary(record: record(at: now.addingTimeInterval(-901))).status == .staleSuccess)
    }

    @Test
    func latestFailureDoesNotLookFreshDespiteAnOlderSuccess() {
        let successDate = now.addingTimeInterval(-30_000)
        let failedAttempt = ProxyHealthAttempt(
            checkedAt: now.addingTimeInterval(-30),
            outcome: .timedOut
        )
        let state = ProxyHealthState(
            latestAttempt: failedAttempt,
            lastSuccess: ProxyHealthSuccess(
                observedAt: successDate,
                responseTimeMilliseconds: 300,
                exitAddressWasObserved: true,
                city: "Secret City",
                countryName: "Secret Country",
                countryCode: "SC",
                timezoneIdentifier: "Secret/Zone",
                localeIdentifier: "xx-XX"
            )
        )
        let projected = summary(record: ProxyHealthRecord(identity: identity, state: state))

        #expect(projected.status == .latestCheckFailed)
        #expect(projected.lastSuccessfulCheckAt == successDate)
        #expect(!projected.title.contains("Secret"))
        #expect(!String(describing: projected).contains("proxy.example"))
    }

    @Test
    func marksLargeFutureTimestampAndChangedIdentityAsUnknown() {
        #expect(summary(record: record(at: now.addingTimeInterval(301))).status == .clockUncertain)
        #expect(summary(record: record(at: now), currentIdentity: ProxyHealthIdentity(
            proxy: identity.proxy,
            profileRevision: 8
        )).status == .configurationChanged)
    }

    @Test
    func toleratesSmallClockSkewWithoutShowingTheResultAsStale() {
        #expect(summary(record: record(at: now.addingTimeInterval(120))).status == .currentSuccess)
    }

    private func summary(
        record: ProxyHealthRecord?,
        currentIdentity: ProxyHealthIdentity? = nil
    ) -> ProxyCheckSummary {
        ProxyCheckSummary(
            record: record,
            currentIdentity: currentIdentity ?? identity,
            now: now
        )
    }

    private func record(at checkedAt: Date) -> ProxyHealthRecord {
        let success = ProxyHealthSuccess(
            observedAt: checkedAt,
            responseTimeMilliseconds: 300,
            exitAddressWasObserved: true,
            city: nil,
            countryName: nil,
            countryCode: nil,
            timezoneIdentifier: nil,
            localeIdentifier: nil
        )
        return ProxyHealthRecord(
            identity: identity,
            state: ProxyHealthState(
                latestAttempt: ProxyHealthAttempt(
                    checkedAt: checkedAt,
                    outcome: .succeeded,
                    responseTimeMilliseconds: 300
                ),
                lastSuccess: success
            )
        )
    }
}
