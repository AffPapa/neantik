import Network
import Testing
@testable import NeAntik

struct WebKitProxyConfigurationFactoryTests {
    @Test func unqualifiedSystemWebKitProxyIsDisabledInEveryBuild() {
        #expect(!WebKitProxyFeature.launchEnabled)
        #expect(BrowserEngine.webkit.managementCapabilities["proxy"] == false)
        #expect(BrowserEngine.webkit.settingsSummary.contains("Прокси WebKit отключён во всех сборках"))
        #expect(!BrowserEngine.webkit.settingsSummary.contains("Прокси профиля включён только в Dev"))
    }

    @Test func directProfileHasNoProxyConfiguration() throws {
        #expect(try WebKitProxyConfigurationFactory.configurations(for: nil, password: nil).isEmpty)
    }

    @Test func supportedProxyKindsAreProfileScopedAndDoNotFailOver() throws {
        for kind in ProxyKind.allCases {
            let proxy = ProxyConfiguration(kind: kind, host: "proxy.example.test", port: 8443, username: "")
            let configurations = try WebKitProxyConfigurationFactory.configurations(for: proxy, password: nil)
            #expect(configurations.count == 1)
            #expect(configurations[0].allowFailover == false)
            #expect(configurations[0].matchDomains.isEmpty)
            #expect(configurations[0].excludedDomains.isEmpty)
        }
    }

    @Test func ipv6EndpointIsAcceptedAndAuthenticatedProxyRequiresKeychainPassword() throws {
        let ipv6 = ProxyConfiguration(kind: .socks5, host: "[::1]", port: 1080, username: "")
        #expect(try WebKitProxyConfigurationFactory.configurations(for: ipv6, password: nil).count == 1)

        let authenticated = ProxyConfiguration(kind: .https, host: "proxy.example.test", port: 443, username: "qa-user")
        #expect(throws: WebKitProxyConfigurationError.self) {
            try WebKitProxyConfigurationFactory.configurations(for: authenticated, password: nil)
        }
        let withPassword = try WebKitProxyConfigurationFactory.configurations(for: authenticated, password: "synthetic-secret")
        #expect(withPassword.count == 1)
        #expect(!withPassword[0].debugDescription.contains("synthetic-secret"))
    }

    @Test func malformedProxyIsRejectedBeforeNativeConfiguration() {
        let malformed = ProxyConfiguration(kind: .http, host: "proxy.example.test", port: 0, username: "")
        #expect(throws: WebKitProxyConfigurationError.self) {
            try WebKitProxyConfigurationFactory.configurations(for: malformed, password: nil)
        }
    }
}
