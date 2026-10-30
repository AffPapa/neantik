import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

struct BrowserRouteProbeTests {
    private let key = Curve25519.Signing.PrivateKey()
    private func plan(http: String = "http://owned.example.test/check", https: String = "https://owned.example.test/check",
                      lifetime: Int = 30) -> BrowserRouteProbe.Plan {
        .init(httpEndpoint: URL(string: http)!, httpsEndpoint: URL(string: https)!, verificationKey: key.publicKey.rawRepresentation,
              httpNonce: String(repeating: "a", count: 64), httpsNonce: String(repeating: "b", count: 64), lifetimeSeconds: lifetime)
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value: UInt64 = 1_000_000_000
        func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: UInt64) { lock.lock(); value += seconds * 1_000_000_000; lock.unlock() }
    }
    private func request(_ target: String, extra: String = "", host: String = "127.0.0.1:1234") -> Data {
        Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\(extra)\r\n".utf8)
    }
    private func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func ack(_ component: BrowserRouteProbe.Component, input: BrowserRouteProbe.Plan,
                     nonce: String? = nil, expires: Int64 = 1010, endpoint: String? = nil, signingKey: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let url = endpoint ?? input.endpoint(component).absoluteString
        let hash = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        let receipt = BrowserRouteProbe.Receipt(schema: 1, component: component, nonce: nonce ?? input.nonce(component), endpointSHA256: hash, expiresAt: expires)
        let bytes = try JSONEncoder().encode(receipt), signature = try (signingKey ?? key).signature(for: bytes)
        return request(BrowserRouteProbe.Session.callbackPath + "?r=" + b64(bytes) + "&s=" + b64(signature))
    }
    private func begin(_ session: BrowserRouteProbe.Session) throws -> String {
        try session.activate(port: 1234)
        let reply = try session.respond(to: request(BrowserRouteProbe.Session.entryPath))
        let line = try #require(String(data: reply.bytes, encoding: .utf8)?.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Location: ") }))
        let url = try #require(URLComponents(string: String(line.dropFirst(10))))
        return url.percentEncodedPath + "?" + (url.percentEncodedQuery ?? "")
    }
    @Test func newPlansGenerateIndependentNoncesWithoutNetworkOrProxyChanges() throws {
        let input = plan()
        let a = try BrowserRouteProbe.Plan.make(httpEndpoint: input.httpEndpoint, httpsEndpoint: input.httpsEndpoint, verificationKey: input.verificationKey)
        let b = try BrowserRouteProbe.Plan.make(httpEndpoint: input.httpEndpoint, httpsEndpoint: input.httpsEndpoint, verificationKey: input.verificationKey)
        #expect(Set([a.httpNonce, a.httpsNonce, b.httpNonce, b.httpsNonce]).count == 4)
        #expect(a.policySHA256 == b.policySHA256)
        #expect(a.httpEndpoint == input.httpEndpoint && a.httpsEndpoint == input.httpsEndpoint)
    }
    @Test func completeRequiresForwardedHTTPAndIndependentSignedHTTPSBrowserCallback() throws {
        let input = plan(), session = try BrowserRouteProbe.Session(plan: input, wallSeconds: { 1000 })
        let target = try begin(session)
        #expect(session.snapshot().status == .waitingHTTP)
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: ack(.http, input: input)) }
        session.observeTunnel(try input.destination(.http)) // CONNECT is not GET.
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: ack(.http, input: input)) }
        session.observeForwardedHTTP(request(target, host: "owned.example.test"), destination: try input.destination(.http))
        _ = try session.respond(to: ack(.http, input: input))
        #expect(session.snapshot().httpResponseAcknowledged)
        #expect(!session.snapshot().httpsResponseAcknowledged)
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: ack(.https, input: input)) }
        session.observeTunnel(try input.destination(.https))
        let result = try session.respond(to: ack(.https, input: input))
        #expect(String(decoding: result.bytes, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
        #expect(session.snapshot().status == .complete)
        #expect(session.snapshot().dnsResolution == "notObserved")
        #expect(session.snapshot().hostnameDelegationObserved)
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: ack(.https, input: input)) }
    }
    @Test func signedButWrongFreshnessNonceKeyEndpointOrComponentCannotAdvance() throws {
        let input = plan(), session = try BrowserRouteProbe.Session(plan: input, wallSeconds: { 1000 })
        let target = try begin(session)
        session.observeForwardedHTTP(request(target, host: "owned.example.test"), destination: try input.destination(.http))
        for control in [try ack(.http, input: input, nonce: String(repeating: "c", count: 64)),
                        try ack(.https, input: input), try ack(.http, input: input, expires: 999),
                        try ack(.http, input: input, expires: Int64.max),
                        try ack(.http, input: input, endpoint: "http://foreign.example.test/check"),
                        try ack(.http, input: input, signingKey: .init())] {
            #expect(throws: (any Error).self) { try session.respond(to: control) }
            #expect(session.snapshot().status == .waitingHTTP)
            #expect(!session.snapshot().httpResponseAcknowledged)
        }
        _ = try session.respond(to: ack(.http, input: input)) // sensitivity positive after negatives
    }
    @Test func evenSignedDuplicateUnknownOrBooleanReceiptFieldsAreRejected() throws {
        let input = plan(), session = try BrowserRouteProbe.Session(plan: input, wallSeconds: { 1000 })
        let target = try begin(session)
        session.observeForwardedHTTP(request(target, host: "owned.example.test"), destination: try input.destination(.http))
        let hash = SHA256.hash(data: Data(input.httpEndpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let prefix = "\"component\":\"http\",\"nonce\":\"\(input.httpNonce)\",\"endpointSHA256\":\"\(hash)\",\"expiresAt\":1010"
        for text in ["{\"schema\":1,\"schema\":1," + prefix + "}",
                     "{\"schema\":true," + prefix + "}", "{\"extra\":1,\"schema\":1," + prefix + "}"] {
            let bytes = Data(text.utf8), sig = try key.signature(for: bytes)
            let forged = request(BrowserRouteProbe.Session.callbackPath + "?r=" + b64(bytes) + "&s=" + b64(sig))
            #expect(throws: (any Error).self) { try session.respond(to: forged) }
            #expect(!session.snapshot().httpResponseAcknowledged)
        }
        _ = try session.respond(to: ack(.http, input: input))
    }
    @Test func correctHTTPNonceWithWrongHostCannotSatisfyForwarding() throws {
        let input = plan(), session = try BrowserRouteProbe.Session(plan: input, wallSeconds: { 1000 })
        let target = try begin(session)
        for host in ["foreign.example.test", "", "owned.example.test:81", "user@owned.example.test", "owned.example.test/other"] {
            session.observeForwardedHTTP(request(target, host: host), destination: try input.destination(.http))
            #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: ack(.http, input: input)) }
        }
        session.observeForwardedHTTP(request(target, host: "owned.example.test"), destination: try input.destination(.http))
        _ = try session.respond(to: ack(.http, input: input))
    }
    @Test func deadlineCrossedDuringReceiptValidationRefusesCommit() throws {
        let input = plan(), clock = Clock()
        let session = try BrowserRouteProbe.Session(plan: input, uptime: { clock.now() }, wallSeconds: { clock.advance(30); return 1000 })
        let target = try begin(session)
        session.observeForwardedHTTP(request(target, host: "owned.example.test"), destination: try input.destination(.http))
        #expect(throws: BrowserRouteProbe.Failure.expired) { try session.respond(to: ack(.http, input: input)) }
        #expect(!session.snapshot().httpResponseAcknowledged)
    }
    @Test func activationEntryAndCancellationAreOneShot() throws {
        let session = try BrowserRouteProbe.Session(plan: plan(), wallSeconds: { 1000 })
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: request(BrowserRouteProbe.Session.entryPath)) }
        _ = try begin(session)
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.activate(port: 1234) }
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: request(BrowserRouteProbe.Session.entryPath)) }
        session.cancel()
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: request(BrowserRouteProbe.Session.entryPath)) }
        #expect(session.snapshot().status == .cancelled)
    }
    @Test func monotonicDeadlineDoesNotDependOnWallClockOrBadCallback() throws {
        let clock = Clock(), input = plan(), session = try BrowserRouteProbe.Session(plan: input, uptime: { clock.now() }, wallSeconds: { 1000 })
        let target = try begin(session)
        session.observeForwardedHTTP(request(target, host: "owned.example.test"), destination: try input.destination(.http))
        clock.advance(30)
        #expect(throws: BrowserRouteProbe.Failure.expired) { try session.respond(to: ack(.http, input: input)) }
        #expect(session.snapshot().status == .expired)
        #expect(!session.snapshot().httpResponseAcknowledged)
    }
    @Test func completedEvidenceExpiresWithoutAnotherRequestWhileHistoricalACKsRemain() throws {
        let clock = Clock(), input = plan(), session = try BrowserRouteProbe.Session(plan: input, uptime: { clock.now() }, wallSeconds: { 1000 })
        let target = try begin(session)
        session.observeForwardedHTTP(request(target, host: "owned.example.test"), destination: try input.destination(.http))
        _ = try session.respond(to: ack(.http, input: input))
        session.observeTunnel(try input.destination(.https)); _ = try session.respond(to: ack(.https, input: input))
        #expect(session.snapshot().status == .complete)
        clock.advance(30)
        let expired = session.snapshot()
        #expect(expired.status == .expired)
        #expect(expired.httpResponseAcknowledged && expired.httpsResponseAcknowledged)
    }
    @Test func wrongDestinationAndPartialHTTPNeverCountAsForwarded() throws {
        let input = plan(), session = try BrowserRouteProbe.Session(plan: input, wallSeconds: { 1000 })
        let target = try begin(session)
        session.observeForwardedHTTP(request(target, host: "owned.example.test"), destination: try .init(host: "other.example.test", port: 80))
        session.observeForwardedHTTP(request("/other", host: "owned.example.test"), destination: try input.destination(.http))
        session.observeForwardedHTTP(request(target, host: "owned.example.test").dropLast(), destination: try input.destination(.http))
        #expect(throws: BrowserRouteProbe.Failure.wrongPhase) { try session.respond(to: ack(.http, input: input)) }
    }
    @Test func unsafeEndpointProtocolsCredentialsQueriesAndUnboundedPlansAreRejected() throws {
        for url in ["https://owned.example.test/check", "http://user:pass@owned.example.test/check", "http://owned.example.test/check?secret=x", "http://owned.example.test/check#x", "http://owned.example.test/a/../check", "http://owned.example.test/%2e/check"] {
            #expect(throws: (any Error).self) { try plan(http: url).validate() }
        }
        for value in [9, 121] { #expect(throws: BrowserRouteProbe.Failure.invalidPlan) { try plan(lifetime: value).validate() } }
        let input = plan()
        #expect(throws: BrowserRouteProbe.Failure.invalidPlan) {
            try BrowserRouteProbe.Plan(httpEndpoint: input.httpEndpoint, httpsEndpoint: input.httpsEndpoint,
                verificationKey: input.verificationKey, httpNonce: input.httpNonce, httpsNonce: input.httpNonce, lifetimeSeconds: 30).validate()
        }
        try input.validate()
        #expect(String(describing: input) == "BrowserRouteProbePlan(<redacted>)")
        #expect(Mirror(reflecting: input).children.isEmpty)
        let snapshot = try BrowserRouteProbe.Session(plan: input).snapshot()
        let export = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for secret in [input.httpNonce, input.httpsNonce, "owned.example.test", input.verificationKey.base64EncodedString()] { #expect(!export.contains(secret)) }
    }
    @Test func HTTPFramingRefusesSmugglingBodiesAbsoluteURLsAndDuplicateHeaders() throws {
        #expect(try BrowserRouteProbe.HTTP.target(request("/valid")) == "/valid")
        #expect(try BrowserRouteProbe.HTTP.target(request("/valid").dropLast()) == nil)
        for bytes in [request("/valid", extra: "Content-Length: 0\r\n"), request("/valid", extra: "Transfer-Encoding: chunked\r\n"),
                      request("/valid", extra: "Host: foreign\r\n"), request("//foreign/check"), request("http://foreign/check"),
                      request("/valid") + Data("GET /other HTTP/1.1\r\n\r\n".utf8), Data(repeating: 97, count: 4097)] {
            #expect(throws: BrowserRouteProbe.Failure.invalidRequest) { try BrowserRouteProbe.HTTP.target(bytes) }
        }
    }
    @Test func virtualDestinationIsExactPortAndIPv4LoopbackOnly() throws {
        let session = try BrowserRouteProbe.Session(plan: plan())
        #expect(!session.isVirtual(try .init(host: "127.0.0.1", port: 1234)))
        try session.activate(port: 1234)
        #expect(session.isVirtual(try .init(host: "127.0.0.1", port: 1234)))
        for host in ["localhost", "::1", "127.0.0.2"] { #expect(!session.isVirtual(try .init(host: host, port: 1234))) }
        #expect(!session.isVirtual(try .init(host: "127.0.0.1", port: 1235)))
        #expect(!session.matchesHTTP(try plan().destination(.https)))
    }
    @Test func launchTargetResolvesOnlyActualRelayPortAndPreservesOrdinaryTargets() throws {
        let target = BrowserUserLaunchTarget.routeProbe(plan())
        #expect(target.startURLOverride == nil)
        #expect(try target.startURLOverride(relayPort: 54321)?.absoluteString == "http://127.0.0.1:54321/__neantik_route/start")
        #expect(throws: BrowserRouteProbe.Failure.invalidPlan) { try target.startURLOverride(relayPort: 0) }
        #expect(try BrowserUserLaunchTarget.profileStart.startURLOverride(relayPort: 54321) == nil)
        #expect(try BrowserUserLaunchTarget.extensions.startURLOverride(relayPort: 54321)?.absoluteString == "about:blank")
    }
    @MainActor @Test func managerRefusesDiagnosticDirectAndAnonymousProxyBeforeLaunchingAnything() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-route-target-" + UUID().uuidString)
        let paths = AppPaths(rootDirectory: root)
        let manager = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent })
        defer { manager.suspendPassiveObservations(); try? FileManager.default.removeItem(at: root) }
        let runtime = BrowserRuntime(name: "Own fixture", executableURL: URL(fileURLWithPath: "/usr/bin/true"), source: "Synthetic")
        let keychain = KeychainStore(backend: DevelopmentFixtureKeychain(), service: "own-route-test", legacyService: nil)
        let direct = BrowserProfile(name: "Own direct", startURL: "https://owned.example.test/start")
        var anonymous = direct
        anonymous.proxy = ProxyConfiguration(kind: .http, host: "127.0.0.1", port: 1234, username: "")
        for profile in [direct, anonymous] {
            do {
                try await manager.launchUserProfile(profile: profile, runtime: runtime, preparationReceipt: nil, keychain: keychain, target: .routeProbe(plan()))
                Issue.record("Diagnostic silently launched without authenticated relay")
            } catch {
                #expect(error.localizedDescription.contains("только для прокси с авторизацией"))
            }
            #expect(!manager.runningProfileIDs.contains(profile.id))
            #expect(!FileManager.default.fileExists(atPath: paths.lockFile(for: profile.id).path))
            #expect(profile.startURL == "https://owned.example.test/start")
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_ROUTE_PROBE_LIVE"] == "1"))
    func realAdmittedSOCKSLocalEntryWorksWithoutOpeningUnreachableUpstream() async throws {
        let session = try BrowserRouteProbe.Session(plan: plan())
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: .init(host: "127.0.0.1", port: 1),
            credentials: .init(username: "own-test", password: "own-test"), routeProbe: session, admit: { peer in
                guard let identity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()) else { return false }
                if case .matched(let e) = ProxyRelaySocketOwnerInspector.inspect(processID: getpid(), expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort) {
                    return ProxyRelaySocketOwnerInspector.revalidate(e, expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort)
                }
                return false
            })
        let port = try await relay.start(); try session.activate(port: port)
        let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        let early = try await client.establish(destination: .init(host: "127.0.0.1", port: Int(port)), credentials: nil, authorizeCredentials: { false })
        #expect(early.isEmpty)
        try await client.send(request(BrowserRouteProbe.Session.entryPath, host: "127.0.0.1:\(port)"))
        var result = Data(), eof = false
        while !eof { let r = try await client.receive(timeout: 3); result.append(r.data); eof = r.endOfStream }
        #expect(String(decoding: result, as: UTF8.self).hasPrefix("HTTP/1.1 303 See Other"))
        #expect(relay.activitySnapshot().upstreamTunnels == 0)
        #expect(session.snapshot().status == .waitingHTTP)
        await relay.stop(); #expect(await relay.activeConnectionCount() == 0)
        #expect(session.snapshot().status == .cancelled)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_ROUTE_PROBE_LIVE"] == "1"), arguments: ["badReceipt", "wrongHost"])
    func realAdmittedInvalidCallbackHasAccurateFailureAndNoUpstream(scenario: String) async throws {
        let session = try BrowserRouteProbe.Session(plan: plan())
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: .init(host: "127.0.0.1", port: 1),
            credentials: .init(username: "own-test", password: "own-test"), routeProbe: session, admit: { peer in
                guard let identity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()) else { return false }
                if case .matched(let e) = ProxyRelaySocketOwnerInspector.inspect(processID: getpid(), expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort) {
                    return ProxyRelaySocketOwnerInspector.revalidate(e, expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort)
                }; return false
            })
        let port = try await relay.start(); try session.activate(port: port)
        let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        _ = try await client.establish(destination: .init(host: "127.0.0.1", port: Int(port)), credentials: nil, authorizeCredentials: { false })
        let target = scenario == "wrongHost" ? BrowserRouteProbe.Session.entryPath : BrowserRouteProbe.Session.callbackPath + "?r=e30&s=AAAA"
        try await client.send(request(target, host: scenario == "wrongHost" ? "foreign.example.test" : "127.0.0.1:\(port)"))
        do { let response = try await client.receive(timeout: 3); #expect(response.data.isEmpty) } catch {}
        await relay.stop()
        let activity = relay.activitySnapshot()
        #expect(activity.upstreamTunnels == 0)
        #expect(activity.lastFailure == .clientNegotiationFailed)
        #expect(!session.snapshot().httpResponseAcknowledged && !session.snapshot().httpsResponseAcknowledged)
        #expect(await relay.activeConnectionCount() == 0)
    }

}
