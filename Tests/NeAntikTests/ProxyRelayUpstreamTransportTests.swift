import Foundation
import Testing
@testable import NeAntik

/// Opt-in real loopback fixtures; ordinary unit/CI runs never contact an
/// external proxy or read credentials. The retained runner owns these ports.
struct ProxyRelayUpstreamTransportTests {
    private final class BlockingAuthorization: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        let release = DispatchSemaphore(value: 0)
        var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func authorize() -> Bool {
            lock.lock(); entered = true; lock.unlock()
            return release.wait(timeout: .now() + 2) == .success
        }
    }
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        private var cleanEOF = false
        private var maximumBuffer = 0
        private var credentialWrites = 0
        func append(_ event: ProxyRelayUpstreamTransport.Observation) {
            lock.lock(); defer { lock.unlock() }
            if case .received(_, true, true, nil) = event { cleanEOF = true }
            if case .buffered(let count) = event { maximumBuffer = max(maximumBuffer, count) }
            if case .credentialWriteEnqueued = event { credentialWrites += 1 }
            if values.count < 100 { values.append(String(describing: event)) }
        }
        var cleanEOFObserved: Bool { lock.lock(); defer { lock.unlock() }; return cleanEOF }
        var maximumBufferedBytes: Int { lock.lock(); defer { lock.unlock() }; return maximumBuffer }
        var credentialWriteCount: Int { lock.lock(); defer { lock.unlock() }; return credentialWrites }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private func transport(_ scenario: String, kind: ProxyKind, trace: Trace? = nil) throws -> ProxyRelayUpstreamTransport {
        let env = ProcessInfo.processInfo.environment
        let text = try #require(env["NEANTIK_RELAY_FIXTURE_PORTS"])
        let data = try #require(text.data(using: .utf8))
        let values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
        let port = try #require(values[scenario])
        return try ProxyRelayUpstreamTransport(kind: kind, upstream: .init(host: "127.0.0.1", port: port), observe: trace.map { box in { event in box.append(event) } })
    }
    private var destination: ProxyRelayDestination { get throws { try .init(host: "owned.example.test", port: 443) } }
    private var credentials: ProxyRelayCredentials { get throws { try .init(username: "fixture-user", password: "fixture-password") } }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_SOCKET_FIXTURE"] == "1"), arguments: ["cancel-auth-http", "cancel-auth-socks"])
    func cancellationDuringSynchronousAdmissionCannotSendCredentials(scenario: String) async throws {
        let authority = BlockingAuthorization()
        let trace = Trace()
        let upstream = try transport(scenario, kind: scenario == "cancel-auth-socks" ? .socks5 : .http, trace: trace)
        let destination = try self.destination, credentials = try self.credentials
        defer { authority.release.signal(); upstream.cancel() }
        let task = Task { try await upstream.establish(destination: destination, credentials: credentials, timeout: 3,
                                                      authorizeCredentials: { authority.authorize() }) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !authority.isEntered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(authority.isEntered, "Authorization callback never entered")
        task.cancel(); authority.release.signal()
        do { _ = try await task.value; Issue.record("Cancelled authorization established tunnel") }
        catch { #expect(error is CancellationError) }
        #expect(trace.credentialWriteCount == 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_SOCKET_FIXTURE"] == "1"), arguments: ["socks", "http", "http-split", "http-delayed", "http-bulk"])
    func authenticatedRealTunnelCarriesPayloadAndEOF(scenario: String) async throws {
        let trace = Trace()
        let upstream = try transport(scenario, kind: scenario == "socks" ? .socks5 : .http, trace: trace)
        defer { upstream.cancel() }
        var phase = "establish"
        var received = Data()
        var readEvents: [String] = []
        do {
        var payload = try await upstream.establish(destination: destination, credentials: credentials, timeout: 3, authorizeCredentials: { true })
        while payload.count < "fixture-proof".utf8.count { payload.append(try await upstream.receive(timeout: 3).data) }
        #expect(payload == Data("fixture-proof".utf8))
        phase = "send-ping"
        try await upstream.send(Data("fixture-ping".utf8), timeout: 3)
        phase = "finish-write"
        try await upstream.finishWrite(timeout: 3)
        phase = "receive-pong-and-eof"
        if scenario == "http-delayed" || scenario == "http-bulk" { try await Task.sleep(for: .milliseconds(200)) }
        var eof = false
        while !eof {
            let chunk = try await upstream.receive(maximumBytes: scenario == "http-bulk" ? 1273 : 64 * 1024, timeout: 3)
            readEvents.append("\(chunk.data.count):\(chunk.endOfStream)")
            received.append(chunk.data); eof = chunk.endOfStream
        }
        let expected = scenario == "http-bulk" ? Data((0..<(512 * 1024)).map { UInt8($0 % 251) }) : Data("fixture-pong".utf8)
        #expect(received == expected)
        #expect(trace.cleanEOFObserved)
        #expect(trace.maximumBufferedBytes <= 128 * 1024)
        let repeatedEOF = try await upstream.receive(timeout: 0.2)
        #expect(repeatedEOF.data.isEmpty && repeatedEOF.endOfStream)
        do { try await upstream.send(Data([0])); Issue.record("Write after FIN was accepted") } catch {}
        let proof: [String: Any] = ["scenario": scenario, "cleanEOFObserved": trace.cleanEOFObserved, "receivedBytes": received.count, "maximumBufferedBytes": trace.maximumBufferedBytes, "expectedPayloadMatched": received == expected]
        let proofText = String(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), encoding: .utf8)!
        print("OWNED_RELAY_PROOF \(proofText)")
        print("OWNED_RELAY_TRACE \(scenario) \(trace.snapshot)")
        } catch { Issue.record("Controlled fixture phase \(phase), redacted typed failure \(error), receivedBytes \(received.count), readEvents \(readEvents), nativeTrace \(trace.snapshot)") }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_SOCKET_FIXTURE"] == "1"), arguments: ["auth-refused", "tls-untrusted", "truncated"])
    func failedUpstreamNeverReturnsATunnel(scenario: String) async throws {
        let upstream = try transport(scenario, kind: scenario == "tls-untrusted" ? .https : .http)
        defer { upstream.cancel() }
        do {
            _ = try await upstream.establish(destination: destination, credentials: credentials, timeout: 3, authorizeCredentials: { true })
            Issue.record("Controlled failed upstream established a tunnel")
        } catch {
            switch scenario {
            case "auth-refused": #expect(error as? ProxyRelayWireError == .authenticationRejected)
            case "tls-untrusted": #expect(error as? ProxyRelayTransportError == .tlsFailed)
            default: #expect(error as? ProxyRelayTransportError == .closed)
            }
        }
        do { try await upstream.send(Data("must-not-send".utf8)); Issue.record("Failed transport remained usable") } catch {}
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_SOCKET_FIXTURE"] == "1"))
    func slowPartialHeaderDoesNotRestartTheHandshakeDeadline() async throws {
        let upstream = try transport("drip", kind: .http)
        defer { upstream.cancel() }
        let started = ContinuousClock.now
        do {
            _ = try await upstream.establish(destination: destination, credentials: credentials, timeout: 0.25, authorizeCredentials: { true })
            Issue.record("Incomplete slow handshake established a tunnel")
        } catch { #expect(error as? ProxyRelayTransportError == .timeout) }
        #expect(started.duration(to: .now) < .seconds(1.5))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_SOCKET_FIXTURE"] == "1"))
    func cancellingPendingReadSettlesAndClosesConnection() async throws {
        let upstream = try transport("cancel", kind: .http)
        try await upstream.open(timeout: 3)
        let read = Task { try await upstream.receive(timeout: 3) }
        await Task.yield(); read.cancel()
        do { _ = try await read.value; Issue.record("Cancelled read returned success") }
        catch { #expect(error is CancellationError) }
        do { try await upstream.send(Data("must-not-send".utf8)); Issue.record("Cancelled transport remained usable") } catch {}
    }
}


extension ProxyRelayUpstreamTransportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_SOCKET_FIXTURE"] == "1"), arguments: ["http-rst", "http-no-fin", "http-no-pong"])
    func brokenStreamCannotPassPayloadAndCleanEOF(scenario: String) async throws {
        let trace = Trace()
        let upstream = try transport(scenario, kind: .http, trace: trace)
        defer { upstream.cancel() }
        _ = try await upstream.establish(destination: destination, credentials: credentials, timeout: 3, authorizeCredentials: { true })
        try await upstream.send(Data("fixture-ping".utf8), timeout: 3)
        try await upstream.finishWrite(timeout: 3)
        var received = Data(); var eof = false; var failure: Error?
        do {
            while !eof {
                let chunk = try await upstream.receive(timeout: 0.2)
                received.append(chunk.data); eof = chunk.endOfStream
            }
        } catch { failure = error }
        #expect(!(received == Data("fixture-pong".utf8) && eof && trace.cleanEOFObserved))
        switch scenario {
        case "http-no-pong": #expect(received.isEmpty && eof && trace.cleanEOFObserved && failure == nil)
        case "http-no-fin": #expect(!eof && !trace.cleanEOFObserved && failure as? ProxyRelayTransportError == .timeout)
        default: #expect(!eof && !trace.cleanEOFObserved && failure is ProxyRelayTransportError)
        }
        let proof: [String: Any] = ["scenario": scenario, "positiveVerdictRejected": true, "cleanEOFObserved": trace.cleanEOFObserved, "receivedBytes": received.count]
        print("OWNED_RELAY_PROOF \(String(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), encoding: .utf8)!)")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_SOCKET_FIXTURE"] == "1"))
    func cancelledConsumerCannotResurrectBufferedPayloadOrEOF() async throws {
        let upstream = try transport("cancel-late", kind: .http)
        defer { upstream.cancel() }
        try await upstream.open(timeout: 3)
        let read = Task { try await upstream.receive(timeout: 3) }
        read.cancel()
        do { _ = try await read.value; Issue.record("Immediate cancellation succeeded") } catch { #expect(error is CancellationError) }
        upstream.cancel()
        try await Task.sleep(for: .milliseconds(200))
        do { _ = try await upstream.receive(timeout: 0.2); Issue.record("Cancelled transport returned late data/EOF") }
        catch { #expect(error is CancellationError) }
    }
}
