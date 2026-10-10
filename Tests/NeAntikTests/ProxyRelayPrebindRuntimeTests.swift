import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayPrebindRuntimeTests {
    private final class AdmissionCount: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func admit(_ peer: ProxyRelayLoopbackServer.Peer) -> Bool {
            lock.lock(); count += 1; lock.unlock()
            guard let identity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()),
                  case .matched(let evidence) = ProxyRelaySocketOwnerInspector.inspect(processID: getpid(), expected: identity,
                    clientPort: peer.clientPort, relayPort: peer.relayPort)
            else { return false }
            return ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: identity,
                        clientPort: peer.clientPort, relayPort: peer.relayPort)
        }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private func upstream(_ scenario: String) throws -> ProxyRelayDestination {
        let env = ProcessInfo.processInfo.environment
        let ports = try #require(env["NEANTIK_RELAY_PREBIND_PORTS"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(ports.utf8)) as? [String: Int])
        return try .init(host: "127.0.0.1", port: try #require(object[scenario]))
    }
    private func awaitPending(_ gate: ProxyRelayBindingGate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await gate.pendingCount() == 0 {
            try #require(ContinuousClock.now < deadline, "Listener did not enter pre-bind state")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_PREBIND_FIXTURE"] == "1"))
    func initialConnectionIsHeldThenAuthenticatesOnlyAfterBinding() async throws {
        let gate = try ProxyRelayBindingGate(), admissions = AdmissionCount()
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: upstream("held"),
            credentials: .init(username: "fixture-user", password: "fixture-password"),
            waitForBinding: { try await gate.wait() }, admit: { admissions.admit($0) })
        let port = try await relay.start(), destination = try ProxyRelayDestination(host: "owned.example.test", port: 443)
        let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        let tunnel = Task { try await client.establish(destination: destination, credentials: nil, timeout: 4, authorizeCredentials: { false }) }
        try await awaitPending(gate); #expect(admissions.value == 0)
        try await gate.open()
        var proof = try await tunnel.value
        while proof.count < 13 { let chunk = try await client.receive(timeout: 2); try #require(!chunk.data.isEmpty); proof.append(chunk.data) }
        #expect(proof == Data("fixture-proof".utf8)); #expect(admissions.value >= 3)
        try await client.send(Data("fixture-ping".utf8)); try await client.finishWrite()
        var response = Data(), eof = false
        while !eof { let chunk = try await client.receive(timeout: 2); response.append(chunk.data); eof = chunk.endOfStream }
        #expect(response == Data("fixture-pong".utf8))
        await relay.stop(); #expect(await relay.activeConnectionCount() == 0)
        print("OWNED_RELAY_PREBIND_SUCCESS {\"heldBeforeAdmission\":true,\"authenticatedAfterBinding\":true,\"payloadAndEOFVerified\":true,\"cleanupVerified\":true}")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_PREBIND_FIXTURE"] == "1"))
    func failedLaunchCancelsHeldConnectionWithoutUpstreamAuthentication() async throws {
        let gate = try ProxyRelayBindingGate(), admissions = AdmissionCount()
        let relay = try ProxyRelayLoopbackServer(upstreamKind: .http, upstream: upstream("failed"),
            credentials: .init(username: "fixture-user", password: "fixture-password"),
            waitForBinding: { try await gate.wait() }, admit: { admissions.admit($0) })
        let port = try await relay.start()
        let client = try ProxyRelayUpstreamTransport(kind: .socks5, upstream: .init(host: "127.0.0.1", port: Int(port)))
        defer { client.cancel(); relay.cancel() }
        let tunnel = Task { try await client.establish(destination: .init(host: "owned.example.test", port: 443), credentials: nil, timeout: 3, authorizeCredentials: { false }) }
        try await awaitPending(gate); await gate.close()
        let started = ContinuousClock.now; await relay.stop()
        #expect(started.duration(to: .now) < .seconds(1))
        do { _ = try await tunnel.value; Issue.record("Failed launch opened tunnel") } catch {}
        #expect(admissions.value == 0); #expect(await relay.activeConnectionCount() == 0)
        #expect(await gate.pendingCount() == 0)
        print("OWNED_RELAY_PREBIND_FAILURE {\"zeroAdmissions\":true,\"cleanupVerified\":true}")
    }
}
