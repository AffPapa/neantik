import Foundation
import Network
import Testing
@testable import NeAntik

struct ProxyProtocolDetectorTests {
    @Test func onlyOfferedSOCKSMethodsAreRecognized() {
        for method: UInt8 in [0,2,255] {
            #expect(ProxyProtocolDetector.reply(Data([5,method]), wire: .socks5) == .recognized(.socks5))
        }
        for bytes: [UInt8] in [[4,0], [5,1], [5,3], [5,2,0]] {
            #expect(ProxyProtocolDetector.reply(Data(bytes), wire: .socks5) == .unrecognized)
        }
        #expect(ProxyProtocolDetector.reply(Data([5]), wire: .socks5) == .incomplete)
    }
    @Test(arguments: [
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 Connection Established\r\n\r\n",
        "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n",
        "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate:\r\n\r\n",
        "HTTP/1.1 407 Bad\r\nProxy-Authenticate: Basic\r\n Unsafe: x\r\n\r\n",
        "HTTP/1.1 407 Bad\r\nProxy-Authenticate: Basic\nInjected: yes\r\n\r\n"
    ]) func ordinaryHTTPAndAmbiguousHeadersCannotClaimProxy(response: String) {
        #expect(ProxyProtocolDetector.reply(Data(response.utf8), wire: .http) == .unrecognized)
    }
    @Test func valid407IsProtocolEvidenceOnlyAndHeaderIsBounded() {
        let data = Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"fixture\"\r\n\r\n".utf8)
        for count in 0..<data.count { #expect(ProxyProtocolDetector.reply(data.prefix(count), wire: .http) == .incomplete) }
        #expect(ProxyProtocolDetector.reply(data, wire: .http) == .recognized(.httpAuthenticationChallenge))
        #expect(ProxyProtocolDetector.reply(Data(repeating: 65, count: 4096), wire: .http) == .unrecognized)
        #expect(ProxyProtocolDetector.reply(data + Data(repeating: 65, count: 4096), wire: .http) == .unrecognized)
        #expect(ProxyProtocolFinding.unknown.kind == nil)
        #expect(ProxyProtocolFinding.httpAuthenticationChallenge.kind == .http)
    }
    @Test func staleAndReturnedEndpointNeverResurrectsAnOldResult() throws {
        let a = try ProxyProtocolEndpoint(host: "owned.example.test", port: 50100)
        let b = try ProxyProtocolEndpoint(host: "owned.example.test", port: 50101)
        var state = ProxyProtocolDiscovery()
        let firstA = state.begin(endpoint: a)
        state.invalidate(); _ = state.begin(endpoint: b)
        state.invalidate(); let currentA = state.begin(endpoint: a)
        let staleAccepted = state.finish(firstA, finding: .socks5, currentEndpoint: a)
        #expect(!staleAccepted)
        #expect(state.applicableKind(at: a) == nil)
        let wrongEndpointAccepted = state.finish(currentA, finding: .socks5, currentEndpoint: b)
        let currentAccepted = state.finish(currentA, finding: .socks5, currentEndpoint: a)
        #expect(!wrongEndpointAccepted)
        #expect(currentAccepted)
        #expect(state.applicableKind(at: a) == .socks5)
        #expect(state.applicableKind(at: b) == nil)
        #expect(state.applicableKind(at: nil) == nil)
        state.invalidate(); #expect(state.applicableKind(at: a) == nil)
    }
    @Test func cancellationCannotStartAnHTTPFallback() async throws {
        let endpoint = try ProxyProtocolEndpoint(host: "owned.example.test", port: 50100)
        let task = Task { try await ProxyProtocolDetector().detect(endpoint: endpoint) { _, wire, _ in
            #expect(wire == .socks5)
            try await Task.sleep(for: .seconds(5)); return Data()
        } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test(arguments: [-1.0, 0, .nan, .infinity, 11])
    func refusesInvalidTimeoutBeforeCallingTransport(timeout: Double) async throws {
        let endpoint = try ProxyProtocolEndpoint(host: "owned.example.test", port: 50100)
        await #expect(throws: ProxyRelayTransportError.invalidLimit) {
            try await ProxyProtocolDetector().detect(endpoint: endpoint, timeout: timeout) { _,_,_ in
                Issue.record("Invalid timeout reached network transport"); return Data()
            }
        }
    }
}

/// Own TCP peer, no browser/Keychain/system proxy or external destination.
final class ProxyProtocolFixture: @unchecked Sendable {
    enum Mode: Sendable, Equatable { case socks, socksAnonymous, socksFragmented, http407, httpFragmented, http200, malformed, oversized, stall }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.neantik.fixture.protocol-detection")
    private let mode: Mode
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var frames: [Data] = []
    private var accepted = 0, closed = 0, begun = 0, peerTerminated = 0
    private var finishStart: ((Result<UInt16, Error>) -> Void)?
    init(_ mode: Mode) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finishStart = { continuation.resume(with: $0) }
                self.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let finish = self.finishStart; self.finishStart = nil
                        if let port = self.listener.port?.rawValue { finish?(.success(port)) }
                        else { finish?(.failure(ProxyRelayTransportError.unavailable)) }
                    case .failed, .cancelled:
                        let finish = self.finishStart; self.finishStart = nil; finish?(.failure(ProxyRelayTransportError.unavailable))
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { self.accept($0) }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 2) {
                    let finish = self.finishStart; self.finishStart = nil; finish?(.failure(ProxyRelayTransportError.timeout))
                }
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        accepted += 1
        let id = UUID(), stream = ProxyRelayUpstreamTransport(accepted: connection)
        tasks[id] = Task {
            var input = Data()
            defer { stream.cancel(); let captured = input; self.queue.async { self.frames.append(captured); self.tasks.removeValue(forKey: id); self.closed += 1 } }
            do {
                try await stream.open(timeout: 1)
                while input.count < 4 {
                    let chunk = try await stream.receive(maximumBytes: 512, timeout: 1)
                    guard !chunk.data.isEmpty else { return }; input.append(chunk.data)
                }
                let socks = input.first == 5
                self.queue.sync { self.begun += 1 }
                if !socks {
                    while input.range(of: Data([13,10,13,10])) == nil {
                        guard input.count < 4096 else { return }
                        let chunk = try await stream.receive(maximumBytes: 512, timeout: 1)
                        guard !chunk.data.isEmpty else { return }; input.append(chunk.data)
                    }
                }
                let response: Data
                switch mode {
                case .stall: response = Data()
                case .socks, .socksFragmented: response = Data([5,2])
                case .socksAnonymous: response = Data([5,0])
                case .http407, .httpFragmented:
                    response = Data((socks ? "HTTP/1.1 400 Bad Request\r\n\r\n" : "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"owned\"\r\n\r\n").utf8)
                case .http200: response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
                case .malformed: response = Data([0,1,2,3])
                case .oversized: response = Data(repeating: 65, count: 5000)
                }
                if mode == .socksFragmented || mode == .httpFragmented {
                    for byte in response { try await stream.send(Data([byte]), timeout: 1); try await Task.sleep(for: .milliseconds(1)) }
                } else if !response.isEmpty { try await stream.send(response, timeout: 1) }
                if mode != .stall { try await stream.finishWrite(timeout: 1) }
                while true {
                    let chunk = try await stream.receive(maximumBytes: 512, timeout: 1)
                    input.append(chunk.data)
                    if chunk.endOfStream { self.queue.sync { self.peerTerminated += 1 }; return }
                }
            } catch {
                if let error = error as? ProxyRelayTransportError {
                    switch error {
                    case .closed, .posixFailure(54), .posixFailure(32): self.queue.sync { self.peerTerminated += 1 }
                    default: break // A server-side timeout is not peer cleanup.
                    }
                }
            }
        }
    }
    func snapshot() -> (accepted: Int, closed: Int, begun: Int, peerTerminated: Int, frames: [Data]) { queue.sync { (accepted, closed, begun, peerTerminated, frames) } }
    func observedClientClose() async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(800))
        while ContinuousClock.now < deadline {
            let value = snapshot()
            if value.accepted > 0 && value.closed == value.accepted { return value.peerTerminated == value.accepted }
            try await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
    func cancel() {
        queue.async {
            self.listener.stateUpdateHandler = nil; self.listener.newConnectionHandler = nil; self.listener.cancel()
            for task in self.tasks.values { task.cancel() }
        }
    }
    func stop() async {
        let pending: [Task<Void,Never>] = await withCheckedContinuation { continuation in
            queue.async { let pending = Array(self.tasks.values); self.listener.stateUpdateHandler = nil; self.listener.newConnectionHandler = nil; self.listener.cancel(); for task in pending { task.cancel() }; continuation.resume(returning: pending) }
        }
        for task in pending { await task.value }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

struct ProxyProtocolSocketTests {
    @Test(arguments: [ProxyProtocolFixture.Mode.socks, .socksAnonymous, .socksFragmented, .http407, .httpFragmented, .http200, .malformed, .oversized])
    func realPeersNeverReceiveCredentialsOrTunnelPayload(mode: ProxyProtocolFixture.Mode) async throws {
        let peer = try ProxyProtocolFixture(mode), port = try await peer.start()
        defer { peer.cancel() }
        let endpoint = try ProxyProtocolEndpoint(host: "127.0.0.1", port: Int(port))
        let finding = try await ProxyProtocolDetector().detect(endpoint: endpoint, timeout: 1)
        switch mode {
        case .socks, .socksAnonymous, .socksFragmented: #expect(finding == .socks5)
        case .http407, .httpFragmented: #expect(finding == .httpAuthenticationChallenge)
        default: #expect(finding == .unknown)
        }
        let clientClosed = try await peer.observedClientClose()
        #expect(clientClosed)
        await peer.stop()
        let result = peer.snapshot()
        #expect(result.accepted == result.closed)
        #expect(result.frames.count == result.accepted)
        #expect(result.frames.first == ProxyProtocolDetector.Wire.socks5.request)
        for frame in result.frames {
            #expect(frame == ProxyProtocolDetector.Wire.socks5.request || frame == ProxyProtocolDetector.Wire.http.request)
        }
        #expect(result.accepted == ((mode == .socks || mode == .socksAnonymous || mode == .socksFragmented) ? 1 : 2))
    }
    @Test func timeoutAndCancellationCloseTheActualSocket() async throws {
        for cancel in [false,true] {
            let peer = try ProxyProtocolFixture(.stall), port = try await peer.start()
            defer { peer.cancel() }
            let endpoint = try ProxyProtocolEndpoint(host: "127.0.0.1", port: Int(port))
            let task = Task { try await ProxyProtocolDetector().detect(endpoint: endpoint, timeout: cancel ? 5 : 0.15) }
            if cancel {
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while peer.snapshot().begun == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
                try #require(peer.snapshot().accepted == 1 && peer.snapshot().begun == 1); task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
            } else { #expect(try await task.value == .unknown) }
            let clientClosed = try await peer.observedClientClose()
            #expect(clientClosed)
            await peer.stop()
            let result = peer.snapshot()
            #expect(result.accepted == result.closed)
            if cancel { #expect(result.accepted == 1) }
            #expect(result.frames.allSatisfy { $0 == ProxyProtocolDetector.Wire.socks5.request || $0 == ProxyProtocolDetector.Wire.http.request })
        }
    }
}
