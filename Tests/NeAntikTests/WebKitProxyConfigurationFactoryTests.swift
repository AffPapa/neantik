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

    @Test func qualificationSwitchIsCompileTimeAndDevBundleScoped() {
        #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
        #expect(WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.dev"))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop"))
        #expect(WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.dev.webkit-host"))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.webkit-host"))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.dev.webkit-host.extra"))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: nil))
        #else
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.dev"))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.dev.webkit-host"))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop"))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: nil))
        #endif
    }

    @Test func productionModeUsesOnlyProductionManagerAndHostIdentifiers() {
        #expect(WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop",
                                             mode: .production))
        #expect(WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.webkit-host",
                                             mode: .production))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.dev",
                                              mode: .production))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.dev.webkit-host",
                                              mode: .production))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.webkit-host.extra",
                                              mode: .production))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: nil, mode: .production))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop",
                                              mode: .qualification))
        #expect(!WebKitProxyFeature.isEnabled(bundleIdentifier: "app.neantik.desktop.dev",
                                              mode: .disabled))
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
        #expect(nw_proxy_config_get_failover_allowed(configuration) == false)
        var matchDomains: [String] = []
        var excludedCount = 0
        nw_proxy_config_enumerate_match_domains(configuration) {
            matchDomains.append(String(cString: $0))
        }
        nw_proxy_config_enumerate_excluded_domains(configuration) { _ in excludedCount += 1 }
        #expect(matchDomains == [""])
        #expect(excludedCount == 0)
        // Positive/negative control: the API must expose a deliberately changed
        // policy; a default value or missing observation is not a pass.
        nw_proxy_config_set_failover_allowed(configuration, true)
        #expect(nw_proxy_config_get_failover_allowed(configuration))
        nw_proxy_config_add_excluded_domain(configuration, "own.invalid")
        nw_proxy_config_enumerate_excluded_domains(configuration) { _ in excludedCount += 1 }
        #expect(excludedCount == 1)
    }

    @Test func malformedExplicitProxyIsAlsoRejectedFailClosed() {
        let malformed = ProxyConfiguration(kind: .http, host: "proxy.example.test", port: 0, username: "")
        #expect(throws: WebKitProxyConfigurationError.self) {
            try WebKitProxyConfigurationFactory.systemWebKitConfigurations(for: malformed)
        }
    }
}
