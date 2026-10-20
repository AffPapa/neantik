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
    /// System WKWebView does not provide NeAntik's fail-closed per-profile
    /// route. Keep this disabled in every build until the isolated runtime and
    /// broker are wired together and qualified on the exact candidate.
    static let launchEnabled = false
}

/// Keeps system WKWebView fail-closed. Its per-store proxy API would connect
/// directly to an upstream and bypass NeAntik's authenticated broker boundary.
enum WebKitProxyConfigurationFactory {
    static let brokerHost = "127.0.0.1"
    static let brokerPort = WebKitLoopbackBroker.sandboxPort

    /// Owned WebKit must always connect through the local broker. The broker
    /// selects this profile's explicit Direct or upstream-proxy route; the
    /// browser never receives the upstream endpoint or its password.
    static func brokerConfiguration(
        using credential: WebKitHostIPC.RelayCredential
    ) -> Network.ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(brokerHost),
            port: NWEndpoint.Port(rawValue: brokerPort)!
        )
        var result = Network.ProxyConfiguration(httpCONNECTProxy: endpoint)
        result.allowFailover = false
        result.matchDomains = []
        result.excludedDomains = []
        credential.withCredentials { username, password in
            result.applyCredential(username: username, password: password)
        }
        return result
    }

    static func systemWebKitConfigurations(
        for proxy: ProxyConfiguration?
    ) throws -> [Network.ProxyConfiguration] {
        guard proxy == nil else {
            throw WebKitProxyConfigurationError.systemWebKitProxyUnsupported
        }
        return []
    }
}
