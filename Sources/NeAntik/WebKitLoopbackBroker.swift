import Foundation
import Network

/// Shared fixed-port broker for the owned WebKit sandbox. Not wired to public
/// launch until the child/store/DNS and exact-runtime gates are qualified.
/// It binds IPv4 loopback exclusively; port ownership is checked by its signed
/// controller before any capability is sent to a child. It is not an OS PID
/// identity boundary. Chromium's existing relay is deliberately independent.
final class WebKitLoopbackBroker: @unchecked Sendable {
    static let sandboxPort: UInt16 = 58631
    static let maximumConnections = 128
    static let maximumConnectionsPerProfile = 8
    enum Failure: Error { case state, unavailable, refused, limit }
    private enum State { case created, starting, ready, stopped }
    private struct Connection {
        var scope: WebKitRelayAuthority.Scope?
        let task: Task<Void, Never>
    }
    private let authority = WebKitRelayAuthority()
    private let queue = DispatchQueue(label: "app.neantik.webkit.broker")
    private let listener: NWListener
    private var state: State = .created
    private var port: UInt16?
    private var connections: [UUID: Connection] = [:]
    private var startFinish: ((Result<UInt16, Error>) -> Void)?
    private var deadline: DispatchWorkItem?

    convenience init() throws { try self.init(port: NWEndpoint.Port(rawValue: Self.sandboxPort)!) }
    private init(port: NWEndpoint.Port) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: port)
        // Never join an unrelated listener or share a fixed policy endpoint.
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
    }
    #if DEBUG
    /// Socket tests choose an ephemeral port; production policy remains fixed.
    convenience init(qualificationPort: NWEndpoint.Port) throws { try self.init(port: qualificationPort) }
    #endif

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.state == .created else { continuation.resume(throwing: Failure.state); return }
                    self.state = .starting; self.startFinish = { continuation.resume(with: $0) }
                    let deadline = DispatchWorkItem { [weak self] in self?.stopOnQueue() }
                    self.deadline = deadline; self.queue.asyncAfter(deadline: .now() + 5, execute: deadline)
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self, self.state != .stopped else { return }
                        switch state {
                        case .ready:
                            guard self.state == .starting, let port = self.listener.port?.rawValue, port > 0 else {
                                self.stopOnQueue(); return
                            }
                            self.state = .ready; self.port = port
                            self.deadline?.cancel(); self.deadline = nil
                            let finish = self.startFinish; self.startFinish = nil; finish?(.success(port))
                        case .failed, .cancelled: self.stopOnQueue()
                        default: break
                        }
                    }
                    self.listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }; self.accept(connection)
                    }
                    self.listener.start(queue: self.queue)
                }
            }
        } onCancel: { self.cancel() }
    }

    func register(scope: WebKitRelayAuthority.Scope, route: WebKitRelayAuthority.Route) throws {
        try queue.sync {
            guard state == .ready else { throw Failure.state }
            try authority.register(scope: scope, route: route)
        }
    }
    func issue(for scope: WebKitRelayAuthority.Scope) throws -> WebKitRelayAuthority.Capability {
        try queue.sync {
            guard state == .ready else { throw Failure.state }
            return try authority.issue(for: scope)
        }
    }
    /// Revoke before cancelling sockets. A stale auth cannot race a reconnect
    /// or a final upstream credential write after this queue fence.
    func revoke(_ scope: WebKitRelayAuthority.Scope) async {
        let tasks: [Task<Void, Never>] = await withCheckedContinuation { continuation in
            queue.async {
                self.authority.revoke(scope)
                let tasks = self.connections.values.filter { $0.scope == scope }.map(\.task)
                tasks.forEach { $0.cancel() }; continuation.resume(returning: tasks)
            }
        }
        for task in tasks { await task.value }
        await fence()
    }
    func cancel() { queue.async { self.stopOnQueue() } }
    func stop() async {
        let tasks: [Task<Void, Never>] = await withCheckedContinuation { continuation in
            queue.async {
                let tasks = self.connections.values.map(\.task)
                self.stopOnQueue(); continuation.resume(returning: tasks)
            }
        }
        for task in tasks { await task.value }
        await fence()
    }
    func activeConnectionCount() async -> Int {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.connections.count) } }
    }
    private func fence() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    private func stopOnQueue() {
        guard state != .stopped else { return }
        state = .stopped; authority.close(); port = nil
        deadline?.cancel(); deadline = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        let finish = startFinish; startFinish = nil; finish?(.failure(Failure.unavailable))
        for connection in connections.values { connection.task.cancel() }
    }

    private func bind(_ permit: WebKitRelayAuthority.Permit, connectionID: UUID) throws {
        try queue.sync {
            guard state == .ready, authority.isCurrent(permit), var entry = connections[connectionID] else { throw Failure.refused }
            guard connections.values.filter({ $0.scope == permit.scope }).count < Self.maximumConnectionsPerProfile else { throw Failure.limit }
            entry.scope = permit.scope; connections[connectionID] = entry
        }
    }
    private func accept(_ connection: NWConnection) {
        guard state == .ready, connections.count < Self.maximumConnections,
              case .hostPort(let host, _) = connection.endpoint, host == NWEndpoint.Host("127.0.0.1")
        else { connection.cancel(); return }
        let id = UUID(), front = ProxyRelayUpstreamTransport(accepted: connection)
        let task = Task.detached { [self] in
            defer { front.cancel(); queue.async { self.connections.removeValue(forKey: id) } }
            do {
                try await withTaskCancellationHandler {
                    let end = ContinuousClock.now.advanced(by: .seconds(5))
                    func remaining() throws -> TimeInterval {
                        let value = ContinuousClock.now.duration(to: end).components
                        let seconds = Double(value.seconds) + Double(value.attoseconds) / 1e18
                        guard seconds > 0 else { throw Failure.unavailable }; return seconds
                    }
                    try await front.open(timeout: remaining())
                    var buffer = Data()
                    let request: WebKitProxyConnectCodec.Request
                    while true {
                        if let parsed = try WebKitProxyConnectCodec.request(buffer) { request = parsed; break }
                        guard buffer.count < WebKitProxyConnectCodec.maximumHeaderBytes else { throw Failure.refused }
                        let chunk = try await front.receive(maximumBytes: min(1024, WebKitProxyConnectCodec.maximumHeaderBytes - buffer.count), timeout: remaining())
                        guard !chunk.data.isEmpty else { throw Failure.refused }; buffer.append(chunk.data)
                    }
                    guard let permit = authority.authorize(request.authorization) else {
                        try await front.send(WebKitProxyConnectCodec.authenticationRequired, timeout: remaining())
                        try await front.finishWrite(timeout: remaining()); return
                    }
                    try bind(permit, connectionID: id)
                    buffer = Data(buffer.dropFirst(request.consumed))
                    let back: ProxyRelayUpstreamTransport
                    switch permit.route {
                    case .direct: back = ProxyRelayUpstreamTransport(kind: .http, upstream: request.destination)
                    case .proxy(let kind, let upstream, _): back = ProxyRelayUpstreamTransport(kind: kind, upstream: upstream)
                    }
                    defer { back.cancel() }
                    try await withTaskCancellationHandler {
                        let early: Data
                        switch permit.route {
                        case .direct:
                            guard authority.isCurrent(permit) else { throw Failure.refused }
                            try Task.checkCancellation(); try await back.open(timeout: remaining()); early = Data()
                        case .proxy(_, _, let credentials):
                            early = try await back.establish(destination: request.destination, credentials: credentials,
                                timeout: remaining(), authorizeCredentials: { self.authority.isCurrent(permit) })
                        }
                        try Task.checkCancellation()
                        guard authority.isCurrent(permit) else { throw Failure.refused }
                        try await front.send(WebKitProxyConnectCodec.established, timeout: remaining())
                        if !early.isEmpty { try await front.send(early) }
                        if !buffer.isEmpty { try await back.send(buffer) }
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await Self.copy(front, back) }
                            group.addTask { try await Self.copy(back, front) }
                            do { while try await group.next() != nil {} }
                            catch { front.cancel(); back.cancel(); group.cancelAll(); throw error }
                        }
                    } onCancel: { back.cancel(); front.cancel() }
                } onCancel: { front.cancel() }
            } catch { /* Deliberately no payload, destination, native error or credential log. */ }
        }
        connections[id] = Connection(scope: nil, task: task)
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
