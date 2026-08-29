import Foundation
import Testing
@testable import NeAntik

struct ProfileEnvironmentInspectorTests {
    @Test
    func snapshotUsesAllFiveEvidenceStatesWithoutSensitiveValues() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = BrowserProfile(
            name: "Environment",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "secret-proxy.example",
                port: 443,
                username: "secret-user"
            ),
            identity: BrowserIdentity(
                seed: 123_456_789,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE",
                proxyContextEvidence: .ipAPI(observedAt: observedAt)
            )
        )
        let runtime = BrowserRuntime(
            name: "Private runtime name",
            executableURL: URL(fileURLWithPath: "/tmp/Chromium"),
            source: "Private runtime source",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "151.0.1",
                architectures: ["arm64"],
                codeSignatureValid: true,
                executableSHA256: String(repeating: "a", count: 64),
                frameworkSHA256: String(repeating: "b", count: 64)
            )
        )
        let health = ProxyHealthUpdatePolicy.success(
            ProxyTestObservation(
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
        )
        let rawObservation = ValidatedProfileFingerprintObservation(
            profileID: profile.id,
            observedAt: observedAt,
            route: .proxied,
            verdict: .verified,
            webRTCLoopback: .passed
        )
        let observation = try #require(
            rawObservation.bound(to: profile, runtime: runtime)
        )

        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: runtime,
            proxyHealth: health,
            fingerprintObservation: observation,
            now: now
        )
        let fields = snapshot.sections.flatMap(\.fields)
        let states = Set(fields.map(\.state))
        let publicText = fields.flatMap {
            [$0.title, $0.value, $0.detail ?? ""]
        }.joined(separator: "\n") + snapshot.limitations.joined(separator: "\n")

        #expect(
            states == [
                .configured, .derived, .observed, .unavailable, .unverified
            ]
        )
        #expect(!publicText.contains("123456789"))
        #expect(!publicText.contains(profile.identity.displayCode))
        #expect(!publicText.contains("203.0.113.77"))
        #expect(!publicText.contains("secret-user"))
        #expect(!publicText.contains("secret-proxy.example"))
        #expect(!publicText.contains(String(repeating: "a", count: 64)))
        #expect(!publicText.contains(String(repeating: "b", count: 64)))
        #expect(try field("fingerprint.observation", in: snapshot).state == .observed)
        #expect(try field("webrtc.loopback", in: snapshot).state == .observed)
        #expect(
            try field("route.chromium-http", in: snapshot).value ==
                "Не измерялся"
        )
    }

    @Test
    func mismatchedFingerprintRouteIsNotPresentedAsObserved() throws {
        let profile = BrowserProfile(name: "Direct")
        let runtime = testRuntime()
        let rawObservation = ValidatedProfileFingerprintObservation(
            profileID: profile.id,
            observedAt: Date(),
            route: .proxied,
            verdict: .verified,
            webRTCLoopback: .passed
        )
        let observation = try #require(
            rawObservation.bound(to: profile, runtime: runtime)
        )

        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: runtime,
            proxyHealth: nil,
            fingerprintObservation: observation
        )

        #expect(
            try field("fingerprint.observation", in: snapshot).state ==
                .unverified
        )
        #expect(
            try field("webrtc.loopback", in: snapshot).state == .unverified
        )
    }

    @Test
    func staleProxyContextIsOmittedWithoutClaimingLaunchBlock() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = BrowserProfile(
            name: "Stale",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8080,
                username: ""
            ),
            identity: BrowserIdentity(
                seed: 123,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE",
                proxyContextEvidence: .ipAPI(observedAt: observedAt)
            )
        )

        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: testRuntime(),
            proxyHealth: nil,
            now: observedAt.addingTimeInterval(31 * 24 * 60 * 60)
        )
        let launch = try field("geolocation.launch", in: snapshot)

        #expect(launch.state == .unverified)
        #expect(
            launch.value ==
                "Устаревший контекст обновится перед запуском"
        )
        #expect(
            launch.detail ==
                "Если прокси или контекст не подтвердятся, " +
                "NeAntik остановит запуск."
        )
        #expect(launch.severity == .neutral)
        #expect(launch.resolution?.key == .proxyContext)
        #expect(launch.resolution?.mode == .fixOnNextLaunch)
    }

    @Test
    func fingerprintObservationFailsClosedAfterProfileOrRuntimeChange() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = BrowserProfile(name: "Bound")
        let runtime = testRuntime()
        let raw = ValidatedProfileFingerprintObservation(
            profileID: profile.id,
            observedAt: now,
            route: .direct,
            verdict: .verified,
            webRTCLoopback: .passed
        )
        let observation = try #require(
            raw.bound(to: profile, runtime: runtime)
        )
        let changedProfile = BrowserProfile(
            id: profile.id,
            name: profile.name,
            identity: BrowserIdentity(seed: profile.identity.seed &+ 1)
        )
        let changedRuntime = BrowserRuntime(
            name: runtime.name,
            executableURL: runtime.executableURL,
            source: runtime.source,
            flavor: runtime.flavor,
            inspection: BrowserRuntimeInspection(
                version: "152",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )

        let changedProfileSnapshot = ProfileEnvironmentInspector.snapshot(
            profile: changedProfile,
            runtime: runtime,
            proxyHealth: nil,
            fingerprintObservation: observation,
            now: now
        )
        let changedRuntimeSnapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: changedRuntime,
            proxyHealth: nil,
            fingerprintObservation: observation,
            now: now
        )

        #expect(
            try field(
                "fingerprint.observation",
                in: changedProfileSnapshot
            ).state == .unverified
        )
        #expect(
            try field(
                "fingerprint.observation",
                in: changedRuntimeSnapshot
            ).state == .unverified
        )
    }

    @Test
    func expiredOrUnboundFingerprintObservationIsNeverPresentedAsMeasured()
        throws
    {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = BrowserProfile(name: "Expired")
        let runtime = testRuntime()
        let unbound = ValidatedProfileFingerprintObservation(
            profileID: profile.id,
            observedAt: observedAt,
            route: .direct,
            verdict: .verified,
            webRTCLoopback: .passed
        )
        let bound = try #require(unbound.bound(to: profile, runtime: runtime))
        let expiredAt = observedAt.addingTimeInterval(
            ValidatedProfileFingerprintObservation.freshnessLifetime + 1
        )

        for observation in [unbound, bound] {
            let snapshot = ProfileEnvironmentInspector.snapshot(
                profile: profile,
                runtime: runtime,
                proxyHealth: nil,
                fingerprintObservation: observation,
                now: observation == unbound ? observedAt : expiredAt
            )
            #expect(
                try field("fingerprint.observation", in: snapshot).state ==
                    .unverified
            )
        }
    }

    @MainActor
    @Test
    func sharedObservationStoreAcceptsOnlyRevisionBoundEvidence() throws {
        let profile = BrowserProfile(name: "Shared")
        let runtime = testRuntime()
        let raw = ValidatedProfileFingerprintObservation(
            profileID: profile.id,
            observedAt: Date(),
            route: .direct,
            verdict: .verified,
            webRTCLoopback: .passed
        )
        let store = FingerprintObservationStore()

        store.record(raw)
        #expect(store.observation(for: profile.id) == nil)

        let bound = try #require(raw.bound(to: profile, runtime: runtime))
        store.record(bound)
        #expect(store.observation(for: profile.id) == bound)

        store.remove(profileID: profile.id)
        #expect(store.observation(for: profile.id) == nil)
    }

    private func testRuntime() -> BrowserRuntime {
        BrowserRuntime(
            name: "NeAntik Chromium",
            executableURL: URL(fileURLWithPath: "/tmp/Chromium"),
            source: "Test",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "151",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )
    }

    private func field(
        _ id: String,
        in snapshot: ProfileEnvironmentSnapshot
    ) throws -> EnvironmentDiagnosticField {
        try #require(
            snapshot.sections.flatMap(\.fields).first { $0.id == id }
        )
    }
}
