import Foundation
import Network

/// Shared fixed-port broker for the owned WebKit sandbox. Not wired to public
/// launch until the child/store/DNS and exact-runtime gates are qualified.
/// It binds IPv4 loopback exclusively; port ownership is checked by its signed
/// controller before any capability is sent to a child. It is not an OS PID
/// identity boundary. Chromium's existing relay is deliberately independent.
final class WebKitLoopbackBroker: @unchecked Sendable {
    // Keep the service socket outside the OS ephemeral range so unrelated
    // outbound connections cannot randomly reserve the fixed sandbox endpoint.
    static let sandboxPort: UInt16 = WebKitBrokerPort.sandboxPort
    static let maximumConnections = 128
    static let maximumConnectionsPerProfile = 8
    enum Failure: Error, LocalizedError, Equatable {
        case state, unavailable, refused, limit
        case listenerStartFailed(diagnostic: String)
        case listenerStartTimedOut
        case listenerStartCancelled

        var errorDescription: String? {
            switch self {
            case .state: "Локальный WebKit-маршрут уже запущен или остановлен."
            case .unavailable: "Локальный WebKit-маршрут недоступен. Профиль не запущен."
            case .refused: "Локальный WebKit-маршрут отклонил запрос. Профиль не запущен."
            case .limit: "Достигнут лимит соединений WebKit-маршрута."
            case .listenerStartFailed(let diagnostic):
                "Не удалось запустить локальный WebKit-маршрут (\(diagnostic)). Профиль не запущен."
            case .listenerStartTimedOut:
                "Локальный WebKit-маршрут не запустился вовремя. Профиль не запущен."
            case .listenerStartCancelled:
                "Запуск локального WebKit-маршрута отменён. Профиль не запущен."
            }
        }
    }
    private enum State { case created, starting, ready, stopped }
    private struct Connection {
        var scope: WebKitRelayAuthority.Scope?
        let task: Task<Void, Never>
    }
    private let authority = WebKitRelayAuthority()
    private var processLeases: [UUID: WebKitNetworkProcessCodeIdentity.Lease] = [:]
    private let queue = DispatchQueue(label: "app.neantik.webkit.broker")
    private let leaseMonitorQueue = DispatchQueue(label: "app.neantik.webkit.broker.lease-monitor", qos: .utility)
    private let listener: NWListener
    private var state: State = .created
    private var port: UInt16?
    private var preparedScopes: [UUID: WebKitRelayAuthority.Scope] = [:]
    private var connections: [UUID: Connection] = [:]
    private var startFinish: ((Result<UInt16, Error>) -> Void)?
    private var deadline: DispatchWorkItem?
    private var leaseMonitor: DispatchSourceTimer?
    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
    struct QACounters: Equatable {
        let inbound: Int
        let loopback: Int
        let parsed: Int
        let authorized: Int
        let bound: Int
    }
    private var qaInbound = 0
    private var qaLoopback = 0
    private var qaParsed = 0
    private var qaAuthorized = 0
    private var qaBound = 0

    /// Counts only protocol boundaries. No URL, address, credential or error
    /// payload enters the private QA receipt.
    func qaCounters() -> QACounters {
        queue.sync { QACounters(inbound: qaInbound, loopback: qaLoopback,
                                parsed: qaParsed, authorized: qaAuthorized,
                                bound: qaBound) }
    }
    #endif

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
                    let deadline = DispatchWorkItem { [weak self] in
                        self?.stopOnQueue(startFailure: Failure.listenerStartTimedOut)
                    }
                    self.deadline = deadline; self.queue.asyncAfter(deadline: .now() + 5, execute: deadline)
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self, self.state != .stopped else { return }
                        switch state {
                        case .ready:
                            guard self.state == .starting, let port = self.listener.port?.rawValue, port > 0 else {
                                self.stopOnQueue(startFailure: Failure.listenerStartFailed(diagnostic: "READY_NO_PORT")); return
                            }
                            self.state = .ready; self.port = port
                            self.deadline?.cancel(); self.deadline = nil
                            let finish = self.startFinish; self.startFinish = nil; finish?(.success(port))
                        case .failed(let error):
                            self.stopOnQueue(startFailure: Self.listenerStartFailure(error))
                        case .cancelled:
                            self.stopOnQueue(startFailure: Failure.listenerStartCancelled)
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

    /// Stage one route and return its session-scoped credential to the already
    /// authenticated host. A connection using it is still rejected until
    /// `activate` installs the matching live NetworkProcess lease.
    func prepare(scope: WebKitRelayAuthority.Scope,
                 route: WebKitRelayAuthority.Route) throws -> WebKitRelayAuthority.Capability {
        try queue.sync {
            guard state == .ready else { throw Failure.state }
            guard preparedScopes[scope.profileID] == nil,
                  processLeases[scope.profileID] == nil else { throw Failure.refused }
            try authority.register(scope: scope, route: route)
            let capability: WebKitRelayAuthority.Capability
            do { capability = try authority.issue(for: scope) }
            catch { authority.revoke(scope); throw error }
            preparedScopes[scope.profileID] = scope
            return capability
        }
    }

    /// Activate a staged route only after the host reports and authenticates
    /// the NetworkProcess started with that credential. Before this succeeds,
    /// `bind` rejects every authenticated CONNECT and opens no upstream socket.
    func activate(scope: WebKitRelayAuthority.Scope,
                  lease: WebKitNetworkProcessCodeIdentity.Lease) throws {
        guard lease.scope == scope, lease.authorizes(scope) else { throw Failure.refused }
        try queue.sync {
            guard state == .ready else { throw Failure.state }
            guard preparedScopes[scope.profileID] == scope,
                  processLeases[scope.profileID] == nil else { throw Failure.refused }
            processLeases[scope.profileID] = lease
            startLeaseMonitorOnQueue()
        }
    }

    /// Select stale leases independently of socket state. Kept pure so expiry
    /// policy has a focused test that does not depend on loopback permissions.
    static func expiredLeaseScopes(
        _ leases: [WebKitNetworkProcessCodeIdentity.Lease]
    ) -> [WebKitRelayAuthority.Scope] {
        expiredLeases(leases).map(\.scope)
    }

    private static func expiredLeases(
        _ leases: [WebKitNetworkProcessCodeIdentity.Lease]
    ) -> [WebKitNetworkProcessCodeIdentity.Lease] {
        leases.filter { !$0.authorizes($0.scope) }
    }

    private func startLeaseMonitorOnQueue() {
        guard leaseMonitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: leaseMonitorQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.checkLeasesOffQueue() }
        leaseMonitor = timer
        timer.resume()
    }

    /// Check potentially expensive SecCode/kernel attestations away from the
    /// listener queue, then revoke only if the exact session is still current.
    private func checkLeasesOffQueue() {
        let snapshot: [WebKitNetworkProcessCodeIdentity.Lease] = queue.sync {
            guard state == .ready else { return [] }
            return Array(processLeases.values)
        }
        let expired = Self.expiredLeases(snapshot)
        guard !expired.isEmpty else { return }
        queue.async {
            for lease in expired {
                let scope = lease.scope
                guard self.state == .ready,
                      self.processLeases[scope.profileID] === lease else { continue }
                // The expensive live attestation was checked on the utility
                // queue. Identity fences a replacement lease even for the same
                // blocking listener work on a second SecCode inspection.
                self.revokeExpiredLeaseOnQueue(scope)
            }
        }
    }

    private func revokeExpiredLeaseOnQueue(_ scope: WebKitRelayAuthority.Scope) {
        authority.revoke(scope)
        processLeases.removeValue(forKey: scope.profileID)
        preparedScopes.removeValue(forKey: scope.profileID)
        // Revoke first, then cancel every already-authorized tunnel. New
        // handshakes fail authorization while these tasks unwind.
        for connection in connections.values where connection.scope == scope {
            connection.task.cancel()
        }
    }

    #if DEBUG
    /// Socket-fixture route registration. The production API has no
    /// unauthenticated registration overload.
    @discardableResult
    func registerForTesting(scope: WebKitRelayAuthority.Scope,
                            route: WebKitRelayAuthority.Route) throws
        -> WebKitRelayAuthority.Capability {
        let capability = try prepare(scope: scope, route: route)
        try activateForTesting(scope: scope, isCurrent: { true })
        return capability
    }
    /// Staging test intentionally delays process-owner activation.
    func activateForTesting(scope: WebKitRelayAuthority.Scope,
                            isCurrent: @escaping @Sendable () -> Bool) throws {
        let fixture = WebKitHostIPC.Session(profileID: scope.profileID,
            revision: scope.revision, generation: scope.sessionID,
            dataRoot: "/tmp/neantik-webkit-broker-fixture",
            runtimeSHA256: String(repeating: "a", count: 64))
        try activate(scope: scope, lease: .fixture(session: fixture, isCurrent: isCurrent))
    }
    #endif
    /// Revoke before cancelling sockets. A stale auth cannot race a reconnect
    /// or a final upstream credential write after this queue fence.
    func revoke(_ scope: WebKitRelayAuthority.Scope) async {
        let tasks: [Task<Void, Never>] = await withCheckedContinuation { continuation in
            queue.async {
                self.authority.revoke(scope)
                self.processLeases.removeValue(forKey: scope.profileID)
                self.preparedScopes.removeValue(forKey: scope.profileID)
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
    static func listenerStartFailure(_ error: NWError) -> Failure {
        let diagnostic: String
        switch error {
        case .posix(let code): diagnostic = "POSIX-\(code.rawValue)"
        case .dns(let code): diagnostic = "DNS-\(code)"
        case .tls(let code): diagnostic = "TLS-\(code)"
        @unknown default: diagnostic = "NETWORK-UNKNOWN"
        }
        return .listenerStartFailed(diagnostic: diagnostic)
    }

    private func stopOnQueue(startFailure: Error = Failure.unavailable) {
        guard state != .stopped else { return }
        state = .stopped; authority.close(); processLeases.removeAll()
        preparedScopes.removeAll(); port = nil
        leaseMonitor?.setEventHandler {}; leaseMonitor?.cancel(); leaseMonitor = nil
        deadline?.cancel(); deadline = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        let finish = startFinish; startFinish = nil; finish?(.failure(startFailure))
        for connection in connections.values { connection.task.cancel() }
    }

    private func bind(_ permit: WebKitRelayAuthority.Permit, connectionID: UUID) throws {
        let lease = try queue.sync {
            guard state == .ready, authority.isCurrent(permit), connections[connectionID] != nil,
                  let lease = processLeases[permit.scope.profileID], lease.scope == permit.scope
            else { throw Failure.refused }
            return lease
        }
        guard lease.authorizes(permit.scope) else {
            queue.sync {
                if processLeases[permit.scope.profileID] === lease {
                    revokeExpiredLeaseOnQueue(permit.scope)
                }
            }
            throw Failure.refused
        }
        try queue.sync {
            guard state == .ready, authority.isCurrent(permit),
                  processLeases[permit.scope.profileID] === lease,
                  var entry = connections[connectionID] else { throw Failure.refused }
            guard connections.values.filter({ $0.scope == permit.scope }).count < Self.maximumConnectionsPerProfile else { throw Failure.limit }
            entry.scope = permit.scope; connections[connectionID] = entry
            #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
            qaBound += 1
            #endif
        }
    }
    private func accept(_ connection: NWConnection) {
        #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
        qaInbound += 1
        #endif
        guard state == .ready, connections.count < Self.maximumConnections,
              case .hostPort(let host, _) = connection.endpoint, host == NWEndpoint.Host("127.0.0.1")
        else { connection.cancel(); return }
        #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
        qaLoopback += 1
        #endif
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
                    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
                    queue.sync { qaParsed += 1 }
                    #endif
                    guard let permit = authority.authorize(request.authorization) else {
                        try await front.send(WebKitProxyConnectCodec.authenticationRequired, timeout: remaining())
                        try await front.finishWrite(timeout: remaining()); return
                    }
                    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
                    queue.sync { qaAuthorized += 1 }
                    #endif
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

/// Owns the single fixed-port listener shared by all isolated WebKit profiles
/// in one manager. The broker itself separates sessions by scoped capability;
/// creating one broker per profile would make every profile contend for the
/// same sandbox-allowed loopback port.
@MainActor
final class WebKitLoopbackBrokerPool {
    typealias Factory = () throws -> WebKitLoopbackBroker

    private let makeBroker: Factory
    private var broker: WebKitLoopbackBroker?
    private var startTask: Task<UInt16, Error>?
    private var stopTask: Task<Void, Never>?

    init(makeBroker: @escaping Factory = { try WebKitLoopbackBroker() }) {
        self.makeBroker = makeBroker
    }

    /// Concurrent profile launches await one listener startup and receive the
    /// same broker instance. A stopped listener is fully drained before a new
    /// one can bind the fixed sandbox endpoint.
    func acquire() async throws -> WebKitLoopbackBroker {
        if let stopTask { await stopTask.value }

        if let broker {
            if let startTask { _ = try await startTask.value }
            return broker
        }

        let broker = try makeBroker()
        self.broker = broker
        let startTask = Task { try await broker.start() }
        self.startTask = startTask
        do {
            _ = try await startTask.value
            if self.broker === broker { self.startTask = nil }
            return broker
        } catch {
            if self.broker === broker {
                self.broker = nil
                self.startTask = nil
            }
            await broker.stop()
            throw error
        }
    }

    /// Stop the fixed listener only after all profile launches and sessions
    /// have settled. If another launch races with stop, acquire waits for the
    /// stop task before binding a new listener.
    func stopIfIdle(_ isIdle: Bool) async {
        guard isIdle else { return }
        if let stopTask { await stopTask.value; return }
        guard let broker else { return }

        let task = Task { @MainActor [weak self] in
            await broker.stop()
            guard let self, self.broker === broker else { return }
            self.broker = nil
            self.startTask = nil
            self.stopTask = nil
        }
        stopTask = task
        await task.value
    }
}
