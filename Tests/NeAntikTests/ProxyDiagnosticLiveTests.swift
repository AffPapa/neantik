import Foundation
import Testing
@testable import NeAntik

/// Opt-in only: the parent fixture owns all listeners and authorizes the one
/// external HTTPS destination. No production profile or Keychain is involved.
struct ProxyDiagnosticLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_DIAGNOSTIC_LIVE_FIXTURE"] == "1"))
    func actualCurlTLSAuthenticationAndSOCKS() async throws {
        let environment = ProcessInfo.processInfo.environment
        func port(_ key: String) throws -> Int {
            guard let text = environment[key], let number = Int(text), (1...65_535).contains(number) else {
                throw ProxyDiagnosticError.invalidAddress
            }
            return number
        }
        let endpoint = try ProxyDiagnosticEndpoint("https://ipwho.is/")
        let http = ProxyConfiguration(kind: .http, host: "127.0.0.1", port: try port("NEANTIK_DIAGNOSTIC_HTTP_PORT"), username: "fixture")
        let httpResult = try await ProxyTester().diagnose(endpoint: endpoint, configuration: http, password: "synthetic-only", consent: true)
        // Evaluate to a boolean so a test failure cannot print the observed IP.
        let httpHasIP = !httpResult.ipAddress.isEmpty
        #expect(httpHasIP)
        do {
            _ = try await ProxyTester().diagnose(endpoint: endpoint, configuration: http, password: "wrong-synthetic", consent: true)
            Issue.record("A real HTTP 407 must reject authentication")
        } catch let error as ProxyProbeError { #expect(error.outcome == .authenticationRejected) }
        let socks = ProxyConfiguration(kind: .socks5, host: "127.0.0.1", port: try port("NEANTIK_DIAGNOSTIC_SOCKS_PORT"), username: "")
        let socksResult = try await ProxyTester().diagnose(endpoint: endpoint, configuration: socks, password: "", consent: true)
        let socksHasIP = !socksResult.ipAddress.isEmpty
        #expect(socksHasIP)
        let untrusted = try ProxyDiagnosticEndpoint("https://127.0.0.1:\(try port("NEANTIK_DIAGNOSTIC_TLS_PORT"))/ip")
        do {
            _ = try await ProxyTester().diagnose(endpoint: untrusted, configuration: http, password: "synthetic-only", consent: true)
            Issue.record("An untrusted real TLS certificate must be refused")
        } catch let error as ProxyProbeError { #expect(error.outcome == .transportSecurityFailed) }
    }
}
