import Foundation
import AppKit
import Darwin
import Network
import Testing
import WebKit
@testable import NeAntik

/// Network.framework controls only, not WebKit/headed route qualification.
/// All listeners, credentials and destination data are owned synthetic values.
struct WebKitProxyTransportTests {
    fileprivate final class Upstream: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "app.neantik.fixture.wk-connect")
        private var tasks: [UUID: Task<Void, Never>] = [:]
        private var connections = 0, authenticated = 0
        private let destination: ProxyRelayDestination
        private let direct: Bool
        private var startFinish: ((Result<UInt16, Error>) -> Void)?
        init(destination: ProxyRelayDestination = try! .init(host: "owned.invalid", port: 443), direct: Bool = false) throws {
            self.destination = destination; self.direct = direct
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)
            listener = try NWListener(using: parameters)
        }
        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.startFinish = { continuation.resume(with: $0) }
                    self.listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            let finish = self.startFinish; self.startFinish = nil
                            if let port = self.listener.port?.rawValue { finish?(.success(port)) }
                            else { finish?(.failure(WebKitProxySession.Failure.unavailable)) }
                        case .failed, .cancelled:
                            let finish = self.startFinish; self.startFinish = nil
                            finish?(.failure(WebKitProxySession.Failure.unavailable))
                        default: break
                        }
                    }
                    self.listener.newConnectionHandler = { self.accept($0) }
                    self.listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        let finish = self.startFinish; self.startFinish = nil
                        finish?(.failure(WebKitProxySession.Failure.unavailable))
                    }
                }
            }
        }
        private func accept(_ connection: NWConnection) {
            connections += 1
            let transport = ProxyRelayUpstreamTransport(accepted: connection), id = UUID()
            tasks[id] = Task {
                defer { transport.cancel(); self.queue.async { self.tasks.removeValue(forKey: id) } }
                do {
                    try await transport.open(timeout: 2)
                    if self.direct {
                        let chunk = try await transport.receive(maximumBytes: 1024, timeout: 2)
                        guard !chunk.data.isEmpty else { return }
                        try await transport.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 6\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nDIRECT".utf8))
                        try await transport.finishWrite(); return
                    }
                    var header = Data(), parsed: WebKitProxyConnectCodec.Request?
                    while parsed == nil {
                        let chunk = try await transport.receive(maximumBytes: 1024, timeout: 2)
                        guard !chunk.data.isEmpty else { return }
                        header.append(chunk.data); parsed = try WebKitProxyConnectCodec.request(header)
                    }
                    guard let parsed,
                          parsed.authorization == Data("owned-upstream:fixture-only".utf8),
                          parsed.destination == self.destination else { return }
                    self.queue.sync { self.authenticated += 1 }
                    try await transport.send(WebKitProxyConnectCodec.established)
                    var payload = Data(header.dropFirst(parsed.consumed))
                    while payload.count < 4 {
                        let chunk = try await transport.receive(maximumBytes: 4, timeout: 2)
                        guard !chunk.data.isEmpty else { return }; payload.append(chunk.data)
                    }
                    if payload.starts(with: Data("GET ".utf8)) {
                        try await transport.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nCache-Control: no-store\r\nConnection: close\r\n\r\npong".utf8))
                    } else {
                        guard payload == Data("ping".utf8) else { return }
                        try await transport.send(Data("pong".utf8))
                    }
                    try await transport.finishWrite()
                } catch { /* Never serialize a raw error or credential. */ }
            }
        }
        func counts() -> (connections: Int, authenticated: Int) { queue.sync { (connections, authenticated) } }
        func cancel() {
            queue.async {
                self.listener.newConnectionHandler = nil; self.listener.stateUpdateHandler = nil
                self.listener.cancel(); for task in self.tasks.values { task.cancel() }
                let finish = self.startFinish; self.startFinish = nil
                finish?(.failure(WebKitProxySession.Failure.unavailable))
            }
        }
        func stop() async {
            let pending: [Task<Void, Never>] = await withCheckedContinuation { continuation in
                queue.async {
                    self.listener.newConnectionHandler = nil; self.listener.stateUpdateHandler = nil
                    self.listener.cancel(); let pending = Array(self.tasks.values)
                    for task in pending { task.cancel() }; continuation.resume(returning: pending)
                }
            }
            for task in pending { await task.value }
        }
    }
    private func scope() -> WebKitProxySession.Scope {
        let id = UUID(); return .init(profileID: id, storeID: id, sessionID: UUID(), revision: 1)
    }
    private func networkClient(_ configuration: Network.ProxyConfiguration) -> URLSession {
        let parameters = URLSessionConfiguration.ephemeral
        parameters.httpCookieStorage = nil; parameters.httpShouldSetCookies = false
        parameters.urlCredentialStorage = nil; parameters.urlCache = nil
        parameters.timeoutIntervalForRequest = 3; parameters.timeoutIntervalForResource = 3
        parameters.proxyConfigurations = [configuration]
        return URLSession(configuration: parameters)
    }
    // Experimental native compatibility gate, separate from model/framing CI.
    // Its retained FAIL (CFNetwork loopback bypass) is not a skipped PASS.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_CFNETWORK_QUALIFICATION"] == "1"))
    func nativeNetworkCredentialInteroperatesWithoutExposingLocalSecret() async throws {
        let sentinel = try Upstream(direct: true), sentinelPort = try await sentinel.start()
        defer { sentinel.cancel() }
        let upstream = try Upstream(destination: .init(host: "127.0.0.1", port: Int(sentinelPort)))
        let port = try await upstream.start(), scope = scope()
        defer { upstream.cancel() }
        let session = try WebKitProxySession(scope: scope, upstreamKind: .http,
            upstream: .init(host: "127.0.0.1", port: Int(port)),
            credentials: .init(username: "owned-upstream", password: "fixture-only"))
        let relayPort = try await session.start()
        let config = try session.configuration(for: scope), client = networkClient(config)
        defer { session.cancel(); client.invalidateAndCancel() }
        do {
            let url = URL(string: "http://127.0.0.1:\(sentinelPort)/")!
            let (reply, response) = try await client.data(from: url)
            let observation = session.qualificationSnapshot()
            print("OWNED_CFNETWORK_PROXY_OBSERVATION accepted=\(observation.accepted) malformed=\(observation.malformed) authRefused=\(observation.authenticationRefused) established=\(observation.established) upstream=\(upstream.counts().connections) direct=\(sentinel.counts().connections)")
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(reply == Data("pong".utf8))
            #expect(upstream.counts().connections == 1)
            #expect(upstream.counts().authenticated == 1)
            #expect(sentinel.counts().connections == 0)
            client.invalidateAndCancel(); await session.stop()
            #expect(await session.activeConnectionCount() == 0)
            // A fresh Network connection retains the old proxy configuration;
            // after revocation it must fail, never route directly.
            let stale = networkClient(config)
            defer { stale.invalidateAndCancel() }
            await #expect(throws: (any Error).self) { try await stale.data(from: url) }
            #expect(upstream.counts().connections == 1)
            #expect(sentinel.counts().connections == 0)
            // An independent no-proxy client can reach this exact destination;
            // stale proxy refusal must not be caused by an unavailable origin.
            let direct = URLSession(configuration: .ephemeral)
            defer { direct.invalidateAndCancel() }
            let (directReply, _) = try await direct.data(from: url)
            #expect(directReply == Data("DIRECT".utf8))
            #expect(sentinel.counts().connections == 1)
            #expect(relayPort > 0)
        } catch {
            client.invalidateAndCancel(); await session.stop(); await upstream.stop(); await sentinel.stop(); throw error
        }
        await upstream.stop()
        await sentinel.stop()
    }
    @Test func foreignLocalCredentialsNeverReachUpstream() async throws {
        let upstream = try Upstream(), port = try await upstream.start(), scope = scope()
        defer { upstream.cancel() }
        let session = try WebKitProxySession(scope: scope, upstreamKind: .http,
            upstream: .init(host: "127.0.0.1", port: Int(port)),
            credentials: .init(username: "owned-upstream", password: "fixture-only"))
        let relayPort = try await session.start()
        _ = try session.configuration(for: scope)
        let client = try ProxyRelayUpstreamTransport(kind: .http, upstream: .init(host: "127.0.0.1", port: Int(relayPort)))
        do {
            await #expect(throws: ProxyRelayWireError.authenticationRejected) {
                try await client.establish(destination: .init(host: "owned.invalid", port: 443),
                    credentials: .init(username: "foreign-session", password: "fixture-only"), timeout: 2,
                    authorizeCredentials: { true })
            }
            client.cancel(); await session.stop()
            #expect(upstream.counts().connections == 0)
            #expect(upstream.counts().authenticated == 0)
            #expect(await session.activeConnectionCount() == 0)
        } catch {
            client.cancel(); await session.stop(); await upstream.stop(); throw error
        }
        await upstream.stop()
    }
}

@MainActor private final class WebKitProxyNavigationProbe: NSObject, WKNavigationDelegate {
    var finished = false, failed = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed = true }
}

/// Opt-in real headed public WK API experiment. Nonpersistent stores only:
/// this does not qualify persistent UUID stores, shipping manager, DNS or UDP.
@Suite(.serialized) @MainActor struct WebKitProxyHeadedQualificationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_HEADED_QUALIFICATION"] == "1"))
    func publicStoreProxyAndReachableDirectControl() async throws {
        func requireAdmission() throws {
            var pressure: Int32 = 0, size = MemoryLayout<Int32>.size
            let observed = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0
            let warningApproved = ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_WARNING_ONCE"] == "authorized-current-run"
            let thermal = ProcessInfo.processInfo.thermalState
            guard observed, size == MemoryLayout<Int32>.size,
                  pressure == 1 || (pressure == 2 && warningApproved),
                  thermal == .nominal || thermal == .fair else { throw WebKitProxySession.Failure.unavailable }
        }
        try requireAdmission()
        _ = NSApplication.shared
        let sentinel = try WebKitProxyTransportTests.Upstream(direct: true)
        let originPort = try await sentinel.start()
        defer { sentinel.cancel() }
        let upstream = try WebKitProxyTransportTests.Upstream(destination: .init(host: "127.0.0.1", port: Int(originPort)))
        let upstreamPort = try await upstream.start()
        defer { upstream.cancel() }
        let profileID = UUID()
        let scope = WebKitProxySession.Scope(profileID: profileID, storeID: profileID, sessionID: UUID(), revision: 1)
        let session = try WebKitProxySession(scope: scope, upstreamKind: .http,
            upstream: .init(host: "127.0.0.1", port: Int(upstreamPort)),
            credentials: .init(username: "owned-upstream", password: "fixture-only"))
        _ = try await session.start()
        defer { session.cancel() }
        let storeA = WKWebsiteDataStore.nonPersistent(), storeB = WKWebsiteDataStore.nonPersistent()
        storeA.proxyConfigurations = [try session.configuration(for: scope)]
        storeB.proxyConfigurations = []
        let configurationA = WKWebViewConfiguration(), configurationB = WKWebViewConfiguration()
        configurationA.websiteDataStore = storeA; configurationB.websiteDataStore = storeB
        try requireAdmission()
        let a = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configurationA)
        let b = WKWebView(frame: a.frame, configuration: configurationB)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NeAntik · owned WebKit proxy qualification"
        window.isReleasedWhenClosed = false
        let stack = NSStackView(views: [a, b]); stack.orientation = .horizontal; stack.distribution = .fillEqually
        window.contentView = stack; window.makeKeyAndOrderFront(nil)
        defer {
            a.stopLoading(); b.stopLoading(); a.navigationDelegate = nil; b.navigationDelegate = nil
            // Keep A's proxy assignment; never clear it while views live.
            window.contentView = nil; window.close()
        }
        func navigate(_ view: WKWebView, path: String) async throws -> (body: String?, failed: Bool) {
            let probe = WebKitProxyNavigationProbe(); view.navigationDelegate = probe
            view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(originPort)/\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData))
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !probe.finished && !probe.failed && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard probe.finished || probe.failed else { throw WebKitProxySession.Failure.unavailable }
            let body = probe.finished ? (try await view.evaluateJavaScript("document.body.innerText")) as? String : nil
            return (body?.trimmingCharacters(in: .whitespacesAndNewlines), probe.failed)
        }
        do {
            let protected = try await navigate(a, path: "protected")
            let observation = session.qualificationSnapshot(), initialDirect = sentinel.counts().connections
            print("OWNED_WK_PROXY_OBSERVATION accepted=\(observation.accepted) malformed=\(observation.malformed) authRefused=\(observation.authenticationRefused) established=\(observation.established) upstream=\(upstream.counts().connections) direct=\(initialDirect) failed=\(protected.failed)")
            try #require(protected.body == "pong" && !protected.failed)
            try #require(initialDirect == 0 && upstream.counts().authenticated == 1)
            let direct = try await navigate(b, path: "direct-control")
            try #require(direct.body == "DIRECT" && !direct.failed && sentinel.counts().connections == 1)
            await session.stop()
            let revoked = try await navigate(a, path: "revoked")
            try #require(revoked.failed && sentinel.counts().connections == 1)
            try #require(await session.activeConnectionCount() == 0)
        } catch {
            await session.stop(); await upstream.stop(); await sentinel.stop(); throw error
        }
        await upstream.stop(); await sentinel.stop()
    }
}
