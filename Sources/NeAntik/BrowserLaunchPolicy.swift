import Foundation

enum BrowserRoutePolicy: Equatable, Sendable {
    case direct
    case proxied(kind: ProxyKind)
}

enum BrowserWebRTCPolicy: String, Equatable, Sendable {
    case publicInterfaceOnly
    case disableNonProxiedUDP
}

enum BrowserQUICPolicy: String, Equatable, Sendable {
    case notDisabledByNeAntik
    case disabledByNeAntik
}

enum BrowserDNSPolicy: String, Equatable, Sendable {
    case ordinaryChromium
    case proxyResolverFailClosed
}

struct BrowserLaunchPolicy: Equatable, Sendable {
    let route: BrowserRoutePolicy
    let webRTC: BrowserWebRTCPolicy
    let quic: BrowserQUICPolicy
    let dns: BrowserDNSPolicy
    let fingerprintSeedConfigured: Bool
    let fingerprintIdentityConfigured: Bool
    let fingerprintNoiseArgumentsEnabled: Bool
    let webGPUDisabled: Bool
    let proxyContextIsFresh: Bool
    let appliedLocaleIdentifier: String?
    let appliedTimezoneIdentifier: String?
    let disabledFeatures: Set<String>

    /// The prepared Chromium patch is not a qualified shipped capability yet.
    /// Refuse an explicit request at the process boundary instead of launching
    /// native fonts while pretending to honor it. Replace this gate only when
    /// exact runtime support and explicit user activation have been qualified.
    static func validateFontPolicy(_ profile: BrowserProfile) throws {
        guard profile.fontPolicy == .native else {
            throw UnsupportedBrowserFontPolicyError()
        }
    }

    static func resolve(
        profile: BrowserProfile,
        runtimeCapabilities: BrowserRuntimeCapabilities,
        now: Date = Date()
    ) -> BrowserLaunchPolicy {
        let fingerprintSeedConfigured = runtimeCapabilities.contains(
            .fingerprintSeed
        )
        let fingerprintIdentityConfigured = runtimeCapabilities.contains(
            .fingerprintIdentity
        )
        let proxyContextIsFresh =
            profile.proxy != nil &&
            profile.identity.proxyContextEvidence?.isFresh(
                relativeTo: now
            ) == true

        var disabledFeatures = Set<String>()
        if fingerprintSeedConfigured {
            disabledFeatures.insert("WebGPUService")
        }

        let route: BrowserRoutePolicy
        let webRTC: BrowserWebRTCPolicy
        let quic: BrowserQUICPolicy
        let dns: BrowserDNSPolicy
        if let proxy = profile.proxy {
            route = .proxied(kind: proxy.kind)
            webRTC = .disableNonProxiedUDP
            quic = .disabledByNeAntik
            dns = .proxyResolverFailClosed
            disabledFeatures.formUnion(["AsyncDns", "DnsOverHttpsUpgrade"])
        } else {
            route = .direct
            webRTC = .publicInterfaceOnly
            quic = .notDisabledByNeAntik
            dns = .ordinaryChromium
        }

        return BrowserLaunchPolicy(
            route: route,
            webRTC: webRTC,
            quic: quic,
            dns: dns,
            fingerprintSeedConfigured: fingerprintSeedConfigured,
            fingerprintIdentityConfigured: fingerprintIdentityConfigured,
            fingerprintNoiseArgumentsEnabled: false,
            webGPUDisabled: fingerprintSeedConfigured,
            proxyContextIsFresh: proxyContextIsFresh,
            appliedLocaleIdentifier:
                fingerprintSeedConfigured && proxyContextIsFresh
                    ? profile.identity.localeIdentifier
                    : nil,
            appliedTimezoneIdentifier:
                fingerprintSeedConfigured && proxyContextIsFresh
                    ? profile.identity.timezoneIdentifier
                    : nil,
            disabledFeatures: disabledFeatures
        )
    }
}
