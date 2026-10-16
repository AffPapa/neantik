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
        private var connections = 0, authenticated = 0, responses = 0
        private let destinations: [ProxyRelayDestination]
        private let direct: Bool
        private let noncePrefix: String?
        private let ownedPeer: NWEndpoint.Host
        private var startFinish: ((Result<UInt16, Error>) -> Void)?
        init(destination: ProxyRelayDestination = try! .init(host: "owned.invalid", port: 443), direct: Bool = false,
             bindHost: String = "127.0.0.1", alternateDestination: ProxyRelayDestination? = nil,
             noncePrefix: String? = nil) throws {
            self.destinations = [destination] + (alternateDestination.map { [$0] } ?? [])
            self.direct = direct; self.noncePrefix = noncePrefix
            self.ownedPeer = .init(bindHost)
            guard bindHost == "127.0.0.1" || WebKitProxyOwnedEndpoint.isPrivateIPv4(bindHost) else {
                throw WebKitProxySession.Failure.scope
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .init(bindHost), port: .any)
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
            guard case .hostPort(let peer, _) = connection.endpoint, peer == ownedPeer,
                  tasks.count < 8, connections < 32 else { connection.cancel(); return }
            connections += 1
            let transport = ProxyRelayUpstreamTransport(accepted: connection), id = UUID()
            tasks[id] = Task {
                defer { transport.cancel(); self.queue.async { self.tasks.removeValue(forKey: id) } }
                do {
                    try await transport.open(timeout: 2)
                    if self.direct {
                        let chunk = try await transport.receive(maximumBytes: 1024, timeout: 2)
                        guard !chunk.data.isEmpty else { return }
                        guard try await self.validRequest(chunk.data, transport: transport) else { return }
                        self.queue.sync { self.responses += 1 }
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
                          self.destinations.contains(parsed.destination) else { return }
                    self.queue.sync { self.authenticated += 1 }
                    try await transport.send(WebKitProxyConnectCodec.established)
                    var payload = Data(header.dropFirst(parsed.consumed))
                    while payload.count < 4 {
                        let chunk = try await transport.receive(maximumBytes: 4, timeout: 2)
                        guard !chunk.data.isEmpty else { return }; payload.append(chunk.data)
                    }
                    if payload.starts(with: Data("GET ".utf8)) {
                        guard try await self.validRequest(payload, transport: transport) else { return }
                        self.queue.sync { self.responses += 1 }
                        try await transport.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nCache-Control: no-store\r\nConnection: close\r\n\r\npong".utf8))
                    } else {
                        guard payload == Data("ping".utf8) else { return }
                        try await transport.send(Data("pong".utf8))
                    }
                    try await transport.finishWrite()
                } catch { /* Never serialize a raw error or credential. */ }
            }
        }
        private func validRequest(_ initial: Data, transport: ProxyRelayUpstreamTransport) async throws -> Bool {
            guard let noncePrefix else { return true }
            var header = initial
            while header.range(of: Data("\r\n\r\n".utf8)) == nil {
                guard header.count < 4096 else { return false }
                let chunk = try await transport.receive(maximumBytes: min(1024, 4096 - header.count), timeout: 2)
                guard !chunk.data.isEmpty else { return false }; header.append(chunk.data)
            }
            guard header.count <= 4096, let text = String(data: header, encoding: .utf8),
                  let first = text.components(separatedBy: "\r\n").first else { return false }
            return first.hasPrefix("GET /" + noncePrefix + "/") && first.hasSuffix(" HTTP/1.1")
        }
        func counts() -> (connections: Int, authenticated: Int, responses: Int) {
            queue.sync { (connections, authenticated, responses) }
        }
        func activeTaskCount() -> Int { queue.sync { tasks.count } }
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
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
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

/// Only selects an address already assigned to this Mac. No route, resolver,
/// interface, hosts file or system proxy setting is changed by this fixture.
private enum WebKitProxyOwnedEndpoint {
    struct Candidate {
        let address: String
        let flags: UInt32
    }
    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0" else { return nil }
            return UInt8(part)
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
    static func select(_ candidates: [Candidate]) -> String? {
        candidates.first {
            let required = UInt32(IFF_UP | IFF_RUNNING)
            let forbidden = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
            return $0.flags & required == required && $0.flags & forbidden == 0 && isPrivateIPv4($0.address)
        }?.address
    }
    static func current() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first, candidates: [Candidate] = []
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append(.init(address: String(cString: buffer), flags: item.pointee.ifa_flags))
        }
        return select(candidates)
    }
}

/// Closed QA input. A typo must not silently select the already-failed default.
private enum WebKitProxyQualificationMatchMode: String {
    case defaults, exactHosts = "exact-hosts"
    static func requested(_ value: String?) throws -> Self {
        guard let value else { return .defaults }
        guard let mode = Self(rawValue: value) else { throw WebKitProxySession.Failure.scope }
        return mode
    }
}

/// Pure synthetic selection controls; these do not read interfaces or launch WK.
struct WebKitProxyOwnedEndpointTests {
    @Test func unknownMatchPolicyNeverFallsBackToDefaults() throws {
        #expect(try WebKitProxyQualificationMatchMode.requested(nil) == .defaults)
        #expect(try WebKitProxyQualificationMatchMode.requested("exact-hosts") == .exactHosts)
        for value in ["", "*", "exact", "exact-hosts\n"] {
            #expect(throws: WebKitProxySession.Failure.scope) {
                try WebKitProxyQualificationMatchMode.requested(value)
            }
        }
    }
    @Test func onlyStrictRFC1918NumericAddressesAreEligible() {
        for value in ["10.1.2.3", "172.16.0.2", "172.31.255.254", "192.168.1.2"] {
            #expect(WebKitProxyOwnedEndpoint.isPrivateIPv4(value))
        }
        for value in ["127.0.0.1", "0.0.0.0", "169.254.1.1", "172.15.1.1", "172.32.1.1",
                      "192.0.2.1", "224.1.1.1", "10.256.1.1", "10.01.1.1", "10.1.1.1:80",
                      "::1", "localhost", "10.1.1.", "10.1.1.1\n"] {
            #expect(!WebKitProxyOwnedEndpoint.isPrivateIPv4(value))
        }
    }
    @Test func unavailableDownLoopbackAndVPNInterfacesAreNotFallbacks() {
        let active = UInt32(IFF_UP | IFF_RUNNING)
        #expect(WebKitProxyOwnedEndpoint.select([]) == nil)
        #expect(WebKitProxyOwnedEndpoint.select([
            .init(address: "10.1.2.3", flags: 0),
            .init(address: "10.1.2.4", flags: active | UInt32(IFF_LOOPBACK)),
            .init(address: "10.1.2.5", flags: active | UInt32(IFF_POINTOPOINT)),
            .init(address: "192.0.2.1", flags: active)
        ]) == nil)
        #expect(WebKitProxyOwnedEndpoint.select([.init(address: "192.168.1.2", flags: active)]) == "192.168.1.2")
    }
}

/// A new input, not a retry of the retained literal-loopback bypass. This is
/// public WK API compatibility research, not shipping proxy qualification.
@Suite(.serialized) @MainActor struct WebKitProxyNonLoopbackQualificationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_NONLOOPBACK_QUALIFICATION"] == "1"))
    func namedAndReachableLocalTargetsHaveIndependentControls() async throws {
        let matchMode = try WebKitProxyQualificationMatchMode.requested(
            ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_NONLOOPBACK_MATCH_MODE"])
        func requireAdmission() throws {
            var pressure: Int32 = 0, size = MemoryLayout<Int32>.size
            let observed = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0
            let approved = ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_PROXY_NONLOOPBACK_WARNING_ONCE"] == "authorized-current-run"
            let thermal = ProcessInfo.processInfo.thermalState
            guard observed, size == MemoryLayout<Int32>.size,
                  pressure == 1 || (pressure == 2 && approved),
                  thermal == .nominal || thermal == .fair else { throw WebKitProxySession.Failure.unavailable }
        }
        try requireAdmission()
        guard let host = WebKitProxyOwnedEndpoint.current() else {
            print("OWNED_WK_NONLOOPBACK_SETUP eligiblePrivateInterface=0")
            throw WebKitProxySession.Failure.unavailable
        }
        let nonce = UUID().uuidString.lowercased(), namedHost = "wk-" + UUID().uuidString.lowercased() + ".invalid"
        var origin: WebKitProxyTransportTests.Upstream?, upstream: WebKitProxyTransportTests.Upstream?
        var session: WebKitProxySession?, viewA: WKWebView?, viewB: WKWebView?, window: NSWindow?
        func cleanup() async {
            viewA?.stopLoading(); viewB?.stopLoading()
            viewA?.navigationDelegate = nil; viewB?.navigationDelegate = nil
            window?.contentView = nil; window?.close(); window = nil; viewA = nil; viewB = nil
            // Never clear the live A store's proxy assignment on revoke.
            if let session { await session.stop(); #expect(await session.activeConnectionCount() == 0) }
            if let upstream { await upstream.stop(); #expect(upstream.activeTaskCount() == 0) }
            if let origin { await origin.stop(); #expect(origin.activeTaskCount() == 0) }
            print("OWNED_WK_NONLOOPBACK_CLEANUP windowClosed=1 relayDrained=1 fixtureStopsAwaited=1")
        }
        do {
            let sentinel = try WebKitProxyTransportTests.Upstream(direct: true, bindHost: host, noncePrefix: nonce)
            origin = sentinel; let originPort = try await sentinel.start()
            let target = try ProxyRelayDestination(host: host, port: Int(originPort))
            let named = try ProxyRelayDestination(host: namedHost, port: Int(originPort))
            let fixture = try WebKitProxyTransportTests.Upstream(destination: target, alternateDestination: named, noncePrefix: nonce)
            upstream = fixture; let upstreamPort = try await fixture.start()
            let profile = UUID(), scope = WebKitProxySession.Scope(profileID: profile, storeID: profile, sessionID: UUID(), revision: 1)
            let relay = try WebKitProxySession(scope: scope, upstreamKind: .http,
                upstream: .init(host: "127.0.0.1", port: Int(upstreamPort)),
                credentials: .init(username: "owned-upstream", password: "fixture-only"))
            session = relay; _ = try await relay.start()
            let storeA = WKWebsiteDataStore.nonPersistent(), storeB = WKWebsiteDataStore.nonPersistent()
            var proxy = try relay.configuration(for: scope)
            if matchMode == .exactHosts {
                // Documented suffix selectors only. Whether explicit selectors
                // override implicit local-IP bypass is what this experiment tests.
                proxy.matchDomains = [host, namedHost]
                let expectedSelectors = proxy.matchDomains.count == 2 && Set(proxy.matchDomains) == Set([host, namedHost])
                try #require(expectedSelectors) // Do not render address values in a failed assertion.
            }
            let validPolicy = !proxy.allowFailover && proxy.excludedDomains.isEmpty
            try #require(validPolicy)
            print("OWNED_WK_NONLOOPBACK_POLICY exactHosts=\(matchMode == .exactHosts ? 1 : 0) noFailover=1 exceptionCount=0")
            storeA.proxyConfigurations = [proxy]; storeB.proxyConfigurations = []
            let configA = WKWebViewConfiguration(), configB = WKWebViewConfiguration()
            configA.websiteDataStore = storeA; configB.websiteDataStore = storeB
            try requireAdmission(); _ = NSApplication.shared
            let a = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configA)
            let b = WKWebView(frame: a.frame, configuration: configB); viewA = a; viewB = b
            let ownedWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 480),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window = ownedWindow; ownedWindow.isReleasedWhenClosed = false
            ownedWindow.title = "NeAntik · owned non-loopback WebKit proxy experiment"
            let stack = NSStackView(views: [a, b]); stack.orientation = .horizontal; stack.distribution = .fillEqually
            ownedWindow.contentView = stack; ownedWindow.makeKeyAndOrderFront(nil)
            func navigate(_ view: WKWebView, host: String, phase: String) async throws -> (body: String?, failed: Bool, timeout: Bool) {
                let probe = WebKitProxyNavigationProbe(); view.navigationDelegate = probe
                guard let url = URL(string: "http://\(host):\(originPort)/\(nonce)/\(phase)") else {
                    throw WebKitProxySession.Failure.scope
                }
                view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
                let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                while !probe.finished && !probe.failed && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                guard probe.finished || probe.failed else { view.stopLoading(); return (nil, false, true) }
                let body = probe.finished ? (try await view.evaluateJavaScript("document.body.innerText")) as? String : nil
                return (body?.trimmingCharacters(in: .whitespacesAndNewlines), probe.failed, false)
            }
            func observe(_ phase: String) {
                let s = relay.qualificationSnapshot()
                print("OWNED_WK_NONLOOPBACK phase=\(phase) accepted=\(s.accepted) malformed=\(s.malformed) authRefused=\(s.authenticationRefused) established=\(s.established) upstreamAuth=\(fixture.counts().authenticated) upstreamResponses=\(fixture.counts().responses) directConnections=\(sentinel.counts().connections) directResponses=\(sentinel.counts().responses)")
            }
            // .invalid may prove name routing/auth, but is never a Direct-failure
            // oracle: a Direct client would also fail to resolve this name.
            let nameResult = try await navigate(a, host: namedHost, phase: "named")
            observe("named")
            #expect(nameResult.body == "pong" && !nameResult.failed && !nameResult.timeout)
            #expect(fixture.counts().responses >= 1 && sentinel.counts().responses == 0)
            let direct = try await navigate(b, host: host, phase: "same-target")
            observe("direct-before")
            try #require(direct.body == "DIRECT" && !direct.failed && !direct.timeout && sentinel.counts().responses == 1)
            // A deliberately broken path opens TCP but sends no HTTP. Prove
            // the negative oracle catches an arrival without counting a body.
            let beforeBare = sentinel.counts()
            let bare = ProxyRelayUpstreamTransport(kind: .http, upstream: target)
            defer { bare.cancel() }
            try await bare.open(timeout: 2)
            let bareDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while sentinel.counts().connections == beforeBare.connections, ContinuousClock.now < bareDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            bare.cancel(); observe("bare-tcp-control")
            try #require(sentinel.counts().connections > beforeBare.connections)
            try #require(sentinel.counts().responses == beforeBare.responses)
            let beforeProxy = fixture.counts().responses
            let beforeA = sentinel.counts()
            let protected = try await navigate(a, host: host, phase: "same-target")
            observe("protected")
            #expect(protected.body == "pong" && !protected.failed && !protected.timeout)
            #expect(fixture.counts().responses == beforeProxy + 1 && sentinel.counts().responses == beforeA.responses)
            #expect(sentinel.counts().connections == beforeA.connections)
            await relay.stop()
            let beforeRevoke = sentinel.counts()
            let revoked = try await navigate(a, host: host, phase: "same-target")
            observe("revoked")
            #expect(revoked.failed && !revoked.timeout && sentinel.counts().responses == beforeRevoke.responses)
            #expect(sentinel.counts().connections == beforeRevoke.connections)
            let beforeDirectAfter = sentinel.counts()
            let stillReachable = try await navigate(b, host: host, phase: "same-target")
            observe("direct-after")
            #expect(stillReachable.body == "DIRECT" && !stillReachable.failed && !stillReachable.timeout)
            #expect(sentinel.counts().responses == beforeDirectAfter.responses + 1)
            #expect(sentinel.counts().connections > beforeDirectAfter.connections)
            await cleanup()
        } catch { await cleanup(); throw error }
    }
}
