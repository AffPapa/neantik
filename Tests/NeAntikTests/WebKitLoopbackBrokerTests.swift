import Foundation
import Network
import Testing
@testable import NeAntik

private final class WebKitBrokerAttestationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var released = false
    private var validationBlocked = false

    func arm() {
        condition.lock(); armed = true; condition.unlock()
    }

    func validate() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard armed else { return true }
        validationBlocked = true; condition.broadcast()
        while !released { condition.wait() }
        return true
    }

    func waitUntilBlocked(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock(); defer { condition.unlock() }
        while !validationBlocked {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }

    static func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

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
    @Test func startupFailurePreservesOnlySanitizedNetworkDomainAndCode() {
        let addressInUse = POSIXErrorCode(rawValue: 48)!
        let failure = WebKitLoopbackBroker.listenerStartFailure(.posix(addressInUse))
        #expect(failure.errorDescription == "Не удалось запустить локальный WebKit-маршрут (POSIX-48). Профиль не запущен.")
        #expect(!failure.localizedDescription.contains("127.0.0.1"))
    }

    @Test func listenerStartupTimeoutHasDistinctUserMessage() {
        let failure = WebKitLoopbackBroker.Failure.listenerStartTimedOut
        #expect(failure.errorDescription == "Локальный WebKit-маршрут не запустился вовремя. Профиль не запущен.")
    }

    @Test func productionLoopbackEndpointCanStartAndStop() async throws {
        let broker = try WebKitLoopbackBroker(qualificationPort: NWEndpoint.Port(rawValue: WebKitLoopbackBroker.sandboxPort)!)
        let port = try await broker.start()
        await broker.stop()
        #expect(port == WebKitLoopbackBroker.sandboxPort)
    }

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
        let ca = try broker.registerForTesting(scope: a, route: .direct)
        let cb = try broker.registerForTesting(scope: b, route: .direct)
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
        let s = scope(); _ = try broker.registerForTesting(scope: s, route: .direct)
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
    @Test func preparedCapabilityCannotRouteUntilNetworkProcessLeaseActivates() async throws {
        let origin = try WebKitBrokerEcho(), originPort = try await origin.start()
        defer { origin.cancel() }
        let broker = try WebKitLoopbackBroker(qualificationPort: .any), port = try await broker.start()
        defer { broker.cancel() }
        let scope = scope()
        let capability = try broker.prepare(scope: scope, route: .direct)
        let destination = try ProxyRelayDestination(host: "127.0.0.1", port: Int(originPort))

        let beforeOwner = try client(port); defer { beforeOwner.cancel() }
        await #expect(throws: (any Error).self) {
            try await beforeOwner.establish(destination: destination,
                credentials: credentials(capability), timeout: 2,
                authorizeCredentials: { true })
        }
        #expect(origin.acceptedCount == 0)

        try broker.activateForTesting(scope: scope, isCurrent: { true })
        let afterOwner = try client(port); defer { afterOwner.cancel() }
        _ = try await afterOwner.establish(destination: destination,
            credentials: credentials(capability), timeout: 2,
            authorizeCredentials: { true })
        try await echo(afterOwner, marker: "activated-only")
        #expect(origin.acceptedCount == 1)
        await broker.revoke(scope)
        await broker.stop(); await origin.stop()
    }
    @Test func authenticatedUpstreamAndFailureNeverBecomeDirect() async throws {
        let origin = try WebKitBrokerEcho(), originPort = try await origin.start()
        defer { origin.cancel() }
        let upstream = try WebKitLoopbackBroker(qualificationPort: .any), upstreamPort = try await upstream.start()
        let u = scope(); let upstreamCapability = try upstream.registerForTesting(scope: u, route: .direct)
        let upstreamAuth = try credentials(upstreamCapability)
        let broker = try WebKitLoopbackBroker(qualificationPort: .any), port = try await broker.start()
        defer { broker.cancel(); upstream.cancel() }
        let a = scope(), b = scope()
        let ca = try broker.registerForTesting(scope: a, route: .proxy(kind: .http,
            upstream: .init(host: "127.0.0.1", port: Int(upstreamPort)), credentials: upstreamAuth))
        let cb = try broker.registerForTesting(scope: b, route: .direct)
        let credentialsA = try credentials(ca), credentialsB = try credentials(cb)
        let destination = try ProxyRelayDestination(host: "127.0.0.1", port: Int(originPort))
        let tunneled = try client(port); defer { tunneled.cancel() }
        _ = try await tunneled.establish(destination: destination, credentials: credentialsA, timeout: 2, authorizeCredentials: { true })
        try await echo(tunneled, marker: "upstream-proof")
        await upstream.stop()
        let failed = try client(port); defer { failed.cancel() }
        await #expect(throws: (any Error).self) {
            try await failed.establish(destination: destination, credentials: credentialsA, timeout: 2, authorizeCredentials: { true })
        }
        #expect(origin.acceptedCount == 1)
        let direct = try client(port); defer { direct.cancel() }
        _ = try await direct.establish(destination: destination, credentials: credentialsB, timeout: 2, authorizeCredentials: { true })
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
        #expect(throws: WebKitLoopbackBroker.Failure.state) { try first.registerForTesting(scope: scope(), route: .direct) }
        await #expect(throws: WebKitLoopbackBroker.Failure.state) { try await first.start() }
    }
    @Test func slowLiveAttestationDoesNotHoldBrokerQueueOrIssueAfterStop() async throws {
        let scope = scope()
        let session = WebKitHostIPC.Session(
            profileID: scope.profileID, revision: scope.revision,
            generation: scope.sessionID, dataRoot: "/tmp/neantik-broker-attestation-qa",
            runtimeSHA256: String(repeating: "d", count: 64))
        let gate = WebKitBrokerAttestationGate()
        let lease = WebKitNetworkProcessCodeIdentity.Lease.fixture(session: session) {
            gate.validate()
        }
        let broker = try WebKitLoopbackBroker(qualificationPort: .any)
        _ = try await broker.start()
        _ = try broker.prepare(scope: scope, route: .direct)
        gate.arm()

        let issuance = Task.detached { () -> Bool in
            do { try broker.activate(scope: scope, lease: lease); return true }
            catch { return false }
        }
        #expect(gate.waitUntilBlocked(timeout: 2))
        let stopFinished = DispatchSemaphore(value: 0)
        let stopping = Task.detached {
            await broker.stop()
            stopFinished.signal()
        }
        let stoppedBeforeAttestationReturned = WebKitBrokerAttestationGate.wait(stopFinished, timeout: 0.5)
        gate.release()
        await stopping.value
        let issuedAfterStop = await issuance.value
        #expect(stoppedBeforeAttestationReturned)
        #expect(!issuedAfterStop)
    }
    @Test func oneProfileCannotConsumeAnotherProfilesConnectionBudget() async throws {
        let origin = try WebKitBrokerEcho(), originPort = try await origin.start()
        defer { origin.cancel() }
        let broker = try WebKitLoopbackBroker(qualificationPort: .any), port = try await broker.start()
        defer { broker.cancel() }
        let a = scope(), b = scope()
        let capabilityA = try broker.registerForTesting(scope: a, route: .direct)
        let capabilityB = try broker.registerForTesting(scope: b, route: .direct)
        let ca = try credentials(capabilityA), cb = try credentials(capabilityB)
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

@MainActor
struct WebKitLoopbackBrokerPoolTests {
    @Test func concurrentProfileLaunchesShareOneListenerAndIdlePoolCanRestart() async throws {
        let pool = WebKitLoopbackBrokerPool {
            try WebKitLoopbackBroker(qualificationPort: .any)
        }

        async let first = pool.acquire()
        async let second = pool.acquire()
        let (firstBroker, secondBroker) = try await (first, second)
        #expect(firstBroker === secondBroker)

        await pool.stopIfIdle(false)
        #expect(try await pool.acquire() === firstBroker)

        await pool.stopIfIdle(true)
        let restarted = try await pool.acquire()
        #expect(restarted !== firstBroker)
        await pool.stopIfIdle(true)
    }
}
