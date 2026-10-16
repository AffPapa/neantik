#if DEBUG
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayRouteQualificationTests {
    @Test func backgroundCaptureDoesNotSuppressNormalNetworking() throws {
        let log = URL(fileURLWithPath: "/private/tmp/owned-netlog.json")
        let flags = ProxyRelayOwnerQualification.captureArguments(log: log, observeBackgroundNetworking: true)
        #expect(flags == ["--use-mock-keychain", "--log-net-log=" + log.path, "--net-log-capture-mode=Default",
                          "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
                          "--remote-allow-origins=http://neantik.local"])
        let suppressed = ProxyRelayOwnerQualification.captureArguments(log: log, observeBackgroundNetworking: false)
        #expect(!suppressed.contains { $0.hasPrefix("--remote-debugging") })
        for flag in ["--disable-background-networking", "--disable-component-update", "--disable-sync", "--disable-extensions"] {
            #expect(!flags.contains(flag))
            #expect(suppressed.contains(flag))
        }
    }
    @Test func ordinaryBundleCannotEnableBackgroundDownloadInstrumentation() {
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-relay-owner-qualification-owned"))
        #expect(ProxyRelayOwnerQualification.browserArguments(paths: paths).isEmpty)
    }
    @Test func backgroundCaptureRefusesBiasedOrEarlyExitExperiments() throws {
        var request = ProxyRelayOwnerQualification.Request(root: "", upstreamPort: 1, kind: .http)
        request.observeBackgroundNetworking = true
        #expect(throws: ProxyRelayOwnerQualification.Failure.self) {
            try ProxyRelayOwnerQualification.validateRouteFixture(request)
        }
        request.managerIntegration = true
        try ProxyRelayOwnerQualification.validateRouteFixture(request)
        for option in [0, 1, 2, 3] {
            var biased = request
            switch option {
            case 0: biased.observeRestart = true
            case 1: biased.mutateBeforeActivation = true
            case 2: biased.terminateAfterActivation = true
            default: biased.cancelBeforeActivation = true
            }
            #expect(throws: ProxyRelayOwnerQualification.Failure.self) {
                try ProxyRelayOwnerQualification.validateRouteFixture(biased)
            }
        }
    }
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
