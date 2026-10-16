import Foundation
import Network
import Testing
@testable import NeAntik

struct WebKitProxyConnectCodecTests {
    private func frame(_ authority: String = "owned.example.test:443", extra: String = "") -> Data {
        Data("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\(extra)\r\n".utf8)
    }
    @Test func fragmentedHeaderAndCoalescedPayloadRemainSeparate() throws {
        let input = frame(extra: "Proxy-Authorization: Basic Zml4dHVyZTpvbmx5\r\n")
        for count in 0..<input.count { #expect(try WebKitProxyConnectCodec.request(input.prefix(count)) == nil) }
        let request = try #require(try WebKitProxyConnectCodec.request(input + Data([0,255,1])))
        #expect(request.consumed == input.count)
        #expect(request.destination == (try ProxyRelayDestination(host: "owned.example.test", port: 443)))
        #expect(request.authorization == Data("fixture:only".utf8))
        #expect(String(reflecting: request) == "WebKitProxyRequest(<redacted>)")
        #expect(Mirror(reflecting: request).children.isEmpty)
    }
    @Test func anonymousChallengeIsDistinctFromMalformedRequest() throws {
        #expect(try WebKitProxyConnectCodec.request(frame())?.authorization == nil)
        let input = frame("[::1]:8443", extra: "User-Agent: fixture\r\nProxy-Connection: keep-alive\r\n")
        #expect(try WebKitProxyConnectCodec.request(input)?.destination == (try ProxyRelayDestination(host: "::1", port: 8443)))
    }
    @Test(arguments: [
        "GET / HTTP/1.1\r\nHost: owned.example.test:443\r\n\r\n",
        "CONNECT owned.example.test:443 HTTP/1.1\r\n\r\n",
        "CONNECT owned.example.test:443 HTTP/1.1\r\nHost: other.example.test:443\r\n\r\n",
        "CONNECT owned.example.test:443 HTTP/1.1\r\nHost: owned.example.test:443\r\nHost: owned.example.test:443\r\n\r\n",
        "CONNECT owned.example.test:443 HTTP/1.1\r\nHost : owned.example.test:443\r\n\r\n",
        "CONNECT owned.example.test:443 HTTP/1.1\nHost: owned.example.test:443\r\n\r\n"
    ]) func rejectsAmbiguousGrammar(input: String) {
        #expect(throws: (any Error).self) { try WebKitProxyConnectCodec.request(Data(input.utf8)) }
    }
    @Test(arguments: [
        "Content-Length: 0\r\n", "Transfer-Encoding: chunked\r\n", "Expect: 100-continue\r\n",
        "Authorization: Basic Zml4dHVyZTpvbmx5\r\n", "Proxy-Authorization: Bearer fixture\r\n",
        "Proxy-Authorization: Basic !!!\r\n", "Proxy-Authorization: Basic Zg== Zg==\r\n",
        "Proxy-Authorization: Basic Zg==\r\nproxy-authorization: Basic Zg==\r\n",
        " folded: header\r\n", "Unsafe: value\nvalue\r\n"
    ]) func rejectsCredentialSmugglingAndBodyFraming(extra: String) {
        #expect(throws: (any Error).self) { try WebKitProxyConnectCodec.request(frame(extra: extra)) }
    }
    @Test(arguments: ["owned.example.test:0", "owned.example.test:65536", "owned.example.test:0443",
                      "user@owned.example.test:443", "owned.example.test:443/path", "::1:443"])
    func rejectsInvalidAuthorities(authority: String) {
        #expect(throws: (any Error).self) { try WebKitProxyConnectCodec.request(frame(authority)) }
    }
    @Test func headerLimitIncludesTerminatorButNotTunnelBytes() throws {
        #expect(throws: WebKitProxyConnectCodec.Failure.limit) {
            try WebKitProxyConnectCodec.request(Data(repeating: 65, count: WebKitProxyConnectCodec.maximumHeaderBytes))
        }
        let good = frame()
        #expect(try WebKitProxyConnectCodec.request(good + Data(repeating: 65, count: 9000))?.consumed == good.count)
    }
}

struct WebKitProxySessionTests {
    private func scope() -> WebKitProxySession.Scope {
        let profile = UUID()
        return .init(profileID: profile, storeID: profile, sessionID: UUID(), revision: 1)
    }
    private func session(_ scope: WebKitProxySession.Scope) throws -> WebKitProxySession {
        try .init(scope: scope, upstreamKind: .http,
                  upstream: .init(host: "127.0.0.1", port: 1), credentials: nil)
    }
    @Test func invalidScopeRefusedBeforeListenerConstruction() throws {
        let good = scope()
        for bad in [WebKitProxySession.Scope(profileID: good.profileID, storeID: UUID(), sessionID: good.sessionID, revision: 1),
                    .init(profileID: good.profileID, storeID: good.storeID, sessionID: good.sessionID, revision: 0)] {
            #expect(throws: WebKitProxySession.Failure.scope) { try session(bad) }
        }
    }
    @Test func configurationIsOnceOnlyAndNeverPermitsDirectFailover() async throws {
        let scope = scope(), session = try session(scope)
        defer { session.cancel() }
        #expect(throws: WebKitProxySession.Failure.state) { try session.configuration(for: scope) }
        _ = try await session.start()
        for mismatch in [WebKitProxySession.Scope(profileID: UUID(), storeID: scope.storeID, sessionID: scope.sessionID, revision: 1),
                         .init(profileID: scope.profileID, storeID: UUID(), sessionID: scope.sessionID, revision: 1),
                         .init(profileID: scope.profileID, storeID: scope.storeID, sessionID: UUID(), revision: 1),
                         .init(profileID: scope.profileID, storeID: scope.storeID, sessionID: scope.sessionID, revision: 2)] {
            #expect(throws: WebKitProxySession.Failure.scope) { try session.configuration(for: mismatch) }
        }
        let configuration = try session.configuration(for: scope)
        #expect(!configuration.allowFailover)
        #expect(configuration.matchDomains.isEmpty && configuration.excludedDomains.isEmpty)
        #expect(throws: WebKitProxySession.Failure.state) { try session.configuration(for: scope) }
        #expect(String(reflecting: session) == "WebKitProxySession(<redacted>)")
        #expect(Mirror(reflecting: session).children.isEmpty)
        await session.stop()
        #expect(await session.activeConnectionCount() == 0)
        #expect(throws: WebKitProxySession.Failure.state) { try session.configuration(for: scope) }
        await #expect(throws: WebKitProxySession.Failure.state) { try await session.start() }
    }
    @Test func cancelBeforeStartIsTerminal() async throws {
        let scope = scope(), session = try session(scope)
        await session.stop()
        await #expect(throws: WebKitProxySession.Failure.state) { try await session.start() }
        #expect(throws: WebKitProxySession.Failure.state) { try session.configuration(for: scope) }
        #expect(await session.activeConnectionCount() == 0)
    }
    @Test func missingAndForeignCredentialsCannotEstablishTunnel() async throws {
        let scope = scope(), session = try session(scope)
        let port = try await session.start()
        defer { session.cancel() }
        _ = try session.configuration(for: scope)
        for credentials in [nil, try ProxyRelayCredentials(username: "another-session", password: "fixture-only")] {
            let client = try ProxyRelayUpstreamTransport(kind: .http, upstream: .init(host: "127.0.0.1", port: Int(port)))
            defer { client.cancel() }
            await #expect(throws: ProxyRelayWireError.authenticationRejected) {
                try await client.establish(destination: .init(host: "owned.invalid", port: 443),
                    credentials: credentials, timeout: 2, authorizeCredentials: { true })
            }
        }
        await session.stop()
        #expect(await session.activeConnectionCount() == 0)
        let client = try ProxyRelayUpstreamTransport(kind: .http, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel() }
        await #expect(throws: (any Error).self) { try await client.open(timeout: 1) }
    }
    @Test(arguments: [false, true])
    func listenerCancellationRevokesReadyAndIssuedSession(issueConfiguration: Bool) async throws {
        let scope = scope(), session = try session(scope)
        defer { session.cancel() }
        _ = try await session.start()
        if issueConfiguration { _ = try session.configuration(for: scope) }
        session.cancelListenerForQualification()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !session.isRevokedForQualification(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.isRevokedForQualification())
        #expect(throws: WebKitProxySession.Failure.state) { try session.configuration(for: scope) }
        await session.stop()
        #expect(await session.activeConnectionCount() == 0)
    }
}
