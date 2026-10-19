import Foundation
import Network
import Testing
@testable import NeAntik

/// Own loopback echo endpoint. It records only counts, not traffic or addresses.
private final class WebKitBrokerEcho: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "app.neantik.tests.broker-echo")
    private var accepted = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var finish: ((Result<UInt16, Error>) -> Void)?
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)
        listener = try NWListener(using: parameters)
    }
    var acceptedCount: Int { queue.sync { accepted } }
    func cancel() {
        queue.async {
            self.listener.stateUpdateHandler = nil; self.listener.newConnectionHandler = nil; self.listener.cancel()
            self.tasks.values.forEach { $0.cancel() }
        }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finish = { continuation.resume(with: $0) }
                self.listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        let finish = self.finish; self.finish = nil
                        if let port = listener.port?.rawValue { finish?(.success(port)) }
                        else { finish?(.failure(WebKitLoopbackBroker.Failure.unavailable)) }
                    case .failed, .cancelled:
                        let finish = self.finish; self.finish = nil; finish?(.failure(WebKitLoopbackBroker.Failure.unavailable))
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [self] connection in
                    accepted += 1
                    let front = ProxyRelayUpstreamTransport(accepted: connection), id = UUID()
                    tasks[id] = Task.detached { [self] in
                        defer { front.cancel(); queue.async { self.tasks.removeValue(forKey: id) } }
                        try? await withTaskCancellationHandler {
                            try await front.open(timeout: 2)
                            while true {
                                let chunk = try await front.receive(timeout: 3)
                                if !chunk.data.isEmpty { try await front.send(chunk.data) }
                                if chunk.endOfStream { try await front.finishWrite(); break }
                            }
                        } onCancel: { front.cancel() }
                    }
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    if let finish = self.finish { self.finish = nil; self.listener.cancel(); finish(.failure(WebKitLoopbackBroker.Failure.unavailable)) }
                }
            }
        }
    }
    func stop() async {
        let pending: [Task<Void, Never>] = await withCheckedContinuation { continuation in
            queue.async {
                self.listener.stateUpdateHandler = nil; self.listener.newConnectionHandler = nil; self.listener.cancel()
                let pending = Array(self.tasks.values); pending.forEach { $0.cancel() }; continuation.resume(returning: pending)
            }
        }
        for task in pending { await task.value }
    }
}

@Suite(.serialized)
struct WebKitLoopbackBrokerTests {
    private func scope() -> WebKitRelayAuthority.Scope {
        let profile = UUID(); return .init(profileID: profile, storeID: profile, sessionID: UUID(), revision: 1)
    }
    private func credentials(_ capability: WebKitRelayAuthority.Capability) throws -> ProxyRelayCredentials {
        try capability.withCredentials { try .init(username: $0, password: $1) }
    }
    private func client(_ port: UInt16) throws -> ProxyRelayUpstreamTransport {
        try .init(kind: .http, upstream: .init(host: "127.0.0.1", port: Int(port)))
    }
    private func echo(_ client: ProxyRelayUpstreamTransport, marker: String) async throws {
        let bytes = Data(marker.utf8)
        try await client.send(bytes, timeout: 2)
        var received = Data()
        while received.count < bytes.count {
            let chunk = try await client.receive(timeout: 2)
            try #require(!chunk.data.isEmpty); received.append(chunk.data)
        }
        #expect(received == bytes)
    }
    @Test func independentProfilesAndRevocationUseRealSockets() async throws {
        let origin = try WebKitBrokerEcho(), originPort = try await origin.start()
        defer { origin.cancel() }
        let destination = try ProxyRelayDestination(host: "127.0.0.1", port: Int(originPort))
        let broker = try WebKitLoopbackBroker(qualificationPort: .any), port = try await broker.start()
        defer { broker.cancel() }
        let a = scope(), b = scope()
        try broker.register(scope: a, route: .direct); try broker.register(scope: b, route: .direct)
        let ca = try broker.issue(for: a), cb = try broker.issue(for: b)
        let first = try client(port), second = try client(port)
        defer { first.cancel(); second.cancel() }
        _ = try await first.establish(destination: destination, credentials: credentials(ca), timeout: 2, authorizeCredentials: { true })
        _ = try await second.establish(destination: destination, credentials: credentials(cb), timeout: 2, authorizeCredentials: { true })
        try await echo(first, marker: "first"); try await echo(second, marker: "second")
        await broker.revoke(a)
        #expect(await broker.activeConnectionCount() == 1)
        let rejected = try client(port); defer { rejected.cancel() }
        await #expect(throws: (any Error).self) {
            try await rejected.establish(destination: destination, credentials: credentials(ca), timeout: 2, authorizeCredentials: { true })
        }
        try await echo(second, marker: "still-independent")
        #expect(origin.acceptedCount == 2)
        await broker.stop(); #expect(await broker.activeConnectionCount() == 0)
        await origin.stop()
        do {
            let end = try await first.receive(timeout: 1)
            #expect(end.data.isEmpty && end.endOfStream)
        } catch let error as ProxyRelayTransportError {
            #expect(error != .timeout)
        }
    }
    @Test func absentOrForeignCredentialsDoNotDialDestination() async throws {
        let origin = try WebKitBrokerEcho(), originPort = try await origin.start()
        defer { origin.cancel() }
        let broker = try WebKitLoopbackBroker(qualificationPort: .any), port = try await broker.start()
        defer { broker.cancel() }
        let s = scope(); try broker.register(scope: s, route: .direct); _ = try broker.issue(for: s)
        for auth in [nil, try ProxyRelayCredentials(username: "foreign", password: "synthetic")] {
            let connection = try client(port); defer { connection.cancel() }
            await #expect(throws: ProxyRelayWireError.authenticationRejected) {
                try await connection.establish(destination: .init(host: "127.0.0.1", port: Int(originPort)), credentials: auth,
                    timeout: 2, authorizeCredentials: { true })
            }
        }
        #expect(origin.acceptedCount == 0)
        await broker.stop(); await origin.stop()
    }
    @Test func authenticatedUpstreamAndFailureNeverBecomeDirect() async throws {
        let origin = try WebKitBrokerEcho(), originPort = try await origin.start()
        defer { origin.cancel() }
        let upstream = try WebKitLoopbackBroker(qualificationPort: .any), upstreamPort = try await upstream.start()
        let u = scope(); try upstream.register(scope: u, route: .direct)
        let upstreamAuth = try credentials(upstream.issue(for: u))
        let broker = try WebKitLoopbackBroker(qualificationPort: .any), port = try await broker.start()
        defer { broker.cancel(); upstream.cancel() }
        let a = scope(), b = scope()
        try broker.register(scope: a, route: .proxy(kind: .http,
            upstream: .init(host: "127.0.0.1", port: Int(upstreamPort)), credentials: upstreamAuth))
        try broker.register(scope: b, route: .direct)
        let ca = try credentials(broker.issue(for: a)), cb = try credentials(broker.issue(for: b))
        let destination = try ProxyRelayDestination(host: "127.0.0.1", port: Int(originPort))
        let tunneled = try client(port); defer { tunneled.cancel() }
        _ = try await tunneled.establish(destination: destination, credentials: ca, timeout: 2, authorizeCredentials: { true })
        try await echo(tunneled, marker: "upstream-proof")
        await upstream.stop()
        let failed = try client(port); defer { failed.cancel() }
        await #expect(throws: (any Error).self) {
            try await failed.establish(destination: destination, credentials: ca, timeout: 2, authorizeCredentials: { true })
        }
        #expect(origin.acceptedCount == 1)
        let direct = try client(port); defer { direct.cancel() }
        _ = try await direct.establish(destination: destination, credentials: cb, timeout: 2, authorizeCredentials: { true })
        try await echo(direct, marker: "explicit-direct-only")
        #expect(origin.acceptedCount == 2)
        await broker.stop(); #expect(await broker.activeConnectionCount() == 0); await origin.stop()
    }
    @Test func occupiedEndpointAndStoppedBrokerFailClosed() async throws {
        let first = try WebKitLoopbackBroker(qualificationPort: .any), port = try await first.start()
        defer { first.cancel() }
        let second = try WebKitLoopbackBroker(qualificationPort: NWEndpoint.Port(rawValue: port)!)
        await #expect(throws: (any Error).self) { try await second.start() }
        await second.stop(); await first.stop()
        #expect(throws: WebKitLoopbackBroker.Failure.state) { try first.register(scope: scope(), route: .direct) }
        await #expect(throws: WebKitLoopbackBroker.Failure.state) { try await first.start() }
    }
    @Test func oneProfileCannotConsumeAnotherProfilesConnectionBudget() async throws {
        let origin = try WebKitBrokerEcho(), originPort = try await origin.start()
        defer { origin.cancel() }
        let broker = try WebKitLoopbackBroker(qualificationPort: .any), port = try await broker.start()
        defer { broker.cancel() }
        let a = scope(), b = scope()
        try broker.register(scope: a, route: .direct); try broker.register(scope: b, route: .direct)
        let ca = try credentials(broker.issue(for: a)), cb = try credentials(broker.issue(for: b))
        let destination = try ProxyRelayDestination(host: "127.0.0.1", port: Int(originPort))
        var clients: [ProxyRelayUpstreamTransport] = []
        defer { clients.forEach { $0.cancel() } }
        for _ in 0..<WebKitLoopbackBroker.maximumConnectionsPerProfile {
            let connection = try client(port); clients.append(connection)
            _ = try await connection.establish(destination: destination, credentials: ca, timeout: 2, authorizeCredentials: { true })
        }
        let excess = try client(port); clients.append(excess)
        await #expect(throws: (any Error).self) {
            try await excess.establish(destination: destination, credentials: ca, timeout: 2, authorizeCredentials: { true })
        }
        #expect(origin.acceptedCount == WebKitLoopbackBroker.maximumConnectionsPerProfile)
        let independent = try client(port); clients.append(independent)
        _ = try await independent.establish(destination: destination, credentials: cb, timeout: 2, authorizeCredentials: { true })
        try await echo(independent, marker: "separate-budget")
        await broker.revoke(a)
        #expect(await broker.activeConnectionCount() == 1)
        try await echo(independent, marker: "survives-revoke")
        await broker.stop(); #expect(await broker.activeConnectionCount() == 0); await origin.stop()
    }
}
