import Foundation
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
        #expect(try WebKitProxyConfigurationFactory.systemWebKitConfigurations(for: nil).isEmpty)
    }

    @Test func systemWebKitRejectsEveryExplicitProxyKind() {
        for kind in ProxyKind.allCases {
            let proxy = ProxyConfiguration(kind: kind, host: "proxy.example.test", port: 8443, username: "qa-user")
            #expect(throws: WebKitProxyConfigurationError.self) {
                try WebKitProxyConfigurationFactory.systemWebKitConfigurations(for: proxy)
            }
        }
    }

    @Test func ownedRuntimeUsesOnlyAuthenticatedLoopbackBrokerWithoutFailover() throws {
        let profileID = UUID(uuidString: "2fd91f78-8cd1-451e-8d6c-1b9b36f1b301")!
        let sessionID = UUID(uuidString: "1315f44b-7921-4d9d-894c-4ec61fb60b5f")!
        let scope = WebKitRelayAuthority.Scope(profileID: profileID, storeID: profileID,
                                                sessionID: sessionID, revision: 11)
        let authority = WebKitRelayAuthority()
        try authority.register(scope: scope, route: .direct)
        let capability = try authority.issue(for: scope)
        let session = WebKitHostIPC.Session(profileID: profileID, revision: 11,
            generation: sessionID, dataRoot: "/tmp/neantik-webkit-broker-test",
            runtimeSHA256: String(repeating: "c", count: 64))
        let credential = try WebKitHostIPC.RelayCredential(session: session,
                                                            capability: capability)

        let configuration = WebKitProxyConfigurationFactory.brokerConfiguration(using: credential)
        #expect(WebKitProxyConfigurationFactory.brokerHost == "127.0.0.1")
        #expect(WebKitProxyConfigurationFactory.brokerPort == WebKitLoopbackBroker.sandboxPort)
        #expect(configuration.allowFailover == false)
        #expect(configuration.matchDomains.isEmpty)
        #expect(configuration.excludedDomains.isEmpty)
        #expect(!configuration.debugDescription.contains("synthetic-secret"))
        #expect(!configuration.debugDescription.contains("proxy.example.test"))
    }

    @Test func malformedExplicitProxyIsAlsoRejectedFailClosed() {
        let malformed = ProxyConfiguration(kind: .http, host: "proxy.example.test", port: 0, username: "")
        #expect(throws: WebKitProxyConfigurationError.self) {
            try WebKitProxyConfigurationFactory.systemWebKitConfigurations(for: malformed)
        }
    }
}
