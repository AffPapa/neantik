import Foundation
import Network

enum WebKitProxyConfigurationError: LocalizedError {
    case invalidProxy
    case credentialUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidProxy:
            return "Настройки прокси WebKit некорректны. Проверь адрес и порт."
        case .credentialUnavailable:
            return "Пароль прокси недоступен в Связке ключей. Подключение остановлено; прямой маршрут не используется."
        }
    }
}

enum WebKitProxyFeature {
    /// Keep proxy launch available in the development build for the required
    /// headed qualification, but unavailable in public release builds until
    /// that exact route has passed its no-Direct and recovery checks.
    static var launchEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Builds a proxy policy for one WebKit data store. This configures Apple's
/// networking API; it does not by itself prove the route used by a live page.
enum WebKitProxyConfigurationFactory {
    static func configurations(
        for proxy: ProxyConfiguration?,
        password: String?
    ) throws -> [Network.ProxyConfiguration] {
        guard let proxy else { return [] }
        guard proxy.isValid,
              let port = NWEndpoint.Port(rawValue: UInt16(proxy.port)) else {
            throw WebKitProxyConfigurationError.invalidProxy
        }

        let host = proxy.host.hasPrefix("[") && proxy.host.hasSuffix("]")
            ? String(proxy.host.dropFirst().dropLast())
            : proxy.host
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        var result: Network.ProxyConfiguration
        switch proxy.kind {
        case .http:
            result = Network.ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .https:
            result = Network.ProxyConfiguration(
                httpCONNECTProxy: endpoint,
                tlsOptions: NWProtocolTLS.Options()
            )
        case .socks5:
            result = Network.ProxyConfiguration(socksv5Proxy: endpoint)
        }

        result.allowFailover = false
        result.matchDomains = []
        result.excludedDomains = []
        if !proxy.username.isEmpty {
            guard let password else {
                throw WebKitProxyConfigurationError.credentialUnavailable
            }
            result.applyCredential(username: proxy.username, password: password)
        }
        return [result]
    }
}
