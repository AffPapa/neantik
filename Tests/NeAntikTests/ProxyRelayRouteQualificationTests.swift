#if DEBUG
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayRouteQualificationTests {
    @Test func completeCannotBypassMissingProbeOrRestart() throws {
        var request = ProxyRelayOwnerQualification.Request(root: "", upstreamPort: 1, kind: .http)
        request.requireCompleteRouteProbe = true
        #expect(throws: ProxyRelayOwnerQualification.Failure.self) {
            try ProxyRelayOwnerQualification.validateRouteFixture(request)
        }
        request.managerIntegration = true; request.observeTransport = true
        request.routeProbe = try BrowserRouteProbe.Plan.make(
            httpEndpoint: URL(string: "http://route-qualification.test/check")!,
            httpsEndpoint: URL(string: "https://browser.free/api/route-qa/https")!,
            verificationKey: Data(base64Encoded: "mT19pqlD/5uCjezfSL1yyY5dp/7G4biCkPFbJsRqLqo=")!, lifetimeSeconds: 10)
        try ProxyRelayOwnerQualification.validateRouteFixture(request)
        request.observeRestart = true
        #expect(throws: ProxyRelayOwnerQualification.Failure.self) {
            try ProxyRelayOwnerQualification.validateRouteFixture(request)
        }
    }
    @Test func unrelatedIssuerAndEndpointCannotEnterPositiveFixture() throws {
        var request = ProxyRelayOwnerQualification.Request(root: "", upstreamPort: 1, kind: .http)
        request.managerIntegration = true; request.observeTransport = true; request.requireCompleteRouteProbe = true
        request.routeProbe = try BrowserRouteProbe.Plan.make(
            httpEndpoint: URL(string: "http://route-qualification.test/check")!,
            httpsEndpoint: URL(string: "https://example.com/check")!, verificationKey: Data(repeating: 1, count: 32))
        #expect(throws: ProxyRelayOwnerQualification.Failure.self) {
            try ProxyRelayOwnerQualification.validateRouteFixture(request)
        }
    }
}
#endif
