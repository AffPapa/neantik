import Darwin
import Foundation
import Testing
@testable import NeAntik

/// Real localhost transport controls; the test process is admitted by its
/// exact kernel socket. This does not qualify signed Chromium ownership.
@Suite(.serialized)
struct ProxyRelayActivityIntegrationTests {
    private static func admit(_ peer: ProxyRelayLoopbackServer.Peer) -> Bool {
        guard let identity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()) else { return false }
        if case .matched(let evidence) = ProxyRelaySocketOwnerInspector.inspect(processID: getpid(), expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort) {
            return ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort)
        }
        return false
    }
    private func upstream(_ scenario: String) throws -> ProxyRelayDestination {
        let text = try #require(ProcessInfo.processInfo.environment["NEANTIK_RELAY_ACTIVITY_PORTS"])
        let ports = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Int])
        return try .init(host: "127.0.0.1", port: try #require(ports[scenario]))
    }
    private func settled(_ relay: ProxyRelayLoopbackServer, outcome: BrowserRelayActivity.End) async throws -> BrowserRelayActivity.Snapshot {
        for _ in 0..<200 {
            let snapshot = relay.activitySnapshot()
            if snapshot.lastEnd == outcome && snapshot.activeConnections == 0 { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Transport ledger did not reach the expected terminal outcome")
        return relay.activitySnapshot()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_ACTIVITY_FIXTURE"] == "1"),
          arguments: ["completed", "upstreamRejected", "reset", "cancelled", "denied"])
    func recordsActualTransportEvents(scenario: String) async throws {
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: upstream(scenario), credentials: nil,
                                               admit: { scenario != "denied" && Self.admit($0) })
        let port = try await relay.start()
        let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        let destination = try ProxyRelayDestination(host: "fixture.example.test", port: 443)
        if scenario == "denied" || scenario == "upstreamRejected" {
            do {
                _ = try await client.establish(destination: destination, credentials: nil, timeout: 3, authorizeCredentials: { false })
                Issue.record("Negative transport control unexpectedly established a tunnel")
            } catch {}
            if scenario == "upstreamRejected" {
                let snapshot = try await settled(relay, outcome: .upstreamNegotiationFailed)
                #expect(snapshot.admittedConnections == 1 && snapshot.upstreamTunnels == 0 && snapshot.successRepliesSent == 0)
                #expect(snapshot.failedConnections == 1 && snapshot.lastFailure == .upstreamNegotiationFailed)
            }
            await relay.stop()
            if scenario == "denied" {
                let snapshot = relay.activitySnapshot()
                #expect(snapshot.admittedConnections == 0 && snapshot.failedConnections == 0 && snapshot.upstreamTunnels == 0)
            }
        } else {
            var proof = try await client.establish(destination: destination, credentials: nil, timeout: 3, authorizeCredentials: { false })
            while proof.count < 13 {
                let chunk = try await client.receive(timeout: 3)
                try #require(!chunk.data.isEmpty); proof.append(chunk.data)
            }
            try #require(proof == Data("fixture-proof".utf8))
            let open = relay.activitySnapshot()
            #expect(open.admittedConnections == 1 && open.upstreamTunnels == 1 && open.successRepliesSent == 1)
            #expect(open.activeConnections == 1 && open.completedConnections == 0 && open.failedConnections == 0)
            if scenario == "cancelled" {
                await relay.stop()
                let snapshot = relay.activitySnapshot()
                #expect(snapshot.cancelledConnections == 1 && snapshot.failedConnections == 0 && snapshot.lastFailure == nil)
            } else {
                try await client.send(Data("fixture-ping".utf8)); try await client.finishWrite()
                if scenario == "completed" {
                    var response = Data(), eof = false
                    while !eof { let chunk = try await client.receive(timeout: 3); response.append(chunk.data); eof = chunk.endOfStream }
                    #expect(response == Data("fixture-pong".utf8))
                } else {
                    // Front-side transport may report EOF after the relay
                    // catches upstream RST; the owner's ledger must retain RST.
                    do { _ = try await client.receive(timeout: 3) } catch {}
                }
                let snapshot = try await settled(relay, outcome: scenario == "completed" ? .completed : .streamFailed)
                #expect(snapshot.completedConnections == (scenario == "completed" ? 1 : 0))
                #expect(snapshot.failedConnections == (scenario == "reset" ? 1 : 0))
                #expect(snapshot.cancelledConnections == 0)
                await relay.stop()
            }
        }
        #expect(relay.activitySnapshot().listenerStopped && relay.activitySnapshot().activeConnections == 0)
        #expect(await relay.activeConnectionCount() == 0)
    }
}
