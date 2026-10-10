import Foundation
import Network

/// Development listener only. No production profile/config/MCP path enables
/// it. A caller must supply a bounded, revocable browser-session admission
/// function; loopback address and anonymous SOCKS method are not authority.
final class ProxyRelayLoopbackServer: @unchecked Sendable {
    struct Peer: Sendable, CustomStringConvertible, CustomReflectable {
        let clientPort: UInt16
        let relayPort: UInt16
        var description: String { "ProxyRelayPeer(<redacted>)" }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    enum Failure: Error { case invalidLimit, unavailable, closed, refused, malformed }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.neantik.relay.loopback")
    private let upstreamKind: ProxyKind
    private let upstream: ProxyRelayDestination
    private let credentials: ProxyRelayCredentials?
    private let admit: @Sendable (Peer) throws -> Bool
    private let limit: Int
    private var sessions: [UUID: Task<Void, Never>] = [:]
    private var port: UInt16?
    private var stopped = false
    private var stopError: Error?
    private var starting = false
    private var startFinish: ((Result<UInt16, Error>) -> Void)?
    private var startDeadline: DispatchWorkItem?

    init(upstreamKind: ProxyKind, upstream: ProxyRelayDestination, credentials: ProxyRelayCredentials?,
         maximumConnections: Int = 8, admit: @escaping @Sendable (Peer) throws -> Bool) throws {
        guard (1...64).contains(maximumConnections) else { throw Failure.invalidLimit }
        self.upstreamKind = upstreamKind; self.upstream = upstream; self.credentials = credentials
        limit = maximumConnections; self.admit = admit
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped, !self.starting else { continuation.resume(throwing: self.stopError ?? Failure.closed); return }
                    self.starting = true
                    self.startFinish = { continuation.resume(with: $0) }
                    let deadline = DispatchWorkItem { [weak self] in self?.stopOnQueue(error: Failure.unavailable) }
                    self.startDeadline = deadline; self.queue.asyncAfter(deadline: .now() + 5, execute: deadline)
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.stopped else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener.port?.rawValue, port > 0 else { self.stopOnQueue(error: Failure.unavailable); return }
                            self.port = port; self.startDeadline?.cancel(); self.startDeadline = nil
                            let finish = self.startFinish; self.startFinish = nil; finish?(.success(port))
                        case .failed: self.stopOnQueue(error: Failure.unavailable)
                        case .cancelled: self.stopOnQueue(error: Failure.closed)
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
    func cancel() { queue.async { self.stopOnQueue(error: CancellationError()) } }
    func stop() async {
        let tasks: [Task<Void, Never>] = await withCheckedContinuation { continuation in
            queue.async { let tasks = Array(self.sessions.values); self.stopOnQueue(error: CancellationError()); continuation.resume(returning: tasks) }
        }
        for task in tasks { await task.value }
        // Each session enqueues removal before its Task completes. Fence that
        // queue so stop returning also proves those entries are released.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func activeConnectionCount() async -> Int {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.sessions.count) } }
    }
    private func stopOnQueue(error: Error) {
        guard !stopped else { return }
        stopped = true; stopError = error; startDeadline?.cancel(); startDeadline = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        let finish = startFinish; startFinish = nil; finish?(.failure(error))
        for task in sessions.values { task.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, let port, sessions.count < limit,
              case .hostPort(let host, let clientPort) = connection.endpoint,
              host == NWEndpoint.Host("127.0.0.1"), clientPort.rawValue > 0
        else { connection.cancel(); return }
        let peer = Peer(clientPort: clientPort.rawValue, relayPort: port), id = UUID()
        let front = ProxyRelayUpstreamTransport(accepted: connection)
        let back = ProxyRelayUpstreamTransport(kind: upstreamKind, upstream: upstream)
        sessions[id] = Task.detached { [self] in
            defer { front.cancel(); back.cancel(); queue.async { self.sessions.removeValue(forKey: id) } }
            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    let handshakeDeadline = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 + 10
                    func remaining() throws -> TimeInterval {
                        let value = handshakeDeadline - Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                        guard value > 0 else { throw ProxyRelayTransportError.timeout }
                        return value
                    }
                    guard try admit(peer) else { throw Failure.refused }
                    try await front.open(timeout: remaining())
                    var buffer = Data()
                    func more() async throws {
                        let chunk = try await front.receive(maximumBytes: 1024, timeout: remaining())
                        guard !chunk.data.isEmpty, buffer.count + chunk.data.count <= 4096 else { throw Failure.malformed }
                        buffer.append(chunk.data)
                    }
                    var greeting: ProxyRelayClientWireCodec.Greeting?
                    while greeting == nil { greeting = try ProxyRelayClientWireCodec.greeting(buffer); if greeting == nil { try await more() } }
                    let method = greeting!.selectedMethod; buffer.removeFirst(greeting!.consumed)
                    try await front.send(Data([5, method]), timeout: remaining())
                    guard method == 0 else { throw Failure.refused }
                    var request: ProxyRelayClientWireCodec.Connect?
                    while request == nil { request = try ProxyRelayClientWireCodec.connect(buffer); if request == nil { try await more() } }
                    let destination = request!.destination; buffer.removeFirst(request!.consumed)
                    // Repeat admission after parsing and immediately before
                    // the only operation that may send upstream credentials.
                    try Task.checkCancellation(); guard try admit(peer) else { throw Failure.refused }
                    let early = try await back.establish(destination: destination, credentials: credentials, timeout: remaining(),
                                                         authorizeCredentials: { try self.admit(peer) })
                    let bound = try await back.localBoundEndpoint()
                    let boundFrame = try ProxyRelayWireCodec.socksConnect(bound)
                    try await front.send(Data([5,0,0]) + boundFrame.dropFirst(3), timeout: remaining())
                    if !early.isEmpty { try await front.send(early) }
                    if !buffer.isEmpty { try await back.send(buffer) }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await Self.copy(front, back) }
                        group.addTask { try await Self.copy(back, front) }
                        do { while try await group.next() != nil {} }
                        catch { front.cancel(); back.cancel(); group.cancelAll(); throw error }
                    }
                } onCancel: { front.cancel(); back.cancel() }
            } catch { /* No payload, destinations, credentials or native errors logged. */ }
        }
    }
    private static func copy(_ from: ProxyRelayUpstreamTransport, _ to: ProxyRelayUpstreamTransport) async throws {
        while true {
            try Task.checkCancellation()
            // The owning session cancels both directions. A quiet established
            // stream may be a valid WebSocket; only the handshake has an idle
            // deadline. Production browser/session revocation is still a
            // separate gate before this development listener can be enabled.
            let chunk = try await from.receive(timeout: nil)
            if !chunk.data.isEmpty { try await to.send(chunk.data) }
            if chunk.endOfStream { try await to.finishWrite(); return }
        }
    }
}
