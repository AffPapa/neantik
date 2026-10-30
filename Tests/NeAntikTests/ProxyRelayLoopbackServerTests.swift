import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayLoopbackServerTests {
    private final class AdmissionCounter: @unchecked Sendable {
        let lock = NSLock(); var value = 0
        func admit() -> Bool { lock.lock(); defer { lock.unlock() }; value += 1; return value == 1 }
        func admitBeforeNegotiation() -> Bool { lock.lock(); defer { lock.unlock() }; value += 1; return value <= 2 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    private func backend(_ scenario: String) throws -> ProxyRelayDestination {
        let env = ProcessInfo.processInfo.environment
        let text = try #require(env["NEANTIK_RELAY_LISTENER_PORTS"])
        let ports = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Int])
        return try .init(host: "127.0.0.1", port: try #require(ports[scenario]))
    }
    private var credentials: ProxyRelayCredentials { get throws { try .init(username: "fixture-user", password: "fixture-password") } }
    private var destination: ProxyRelayDestination { get throws { try .init(host: "owned.example.test", port: 443) } }
    private static func ownProcessAdmission(_ peer: ProxyRelayLoopbackServer.Peer) -> Bool {
        guard let identity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()) else { return false }
        if case .matched(let evidence) = ProxyRelaySocketOwnerInspector.inspect(processID: getpid(), expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort) {
            return ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort)
        }
        return false
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_LISTENER_FIXTURE"] == "1"), arguments: ["socks", "http"])
    func realLocalSOCKSFrontRoutesThroughAuthenticatedUpstream(scenario: String) async throws {
        let relay = try ProxyRelayLoopbackServer(upstreamKind: scenario == "socks" ? .socks5 : .http, upstream: backend(scenario), credentials: credentials, admit: { Self.ownProcessAdmission($0) })
        let port = try await relay.start()
        let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        var proof = try await client.establish(destination: destination, credentials: nil, timeout: 3, authorizeCredentials: { false })
        while proof.count < 13 {
            let chunk = try await client.receive(timeout: 3)
            try #require(!chunk.data.isEmpty, "Upstream proof truncated")
            proof.append(chunk.data)
        }
        #expect(proof == Data("fixture-proof".utf8))
        try await client.send(Data("fixture-ping".utf8)); try await client.finishWrite()
        var response = Data(); var eof = false
        while !eof { let chunk = try await client.receive(timeout: 3); response.append(chunk.data); eof = chunk.endOfStream }
        #expect(response == Data("fixture-pong".utf8))
        await relay.stop(); #expect(await relay.activeConnectionCount() == 0)
        print("OWNED_RELAY_LISTENER_PROOF {\"scenario\":\"\(scenario)\",\"payloadAndEOFVerified\":true,\"kernelPeerAdmissionVerified\":true,\"cleanupVerified\":true,\"productionRelayEnabled\":false}")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_LISTENER_FIXTURE"] == "1"), arguments: ["deny", "revoked"])
    func unapprovedAndRevokedPeersNeverAuthenticateToUpstream(scenario: String) async throws {
        let counter = AdmissionCounter()
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: backend(scenario), credentials: credentials, admit: { _ in scenario == "revoked" ? counter.admit() : false })
        let port = try await relay.start(); let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        do { _ = try await client.establish(destination: destination, credentials: nil, timeout: 3, authorizeCredentials: { false }); Issue.record("Unapproved relay established tunnel") } catch {}
        await relay.stop(); #expect(await relay.activeConnectionCount() == 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_LISTENER_FIXTURE"] == "1"))
    func revocationDuringUpstreamNegotiationCannotSendCredentials() async throws {
        let counter = AdmissionCounter()
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .socks5, upstream: backend("revoked-negotiation"), credentials: credentials,
                                                admit: { _ in counter.admitBeforeNegotiation() })
        let port = try await relay.start()
        let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        do { _ = try await client.establish(destination: destination, credentials: nil, timeout: 3, authorizeCredentials: { false }); Issue.record("Revoked negotiation established tunnel") } catch {}
        await relay.stop(); #expect(await relay.activeConnectionCount() == 0); #expect(counter.count == 3)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_LISTENER_FIXTURE"] == "1"))
    func persistentIdleSessionSurvivesFormerSixtySecondBudget() async throws {
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: backend("idle"), credentials: credentials,
                                                admit: { Self.ownProcessAdmission($0) })
        let port = try await relay.start()
        let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        var proof = try await client.establish(destination: destination, credentials: nil, timeout: 3, authorizeCredentials: { false })
        while proof.count < 13 { let chunk = try await client.receive(timeout: 3); try #require(!chunk.data.isEmpty); proof.append(chunk.data) }
        try #require(proof == Data("fixture-proof".utf8))
        try await client.send(Data("fixture-ping".utf8)); try await client.finishWrite()
        let started = ContinuousClock.now
        var response = Data(), eof = false
        while !eof { let chunk = try await client.receive(timeout: nil); response.append(chunk.data); eof = chunk.endOfStream }
        let elapsed = started.duration(to: .now).components
        try #require(elapsed.seconds >= 61)
        try #require(response == Data("fixture-pong".utf8))
        await relay.stop(); try #require(await relay.activeConnectionCount() == 0)
        print("OWNED_RELAY_IDLE_PROOF {\"elapsedWholeSeconds\":\(elapsed.seconds),\"payloadAndEOFVerified\":true,\"cleanupVerified\":true,\"productionRelayEnabled\":false}")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_LISTENER_FIXTURE"] == "1"))
    func stoppingAnActiveRelayCancelsBothDirectionsAndListener() async throws {
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: backend("stop"), credentials: credentials, admit: { Self.ownProcessAdmission($0) })
        let port = try await relay.start(); let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        _ = try await client.establish(destination: destination, credentials: nil, timeout: 3, authorizeCredentials: { false })
        let started = ContinuousClock.now; await relay.stop()
        #expect(started.duration(to: .now) < .seconds(2)); #expect(await relay.activeConnectionCount() == 0)
        let rejected = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { rejected.cancel() }
        do { try await rejected.open(timeout: 1); Issue.record("Stopped listener accepted new stream") } catch {}
    }
    @Test func invalidConnectionLimitCannotStartListener() throws {
        for limit in [0, 65] { #expect(throws: ProxyRelayLoopbackServer.Failure.invalidLimit) { try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: .init(host: "127.0.0.1", port: 1), credentials: nil, maximumConnections: limit, admit: { _ in false }) } }
    }
}
