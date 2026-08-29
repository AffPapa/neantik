import Foundation
import Testing
@testable import NeAntik

struct BrowserLaunchPolicyTests {
    @Test
    func proxyPolicyMatchesFailClosedLaunchArguments() {
        let profile = BrowserProfile(
            name: "Proxy",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: ""
            )
        )
        let policy = BrowserLaunchPolicy.resolve(
            profile: profile,
            runtimeCapabilities: .fingerprintIdentity
        )
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/policy-proxy"),
            runtimeCapabilities: .fingerprintIdentity
        )

        #expect(policy.route == .proxied(kind: .https))
        #expect(policy.webRTC == .disableNonProxiedUDP)
        #expect(policy.quic == .disabledByNeAntik)
        #expect(policy.dns == .proxyResolverFailClosed)
        #expect(policy.webGPUDisabled)
        #expect(
            policy.disabledFeatures == [
                "AsyncDns", "DnsOverHttpsUpgrade", "WebGPUService"
            ]
        )
        #expect(arguments.contains("--disable-quic"))
        #expect(
            arguments.contains(
                "--webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
        )
        #expect(
            arguments.contains(
                "--disable-features=AsyncDns,DnsOverHttpsUpgrade,WebGPUService"
            )
        )
    }

    @Test
    func directPolicyMatchesExplicitDirectLaunchArguments() {
        let profile = BrowserProfile(name: "Direct")
        let policy = BrowserLaunchPolicy.resolve(
            profile: profile,
            runtimeCapabilities: []
        )
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/policy-direct")
        )

        #expect(policy.route == .direct)
        #expect(policy.webRTC == .publicInterfaceOnly)
        #expect(policy.quic == .notDisabledByNeAntik)
        #expect(policy.dns == .ordinaryChromium)
        #expect(policy.disabledFeatures.isEmpty)
        #expect(arguments.contains("--no-proxy-server"))
        #expect(!arguments.contains("--disable-quic"))
        #expect(
            arguments.contains(
                "--webrtc-ip-handling-policy=default_public_interface_only"
            )
        )
    }

    @Test
    func freshProxyContextIsTheOnlyContextApplied() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let proxy = ProxyConfiguration(
            kind: .http,
            host: "proxy.example",
            port: 8080,
            username: ""
        )
        let profile = BrowserProfile(
            name: "Fresh",
            proxy: proxy,
            identity: BrowserIdentity(
                seed: 123,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE",
                proxyContextEvidence: .ipAPI(observedAt: observedAt)
            )
        )

        let fresh = BrowserLaunchPolicy.resolve(
            profile: profile,
            runtimeCapabilities: .fingerprintIdentity,
            now: observedAt.addingTimeInterval(60)
        )
        let stale = BrowserLaunchPolicy.resolve(
            profile: profile,
            runtimeCapabilities: .fingerprintIdentity,
            now: observedAt.addingTimeInterval(31 * 24 * 60 * 60)
        )
        let ordinary = BrowserLaunchPolicy.resolve(
            profile: profile,
            runtimeCapabilities: [],
            now: observedAt
        )

        #expect(fresh.proxyContextIsFresh)
        #expect(fresh.appliedTimezoneIdentifier == "Europe/Berlin")
        #expect(fresh.appliedLocaleIdentifier == "de-DE")
        #expect(!stale.proxyContextIsFresh)
        #expect(stale.appliedTimezoneIdentifier == nil)
        #expect(stale.appliedLocaleIdentifier == nil)
        #expect(ordinary.proxyContextIsFresh)
        #expect(ordinary.appliedTimezoneIdentifier == nil)
        #expect(ordinary.appliedLocaleIdentifier == nil)
    }

    @Test
    func partialSeedCapabilityPreservesExistingLaunchProtocol() {
        let profile = BrowserProfile(name: "Partial")
        let policy = BrowserLaunchPolicy.resolve(
            profile: profile,
            runtimeCapabilities: .fingerprintSeed
        )
        let environment = BrowserLaunchBuilder.environment(
            profile: profile,
            runtimeCapabilities: .fingerprintSeed,
            inherited: [:]
        )

        #expect(policy.fingerprintSeedConfigured)
        #expect(!policy.fingerprintIdentityConfigured)
        #expect(policy.fingerprintNoiseArgumentsEnabled)
        #expect(environment["NEANTIK_PROFILE_SEED"] != nil)
    }
}
