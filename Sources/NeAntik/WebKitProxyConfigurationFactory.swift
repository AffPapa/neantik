import Foundation
import Network

enum WebKitProxyConfigurationError: LocalizedError {
    case systemWebKitProxyUnsupported

    var errorDescription: String? {
        switch self {
        case .systemWebKitProxyUnsupported:
            return "Системный WebKit не запускает профиль с прокси: безопасный изолированный маршрут ещё не подключён."
        }
    }
}

enum WebKitProxyFeature {
    enum BuildMode: Equatable {
        case disabled
        case qualification
        case production
    }

    /// Build mode is selected at compile time. Environment variables and
    /// profile metadata cannot turn a disabled or QA binary into production.
    static var buildMode: BuildMode {
        #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
        return .qualification
        #elseif NEANTIK_WEBKIT_PROXY_PRODUCTION
        return .production
        #else
        return .disabled
        #endif
    }

    static var launchEnabled: Bool {
        isEnabled(bundleIdentifier: Bundle.main.bundleIdentifier, mode: buildMode)
    }

    static func isEnabled(bundleIdentifier: String?, mode: BuildMode) -> Bool {
        switch mode {
        case .disabled:
            return false
        case .qualification:
            return bundleIdentifier == "app.neantik.desktop.dev" ||
                bundleIdentifier == "app.neantik.desktop.dev.webkit-host"
        case .production:
            return bundleIdentifier == "app.neantik.desktop" ||
                bundleIdentifier == "app.neantik.desktop.webkit-host"
        }
    }

    static func isEnabled(bundleIdentifier: String?) -> Bool {
        isEnabled(bundleIdentifier: bundleIdentifier, mode: buildMode)
    }
}

/// Keeps system WKWebView fail-closed. Its per-store proxy API would connect
/// directly to an upstream and bypass NeAntik's authenticated broker boundary.
enum WebKitProxyConfigurationFactory {
    static let brokerHost = "127.0.0.1"
    static let brokerPort = WebKitBrokerPort.sandboxPort

    /// Owned WebKit must always connect through the local broker. The broker
    /// selects this profile's explicit Direct or upstream-proxy route; the
    /// browser never receives the upstream endpoint or its password.
    static func brokerConfiguration(
        using credential: WebKitHostIPC.RelayCredential
    ) -> nw_proxy_config_t {
        // Public Network C API + WebKit's refined Objective-C property avoid
        // libswiftWebKit, whose dependency would load a second system engine.
        let endpoint = nw_endpoint_create_host(brokerHost, String(brokerPort))
        let result = nw_proxy_config_create_http_connect(endpoint, nil)
        nw_proxy_config_set_failover_allowed(result, false)
        nw_proxy_config_clear_match_domains(result)
        // Candidate catch-all suffix; native matching remains unqualified.
        // QA18/19 first navigations were blocked by the Dev host's missing
        // synthetic-origin ATS exceptions before proxy selection ran.
        nw_proxy_config_add_match_domain(result, "")
        nw_proxy_config_clear_excluded_domains(result)
        // A QA-only exact domain demonstrated one route but made unrelated
        // origins miss the proxy. This catch-all still needs native QA.
        // The NetworkProcess sandbox still permits only the loopback broker;
        // qualify named HTTP, HTTPS, DNS and refusal on a signed host before
        // enabling this route in a public build.
        credential.withCredentials { username, password in
            nw_proxy_config_set_username_and_password(result, username, password)
        }
        return result
    }

    static func systemWebKitConfigurations(
        for proxy: ProxyConfiguration?
    ) throws -> [nw_proxy_config_t] {
        guard proxy == nil else {
            throw WebKitProxyConfigurationError.systemWebKitProxyUnsupported
        }
        return []
    }
}
