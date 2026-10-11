import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayTLSQualificationTests {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var writes = 0
        private var maximumBuffer = 0
        func observe(_ event: ProxyRelayUpstreamTransport.Observation) {
            lock.lock(); defer { lock.unlock() }
            if case .credentialWriteEnqueued = event { writes += 1 }
            if case .buffered(let count) = event { maximumBuffer = max(maximumBuffer, count) }
        }
        var credentialWrites: Int { lock.lock(); defer { lock.unlock() }; return writes }
        var maximumBufferedBytes: Int { lock.lock(); defer { lock.unlock() }; return maximumBuffer }
    }

    @Test(arguments: [Data(), Data([1, 2, 3]), Data(repeating: 0, count: 4097)])
    func malformedAndOversizedAnchorRefused(data: Data) {
        #expect(throws: ProxyRelayTLSQualification.Failure.self) {
            _ = try ProxyRelayTLSQualification.Configuration(anchorDER: data)
        }
    }

    private func fixture(_ scenario: String, trace: Trace, standardTrust: Bool = false) throws -> ProxyRelayUpstreamTransport {
        let env = ProcessInfo.processInfo.environment
        let map = try #require(env["NEANTIK_RELAY_TLS_PORTS"]?.data(using: .utf8))
        let ports = try #require(JSONSerialization.jsonObject(with: map) as? [String: Int])
        let endpoint = try ProxyRelayDestination(host: "localhost", port: #require(ports[scenario]))
        if standardTrust { return ProxyRelayUpstreamTransport(kind: .https, upstream: endpoint, observe: { trace.observe($0) }) }
        let encoded = try #require(env["NEANTIK_RELAY_TLS_PUBLIC_ANCHOR"])
        let data = try #require(Data(base64Encoded: encoded))
        return try ProxyRelayUpstreamTransport(qualification: .init(anchorDER: data), upstream: endpoint, observe: { trace.observe($0) })
    }
    private var destination: ProxyRelayDestination { get throws { try .init(host: "owned.example.test", port: 443) } }
    private var credentials: ProxyRelayCredentials { get throws { try .init(username: "fixture-user", password: "fixture-password") } }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_TLS_FIXTURE"] == "1"))
    func trustedChainCarriesAuthenticatedConnectAndBulkPayload() async throws {
        let trace = Trace(), upstream = try fixture("trusted", trace: trace)
        defer { upstream.cancel() }
        var payload = try await upstream.establish(destination: destination, credentials: credentials, timeout: 4, authorizeCredentials: { true })
        let expected = Data((0..<(512 * 1024)).map { UInt8($0 % 251) })
        while payload.count < expected.count {
            let chunk = try await upstream.receive(maximumBytes: 1273, timeout: 4)
            payload.append(chunk.data)
            if chunk.endOfStream { break }
        }
        #expect(payload == expected)
        #expect(trace.credentialWrites == 1)
        #expect(trace.maximumBufferedBytes <= 128 * 1024)
        let terminal = try await upstream.receive(timeout: 4)
        #expect(terminal.data.isEmpty && terminal.endOfStream)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_TLS_FIXTURE"] == "1"),
          arguments: ["wrong-name", "expired", "foreign-ca", "missing-intermediate", "plaintext", "default-trust"])
    func tlsFailurePreventsCredentialWrites(scenario: String) async throws {
        let trace = Trace(), upstream = try fixture(scenario, trace: trace, standardTrust: scenario == "default-trust")
        defer { upstream.cancel() }
        do {
            _ = try await upstream.establish(destination: destination, credentials: credentials, timeout: 4, authorizeCredentials: { true })
            Issue.record("Failed TLS fixture established a tunnel")
        } catch { #expect(error as? ProxyRelayTransportError == .tlsFailed) }
        #expect(trace.credentialWrites == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_TLS_FIXTURE"] == "1"))
    func cancelDuringTLSHandshakeSettlesWithoutCredentials() async throws {
        let trace = Trace(), upstream = try fixture("stall-cancel", trace: trace)
        defer { upstream.cancel() }
        let task = Task { try await upstream.establish(destination: destination, credentials: credentials, timeout: 4, authorizeCredentials: { true }) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled TLS handshake established a tunnel") }
        catch { #expect(error is CancellationError) }
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(trace.credentialWrites == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_TLS_FIXTURE"] == "1"))
    func truncatedTLSStreamCannotReportCleanEOF() async throws {
        let trace = Trace(), upstream = try fixture("truncated-tls", trace: trace)
        defer { upstream.cancel() }
        _ = try await upstream.establish(destination: destination, credentials: credentials, timeout: 4, authorizeCredentials: { true })
        var cleanEOF = false, failure = false
        do {
            while true {
                let chunk = try await upstream.receive(timeout: 4)
                if chunk.endOfStream { cleanEOF = true; break }
            }
        } catch { failure = true }
        #expect(failure && !cleanEOF)
        #expect(trace.credentialWrites == 1)
    }
}
