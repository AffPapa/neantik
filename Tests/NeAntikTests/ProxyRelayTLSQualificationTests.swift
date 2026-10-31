#if DEBUG
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_TLS_FIXTURE"] == "1"))
    func exactCertificateAndBootstrapBoundary() throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["NEANTIK_RELAY_TLS_PUBLIC_ANCHOR"])
        let der = try #require(Data(base64Encoded: encoded))
        _ = try ProxyRelayTLSQualification.Configuration(anchorDER: der)
        for bad in [der + Data([0]), der + der] {
            #expect(throws: (any Error).self) { _ = try ProxyRelayTLSQualification.Configuration(anchorDER: bad) }
        }
        let profileID = UUID(), host = "localhost", hash = String(repeating: "a", count: 64)
        var value = ProxyRelayOwnerProtocol.Bootstrap(schemaVersion: 1, nonce: UUID(), profileID: profileID,
            sessionGeneration: UUID(), profileRevision: 1, kind: .https, host: host, port: 8000,
            username: "fixture-user", password: "fixture-password", runtimeVersion: "156.0.8078.12",
            runtimeExecutableSHA256: hash, runtimeFrameworkSHA256: hash,
            configurationSHA256: ProxyRelayOwnerProtocol.Bootstrap.configurationDigest(profileID: profileID,
                revision: 1, kind: .https, host: host, port: 8000, username: "fixture-user"))
        value.qualificationAnchorDER = der
        let frame = try JSONEncoder().encode(value)
        #expect(frame.count <= 16384)
        let decoded = try JSONDecoder().decode(ProxyRelayOwnerProtocol.Bootstrap.self, from: frame)
        try decoded.validate()
        #expect(decoded.qualificationAnchorDER == der)
        for (kind, host) in [(ProxyKind.http, "localhost"), (.socks5, "localhost"), (.https, "127.0.0.1"), (.https, "external.example.test")] {
            var invalid = ProxyRelayOwnerProtocol.Bootstrap(schemaVersion: 1, nonce: UUID(), profileID: profileID,
                sessionGeneration: UUID(), profileRevision: 1, kind: kind, host: host, port: 8000,
                username: "fixture-user", password: "fixture-password", runtimeVersion: "156.0.8078.12",
                runtimeExecutableSHA256: hash, runtimeFrameworkSHA256: hash,
                configurationSHA256: ProxyRelayOwnerProtocol.Bootstrap.configurationDigest(profileID: profileID,
                    revision: 1, kind: kind, host: host, port: 8000, username: "fixture-user"))
            invalid.qualificationAnchorDER = der
            #expect(throws: ProxyRelayOwnerProtocol.Failure.invalidBootstrap) { try invalid.validate() }
        }
        for otherHost in ["127.0.0.1", "external.example.test"] {
            #expect(throws: ProxyRelayTLSQualification.Failure.invalidEndpoint) {
                _ = try ProxyRelayTLSQualification.Configuration(anchorDER: der).parameters(for: .init(host: otherHost, port: 8000))
            }
        }
    }
    private var destination: ProxyRelayDestination { get throws { try .init(host: "owned.example.test", port: 443) } }
    private var credentials: ProxyRelayCredentials { get throws { try .init(username: "fixture-user", password: "fixture-password") } }

    /// Explicit network opt-in, owned public origin, no proxy credentials.
    /// This qualifies the production default-trust TLS constructor and I/O;
    /// authenticated CONNECT is independently tested by the loopback fixtures.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_PUBLIC_TLS_FIXTURE"] == "1"))
    func systemTrustCarriesApplicationDataWithoutPrivateAnchor() async throws {
        let trace = Trace()
        let transport = ProxyRelayUpstreamTransport(kind: .https,
            upstream: try .init(host: "browser.free", port: 443), observe: { trace.observe($0) })
        defer { transport.cancel() }
        try await transport.open(timeout: 10)
        try await transport.send(Data("GET / HTTP/1.1\r\nHost: browser.free\r\nConnection: close\r\n\r\n".utf8), timeout: 5)
        var prefix = Data()
        while prefix.range(of: Data("\r\n".utf8)) == nil {
            let chunk = try await transport.receive(maximumBytes: 512, timeout: 5)
            try #require(!chunk.data.isEmpty && prefix.count + chunk.data.count <= 4096)
            prefix.append(chunk.data)
        }
        let lineEnd = try #require(prefix.range(of: Data("\r\n".utf8)))
        // Only the ASCII status line is relevant; a partial UTF-8 body must
        // not turn a valid TLS/HTTP response into a harness decoding failure.
        let line = try #require(String(data: prefix[..<lineEnd.lowerBound], encoding: .ascii))
        let parts = line.split(separator: " ")
        try #require(parts.count >= 2 && parts[0] == "HTTP/1.1")
        let status = try #require(Int(parts[1]))
        // A site-level refusal still proves TLS and HTTP application I/O.
        // Never use this control as proof of CONNECT or Chromium's route.
        try #require((200...499).contains(status))
        #expect(trace.credentialWrites == 0)
        #expect(trace.maximumBufferedBytes <= 128 * 1024)
        transport.cancel()
        do { try await transport.send(Data([0]), timeout: 1); Issue.record("Cancelled TLS transport accepted a write") }
        catch { #expect(error is CancellationError || error as? ProxyRelayTransportError == .closed) }
        print("RELAY_DEFAULT_TLS_PROOF {\"systemTrust\":true,\"applicationIO\":true,\"credentialWrites\":0,\"privateAnchor\":false,\"connectProxyQualified\":false}")
    }

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

#endif
