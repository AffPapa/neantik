import Foundation
import Testing
@testable import NeAntik

struct EnvironmentDiagnosticAssessmentTests {
    @Test
    func badRuntimeSignatureIsAnObservedFailure() throws {
        let snapshot = makeSnapshot(runtimeSignature: false)
        let signature = try field(
            "fingerprint.runtime-signature",
            in: snapshot
        )

        #expect(signature.state == .observed)
        #expect(signature.severity == .failure)
    }

    @Test
    func missingRuntimeBlocksTheEnvironment() throws {
        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: BrowserProfile(name: "Missing runtime"),
            runtime: nil,
            proxyHealth: nil
        )

        #expect(
            try field("fingerprint.runtime", in: snapshot).severity ==
                .blocking
        )
    }

    @Test
    func failedWebRTCControlIsAnObservedFailure() throws {
        let profile = BrowserProfile(name: "WebRTC failure")
        let runtime = runtime(signature: true)
        let now = Date()
        let rawObservation = ValidatedProfileFingerprintObservation(
            profileID: profile.id,
            observedAt: now,
            route: .direct,
            verdict: .verified,
            webRTCLoopback: .failed
        )
        let observation = try #require(
            rawObservation.bound(to: profile, runtime: runtime)
        )
        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: runtime,
            proxyHealth: nil,
            fingerprintObservation: observation,
            now: now
        )
        let loopback = try field("webrtc.loopback", in: snapshot)

        #expect(loopback.state == .observed)
        #expect(loopback.severity == .failure)
    }

    @Test
    func expectedUnmeasuredSurfacesStayNeutral() throws {
        let snapshot = makeSnapshot()
        let expectedNeutralIDs = [
            "route.chromium-http",
            "fingerprint.observation",
            "webrtc.loopback",
            "webrtc.public-route",
            "transport.quic-observed",
            "transport.dns-observed",
            "geolocation.browser-api",
        ]

        for id in expectedNeutralIDs {
            #expect(try field(id, in: snapshot).severity == .neutral)
        }
    }

    @Test
    func neverCheckedProxyIsNeutralAndFixesOnNextLaunch() throws {
        let profile = BrowserProfile(
            name: "Fresh proxy",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8080,
                username: ""
            )
        )
        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: runtime(signature: true),
            proxyHealth: nil
        )
        let probe = try field("route.last-probe", in: snapshot)

        #expect(probe.severity == .neutral)
        #expect(probe.resolution?.key == .proxyContext)
        #expect(probe.resolution?.mode == .fixOnNextLaunch)
        #expect(probe.resolution?.action == .testProxy)
        #expect(probe.value.contains("автоматически перед запуском"))
    }

    @Test
    func directProfileGeolocationIsNotApplicableAndNeutral() throws {
        let snapshot = makeSnapshot()
        let geolocation = try field("geolocation.proxy", in: snapshot)

        #expect(geolocation.state == .unavailable)
        #expect(geolocation.severity == .neutral)
    }

    @Test
    func negativeFingerprintVerdictsAreFailures() throws {
        for verdict in [
            FingerprintAuditVerdict.unchanged,
            FingerprintAuditVerdict.unstable,
        ] {
            let profile = BrowserProfile(name: "Negative fingerprint")
            let runtime = runtime(signature: true)
            let now = Date()
            let rawObservation = ValidatedProfileFingerprintObservation(
                profileID: profile.id,
                observedAt: now,
                route: .direct,
                verdict: verdict,
                webRTCLoopback: .passed
            )
            let observation = try #require(
                rawObservation.bound(to: profile, runtime: runtime)
            )
            let snapshot = ProfileEnvironmentInspector.snapshot(
                profile: profile,
                runtime: runtime,
                proxyHealth: nil,
                fingerprintObservation: observation,
                now: now
            )

            #expect(
                try field(
                    "fingerprint.observation",
                    in: snapshot
                ).severity == .failure
            )
        }
    }

    @Test
    func failedProxyProbeIsAnObservedFailure() throws {
        let profile = BrowserProfile(
            name: "Proxy failure",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: ""
            )
        )
        let proxyHealth = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
                outcome: .connectionFailed
            ),
            lastSuccess: nil
        )
        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: runtime(signature: true),
            proxyHealth: proxyHealth
        )
        let probe = try field("route.last-probe", in: snapshot)

        #expect(probe.state == .observed)
        #expect(probe.severity == .failure)
        #expect(probe.resolution?.action == .testProxy)
    }

    @Test
    func invalidCredentialsRecommendEditingInsteadOfRetrying() throws {
        let profile = BrowserProfile(
            name: "Proxy credentials",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: "operator"
            )
        )
        let proxyHealth = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
                outcome: .authenticationRejected
            ),
            lastSuccess: nil
        )
        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: runtime(signature: true),
            proxyHealth: proxyHealth
        )
        let probe = try field("route.last-probe", in: snapshot)

        #expect(probe.severity == .failure)
        #expect(probe.resolution?.action == .editProxy)
    }

    @Test
    func reachableProxyWithoutCompleteContextIsAttentionNotSuccess()
        throws
    {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = BrowserProfile(
            name: "Incomplete proxy context",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: ""
            )
        )
        let proxyHealth = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: observedAt,
                outcome: .succeeded,
                responseTimeMilliseconds: 120
            ),
            lastSuccess: ProxyHealthSuccess(
                observedAt: observedAt,
                responseTimeMilliseconds: 120,
                exitAddressWasObserved: true,
                city: "Paris",
                countryName: "France",
                countryCode: "FR",
                timezoneIdentifier: nil,
                localeIdentifier: "fr-FR"
            )
        )
        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: runtime(signature: true),
            proxyHealth: proxyHealth,
            now: observedAt
        )

        #expect(
            try field("route.last-probe", in: snapshot).severity ==
                .attention
        )
        #expect(
            try field("geolocation.context", in: snapshot).severity ==
                .attention
        )
        #expect(
            try field("geolocation.launch", in: snapshot).severity !=
                .success
        )
    }

    private func makeSnapshot(
        runtimeSignature: Bool? = true
    ) -> ProfileEnvironmentSnapshot {
        ProfileEnvironmentInspector.snapshot(
            profile: BrowserProfile(name: "Assessment"),
            runtime: runtime(signature: runtimeSignature),
            proxyHealth: nil
        )
    }

    private func runtime(signature: Bool?) -> BrowserRuntime {
        BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: URL(fileURLWithPath: "/tmp/NeAntik Browser"),
            source: "Test",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "151",
                architectures: ["arm64"],
                codeSignatureValid: signature
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
