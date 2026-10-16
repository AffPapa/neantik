#if DEBUG
import Foundation
import Network
import Security

/// Not connected to shipping launch/UI/MCP. A capability authorizes its holder,
/// not an Apple PID or a proven WK store. Native store/DNS/UDP qualification is
/// required before this becomes a product capability. Chromium authority is
/// deliberately independent and unchanged.
final class WebKitProxySession: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Scope: Equatable, Sendable {
        let profileID: UUID
        let storeID: UUID
        let sessionID: UUID
        let revision: Int
    }
    enum Failure: Error { case scope, entropy, state, unavailable, refused }
    private enum State { case created, starting, ready, issued, revoked }
    private let scope: Scope
    private let username: String
    private let password: String
    private let authorization: Data
    private let upstreamKind: ProxyKind
    private let upstream: ProxyRelayDestination
    private let credentials: ProxyRelayCredentials?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.neantik.webkit-proxy.qualification")
    private var state: State = .created
    private var port: UInt16?
    private var startFinish: ((Result<UInt16, Error>) -> Void)?
    private var startDeadline: DispatchWorkItem?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    struct QualificationSnapshot: Equatable {
        let accepted: Int
        let malformed: Int
        let authenticationRefused: Int
        let established: Int
    }
    private var accepted = 0, malformed = 0, authenticationRefused = 0, established = 0
    var description: String { "WebKitProxySession(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    init(scope: Scope, upstreamKind: ProxyKind, upstream: ProxyRelayDestination,
         credentials: ProxyRelayCredentials?) throws {
        let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        guard scope.profileID != zero, scope.storeID == scope.profileID,
              scope.sessionID != zero, scope.revision > 0 else { throw Failure.scope }
        self.scope = scope; self.upstreamKind = upstreamKind
        self.upstream = upstream; self.credentials = credentials
        username = "wk-" + UUID().uuidString.lowercased()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.entropy }
        password = Data(bytes).base64EncodedString()
        authorization = Data((username + ":" + password).utf8)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.state == .created else { continuation.resume(throwing: Failure.state); return }
                    self.state = .starting
                    self.startFinish = { continuation.resume(with: $0) }
                    let deadline = DispatchWorkItem { [weak self] in self?.revokeOnQueue() }
                    self.startDeadline = deadline
                    self.queue.asyncAfter(deadline: .now() + 5, execute: deadline)
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self, self.state != .revoked else { return }
                        switch state {
                        case .ready:
                            guard self.state == .starting else { return }
                            guard let port = self.listener.port?.rawValue, port > 0 else { self.revokeOnQueue(); return }
                            self.port = port; self.state = .ready
                            self.startDeadline?.cancel(); self.startDeadline = nil
                            let finish = self.startFinish; self.startFinish = nil; finish?(.success(port))
                        case .failed, .cancelled: self.revokeOnQueue()
                        default: break
                        }
                    }
                    self.listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        self.accept(connection)
                    }
                    self.listener.start(queue: self.queue)
                }
            }
        } onCancel: { self.cancel() }
    }

    /// One configuration per matching generation, issued before the first
    /// WKWebView. Callers must retain it on live stores even after revocation;
    /// replacing it with [] would change the route to Direct.
    func configuration(for requested: Scope) throws -> Network.ProxyConfiguration {
        try queue.sync {
            guard requested == scope else { throw Failure.scope }
            guard state == .ready, let port else { throw Failure.state }
            var configuration = Network.ProxyConfiguration(httpCONNECTProxy:
                .hostPort(host: .init("127.0.0.1"), port: .init(rawValue: port)!))
            configuration.allowFailover = false
            // Fresh configuration has no domain exceptions. Verify the actual
            // defaults instead of mutating an already empty native domain set.
            guard configuration.matchDomains.isEmpty, configuration.excludedDomains.isEmpty else { throw Failure.state }
            configuration.applyCredential(username: username, password: password)
            state = .issued
            return configuration
        }
    }
    func cancel() { queue.async { self.revokeOnQueue() } }
    func stop() async {
        let pending: [Task<Void, Never>] = await withCheckedContinuation { continuation in
            queue.async {
                let pending = Array(self.tasks.values)
                self.revokeOnQueue(); continuation.resume(returning: pending)
            }
        }
        for task in pending { await task.value }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func activeConnectionCount() async -> Int {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.tasks.count) } }
    }
    /// Fault injection for this DEBUG-only qualification surface: cancellation
    /// must travel through the real NWListener callback, not revoke directly.
    func cancelListenerForQualification() { queue.async { self.listener.cancel() } }
    func isRevokedForQualification() -> Bool { queue.sync { state == .revoked } }
    func qualificationSnapshot() -> QualificationSnapshot {
        queue.sync { .init(accepted: accepted, malformed: malformed, authenticationRefused: authenticationRefused, established: established) }
    }
    private func revokeOnQueue() {
        guard state != .revoked else { return }
        state = .revoked
        startDeadline?.cancel(); startDeadline = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        let finish = startFinish; startFinish = nil; finish?(.failure(Failure.unavailable))
        for task in tasks.values { task.cancel() }
    }
    private func permits(_ supplied: Data?) -> Bool {
        queue.sync {
            guard state == .issued, let supplied, supplied.count == authorization.count else { return false }
            var difference: UInt8 = 0
            for (a, b) in zip(supplied, authorization) { difference |= a ^ b }
            return difference == 0
        }
    }
    private func accept(_ connection: NWConnection) {
        guard state == .issued, tasks.count < 8,
              case .hostPort(let host, _) = connection.endpoint,
              host == NWEndpoint.Host("127.0.0.1") else { connection.cancel(); return }
        accepted += 1
        let id = UUID(), front = ProxyRelayUpstreamTransport(accepted: connection)
        // This transport can connect only to the configured upstream. It never
        // resolves or connects to the requested destination itself.
        let back = ProxyRelayUpstreamTransport(kind: upstreamKind, upstream: upstream)
        tasks[id] = Task.detached { [self] in
            defer { front.cancel(); back.cancel(); queue.async { self.tasks.removeValue(forKey: id) } }
            do {
                try await withTaskCancellationHandler {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    func remaining() throws -> TimeInterval {
                        let components = ContinuousClock.now.duration(to: deadline).components
                        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                        guard seconds > 0 else { throw Failure.unavailable }; return seconds
                    }
                    try await front.open(timeout: remaining())
                    var buffer = Data(), request: WebKitProxyConnectCodec.Request?
                    while request == nil {
                        let chunk = try await front.receive(maximumBytes: 1024, timeout: remaining())
                        guard !chunk.data.isEmpty, buffer.count + chunk.data.count <= WebKitProxyConnectCodec.maximumHeaderBytes + 1024 else { throw Failure.refused }
                        buffer.append(chunk.data)
                        do { request = try WebKitProxyConnectCodec.request(buffer) }
                        catch { queue.sync { self.malformed += 1 }; throw error }
                    }
                    guard let request else { throw Failure.refused }
                    guard permits(request.authorization) else {
                        queue.sync { self.authenticationRefused += 1 }
                        try await front.send(WebKitProxyConnectCodec.authenticationRequired, timeout: remaining())
                        try await front.finishWrite(timeout: remaining()); return
                    }
                    try Task.checkCancellation()
                    let early = try await back.establish(destination: request.destination, credentials: credentials,
                        timeout: remaining(), authorizeCredentials: { self.permits(request.authorization) })
                    guard permits(request.authorization) else { throw Failure.refused }
                    queue.sync { self.established += 1 }
                    try await front.send(WebKitProxyConnectCodec.established, timeout: remaining())
                    if !early.isEmpty { try await front.send(early) }
                    let payload = Data(buffer.dropFirst(request.consumed))
                    if !payload.isEmpty { try await back.send(payload) }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await Self.copy(front, back) }
                        group.addTask { try await Self.copy(back, front) }
                        do { while try await group.next() != nil {} }
                        catch { front.cancel(); back.cancel(); group.cancelAll(); throw error }
                    }
                } onCancel: { front.cancel(); back.cancel() }
            } catch { /* Intentionally no payload/credential/native-error log. */ }
        }
    }
    private static func copy(_ from: ProxyRelayUpstreamTransport, _ to: ProxyRelayUpstreamTransport) async throws {
        while true {
            try Task.checkCancellation()
            let chunk = try await from.receive(timeout: nil)
            if !chunk.data.isEmpty { try await to.send(chunk.data) }
            if chunk.endOfStream { try await to.finishWrite(); return }
        }
    }
}
#endif
