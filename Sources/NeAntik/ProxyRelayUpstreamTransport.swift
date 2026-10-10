import Foundation
import Network

enum ProxyRelayTransportError: Error, Equatable {
    case unavailable, posixFailure(Int32), dnsFailure(Int32), tlsFailed, timeout, closed, invalidLimit, invalidOperation, authorizationRejected, concurrentRead, writeFinished, excessiveInformationalResponses
}

/// Development upstream primitive, not a loopback listener or ownership gate.
/// It can dial only the configured upstream. There is no destination/direct
/// retry path. HTTPS uses Network's TLS parameters without a trust override.
/// All connection state and exactly-once continuations belong to one queue.
final class ProxyRelayUpstreamTransport: @unchecked Sendable {
    struct ReadChunk: Sendable { let data: Data; let endOfStream: Bool }
    /// Optional owned-test observer: typed lifecycle only, never addresses,
    /// credentials or payload. The production default emits nothing.
    enum Observation: Sendable {
        case ready, receiveArmed(Int), buffered(Int), received(Int, Bool, Bool, ProxyRelayTransportError?)
        case writeClosed(ProxyRelayTransportError?), failed(ProxyRelayTransportError)
        case credentialWriteEnqueued
    }
    private let observe: (@Sendable (Observation) -> Void)?
    private enum State { case idle, opening, ready, draining, closed }
    private struct Pending { let deadline: DispatchWorkItem?; let read: Bool; let fail: (Error) -> Void }
    private let connection: NWConnection
    private let kind: ProxyKind
    private let allowsUpstreamHandshake: Bool
    private let queue = DispatchQueue(label: "app.neantik.relay.upstream")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var state = State.idle
    private var terminalError: Error?
    private final class CancellationLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private var pending: [UUID: Pending] = [:]
    private var reading = false
    private var writeFinished = false
    // Keep one native receive armed while bounded capacity is available. An
    // async consumer need not race the connection's FIN/state callbacks.
    private var readBuffer = Data()
    private var readEnded = false
    private var readFailure: Error?
    private var nativeStateFailure: Error?
    private var drainDeadline: DispatchWorkItem?
    private var readAborted = false
    private var nativeReadOutstanding = false
    private var readConsumer: (maximum: Int, finish: (Result<ReadChunk, Error>) -> Void)?
    private static let readBufferLimit = 128 * 1024

    init(kind: ProxyKind, upstream: ProxyRelayDestination, observe: (@Sendable (Observation) -> Void)? = nil) {
        self.observe = observe
        self.kind = kind; allowsUpstreamHandshake = true
        connection = NWConnection(host: NWEndpoint.Host(upstream.host), port: NWEndpoint.Port(rawValue: upstream.port)!,
                                  using: kind == .https ? .tls : .tcp)
        queue.setSpecific(key: queueKey, value: 1)
    }
    /// Only the internal loopback listener may wrap an accepted client.
    /// This stream cannot be used to send an upstream authentication frame.
    init(accepted: NWConnection) {
        kind = .http; allowsUpstreamHandshake = false; observe = nil
        connection = accepted
        queue.setSpecific(key: queueKey, value: 1)
    }
    func localBoundEndpoint() async throws -> ProxyRelayDestination {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.state == .ready || self.state == .draining,
                      case .hostPort(let host, let port)? = self.connection.currentPath?.localEndpoint,
                      let destination = try? ProxyRelayDestination(host: String(describing: host), port: Int(port.rawValue))
                else { continuation.resume(throwing: ProxyRelayTransportError.unavailable); return }
                continuation.resume(returning: destination)
            }
        }
    }
    func cancel() { queue.async { self.close(CancellationError()) } }

    func open(timeout: TimeInterval = 10) async throws {
        let _: Void = try await operation(timeout: timeout, opening: true) { finish, _ in
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.state != .closed, self.state != .draining else { return }
                switch state {
                case .ready: self.state = .ready; self.observe?(.ready); self.armReceive(); finish(.success(()))
                case .failed(let error): self.observe?(.failed(self.failure(error))); self.handleNativeFailure(self.failure(error))
                // Waiting after a failed trust/connect attempt must not be
                // retried invisibly or mislabeled as a generic timeout.
                case .waiting(let error): self.close(self.failure(error))
                case .cancelled: self.close(ProxyRelayTransportError.closed)
                default: break // Waiting is bounded by this operation's deadline.
                }
            }
            self.connection.start(queue: self.queue)
        }
    }
    func send(_ data: Data, timeout: TimeInterval = 10) async throws {
        try await send(data, timeout: timeout, authorize: nil)
    }
    private func send(_ data: Data, timeout: TimeInterval, authorize: (@Sendable () throws -> Bool)?) async throws {
        guard data.count <= 256 * 1024 else { throw ProxyRelayTransportError.invalidLimit }
        let _: Void = try await operation(timeout: timeout) { finish, isCancelled in
            guard !self.writeFinished else { finish(.failure(ProxyRelayTransportError.writeFinished)); return }
            // Admission is synchronous on this connection's owning queue.
            // No await/queue hop lies between the fresh check and enqueueing
            // the credential-bearing frame. This is point-in-time admission,
            // not a lease or a substitute for revoking an established stream.
            do { if let authorize, try !authorize() { throw ProxyRelayTransportError.authorizationRejected } }
            catch { finish(.failure(error)); return }
            guard !isCancelled() else { finish(.failure(CancellationError())); return }
            if authorize != nil { self.observe?(.credentialWriteEnqueued) }
            self.connection.send(content: data, completion: .contentProcessed { error in
                if let error { finish(.failure(self.failure(error))) } else { finish(.success(())) }
            })
        }
    }
    func finishWrite(timeout: TimeInterval = 10) async throws {
        let _: Void = try await operation(timeout: timeout) { finish, _ in
            guard !self.writeFinished else { finish(.failure(ProxyRelayTransportError.writeFinished)); return }
            self.writeFinished = true
            self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                self.observe?(.writeClosed(error.map(self.failure)))
                if let error { finish(.failure(self.failure(error))) } else { finish(.success(())) }
            })
        }
    }
    /// A nil idle deadline is permitted only for an established stream read.
    /// Its owning session must cancel it on revocation/exit; connect, auth and
    /// writes remain bounded. Silence on a tunnel is not a network failure.
    func receive(maximumBytes: Int = 64 * 1024, timeout: TimeInterval? = 10) async throws -> ReadChunk {
        guard (1...64 * 1024).contains(maximumBytes) else { throw ProxyRelayTransportError.invalidLimit }
        return try await operation(timeout: timeout, cachedRead: true) { finish, _ in
            guard !self.reading else { finish(.failure(ProxyRelayTransportError.concurrentRead)); return }
            self.reading = true
            self.readConsumer = (maximumBytes, finish)
            self.deliverRead()
            self.armReceive()
        }
    }

    private func armReceive() {
        guard (state == .ready || state == .draining), !nativeReadOutstanding, !readEnded, readFailure == nil,
              readBuffer.count < Self.readBufferLimit else { return }
        nativeReadOutstanding = true
        let capacity = min(64 * 1024, Self.readBufferLimit - readBuffer.count)
        observe?(.receiveArmed(capacity))
        if state == .draining { scheduleDrainDeadline() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: capacity) { data, context, complete, error in
            self.observe?(.received(data?.count ?? 0, complete, context?.isFinal == true, error.map(self.failure)))
            self.nativeReadOutstanding = false
            self.drainDeadline?.cancel(); self.drainDeadline = nil
            guard !self.readAborted else { return }
            if let data { self.readBuffer.append(data) }; self.observe?(.buffered(self.readBuffer.count))
            if error == nil && complete && context?.isFinal == true { self.readEnded = true }
            if let error { self.readFailure = self.failure(error) }
            // Re-arm before waking the async consumer. A completed write
            // must not create a gap in which the remote FIN is unobserved.
            if error == nil { self.armReceive() }
            self.deliverRead()
            if let error { self.close(self.failure(error)) }
            else if self.readEnded, let terminal = self.nativeStateFailure { self.close(terminal) }
        }
    }
    private func deliverRead() {
        guard let consumer = readConsumer else { return }
        let result: Result<ReadChunk, Error>
        if !readBuffer.isEmpty {
            let count = min(consumer.maximum, readBuffer.count)
            let data = Data(readBuffer.prefix(count)); readBuffer.removeFirst(count)
            result = .success(ReadChunk(data: data, endOfStream: readEnded && readBuffer.isEmpty))
        } else if readEnded { result = .success(ReadChunk(data: Data(), endOfStream: true)) }
        else if let readFailure { result = .failure(readFailure) }
        else { return }
        readConsumer = nil; reading = false
        consumer.finish(result)
    }

    /// Authenticated handshake preserves any payload coalesced with the final
    /// response. Callers must first prove browser-client ownership, and must
    /// cancel this transport when their session/helper authority ends.
    func establish(destination: ProxyRelayDestination, credentials: ProxyRelayCredentials?, timeout: TimeInterval = 10,
                   authorizeCredentials: @escaping @Sendable () throws -> Bool) async throws -> Data {
        guard allowsUpstreamHandshake else { throw ProxyRelayTransportError.invalidOperation }
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ProxyRelayTransportError.invalidLimit }
        let deadline = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 + timeout
        func remaining() throws -> TimeInterval {
            let value = deadline - Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            guard value > 0 else { throw ProxyRelayTransportError.timeout }
            return value
        }
        // Reject unencodable credentials before connecting or sending secrets.
        let auth = kind == .socks5 ? try credentials.map(ProxyRelayWireCodec.socksAuthentication) : nil
        let request = kind == .socks5 ? try ProxyRelayWireCodec.socksConnect(destination) : try ProxyRelayWireCodec.httpConnect(destination, credentials: credentials)
        do {
            try await open(timeout: remaining())
            var buffer = Data()
            if kind == .socks5 {
                try await send(ProxyRelayWireCodec.socksGreeting(credentials: credentials), timeout: remaining())
                while buffer.count < 2 { try await appendHandshake(&buffer, timeout: remaining()) }
                let method = try ProxyRelayWireCodec.socksSelectedMethod(buffer, credentials: credentials)
                guard buffer.count == 2 else { throw ProxyRelayWireError.malformed }
                buffer.removeAll(keepingCapacity: true)
                if method == .usernamePassword {
                    guard let auth else { throw ProxyRelayWireError.unsupportedMethod }
                    try await send(auth, timeout: remaining(), authorize: authorizeCredentials)
                    while buffer.count < 2 { try await appendHandshake(&buffer, timeout: remaining()) }
                    _ = try ProxyRelayWireCodec.socksAuthenticationAccepted(buffer)
                    guard buffer.count == 2 else { throw ProxyRelayWireError.malformed }
                    buffer.removeAll(keepingCapacity: true)
                }
                try await send(request, timeout: remaining())
                while true {
                    if let count = try ProxyRelayWireCodec.socksConnectReplyLength(buffer) { return Data(buffer.dropFirst(count)) }
                    try await appendHandshake(&buffer, timeout: remaining())
                }
            }
            try await send(request, timeout: remaining(), authorize: credentials == nil ? nil : authorizeCredentials)
            var informational = 0
            while true {
                switch try ProxyRelayWireCodec.httpConnectReply(buffer) {
                case .incomplete: try await appendHandshake(&buffer, timeout: remaining())
                case .informational(let consumed):
                    informational += 1
                    guard informational <= 8 else { throw ProxyRelayTransportError.excessiveInformationalResponses }
                    buffer.removeFirst(consumed)
                case .established(let consumed): return Data(buffer.dropFirst(consumed))
                }
            }
        } catch { cancel(); throw error }
    }
    private func appendHandshake(_ buffer: inout Data, timeout: TimeInterval) async throws {
        let chunk = try await receive(timeout: timeout)
        guard !chunk.data.isEmpty else { throw ProxyRelayTransportError.closed }
        guard buffer.count + chunk.data.count <= ProxyRelayWireCodec.maximumHeaderBytes + 64 * 1024 else {
            throw ProxyRelayTransportError.invalidLimit
        }
        buffer.append(chunk.data)
        // Payload accompanied by EOF remains readable; incomplete framing on
        // EOF fails at the next receive rather than becoming a false success.
    }

    private func operation<T>(timeout: TimeInterval?, opening: Bool = false, cachedRead: Bool = false,
                              body: @escaping (@escaping (Result<T, Error>) -> Void, @escaping @Sendable () -> Bool) -> Void) async throws -> T {
        if let timeout { guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ProxyRelayTransportError.invalidLimit } }
        else { guard cachedRead && !opening else { throw ProxyRelayTransportError.invalidLimit } }
        let cancellation = CancellationLatch()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard opening ? self.state == .idle : (self.state == .ready || (cachedRead && !self.readAborted && (!self.readBuffer.isEmpty || self.readEnded || self.nativeReadOutstanding))) else {
                        continuation.resume(throwing: self.terminalError ?? ProxyRelayTransportError.closed); return
                    }
                    if opening { self.state = .opening }
                    let id = UUID()
                    let deadline = timeout.map { _ in DispatchWorkItem { [weak self = self] in self?.close(ProxyRelayTransportError.timeout) } }
                    self.pending[id] = Pending(deadline: deadline, read: cachedRead, fail: { continuation.resume(throwing: $0) })
                    if let deadline, let timeout { self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline) }
                    body({ result in
                        let settle = {
                            guard let operation = self.pending.removeValue(forKey: id) else { return }
                            operation.deadline?.cancel()
                            switch result {
                            case .success(let value): continuation.resume(returning: value)
                            case .failure(let error):
                                continuation.resume(throwing: error)
                                // Admission errors do not destroy an existing
                                // reader or the usable half of a stream.
                                if (error as? ProxyRelayTransportError) != .concurrentRead && (error as? ProxyRelayTransportError) != .writeFinished { self.close(error) }
                            }
                        }
                        // NW callbacks already run on this queue. Preserve
                        // their order: a later failure must not overtake an
                        // already delivered receive/send completion.
                        if DispatchQueue.getSpecific(key: self.queueKey) != nil { settle() }
                        else { self.queue.async(execute: settle) }
                    }, { cancellation.isCancelled })
                }
            }
        }, onCancel: { cancellation.cancel(); self.cancel() })
    }
    private func failure(_ error: NWError) -> ProxyRelayTransportError {
        if case .tls = error { return .tlsFailed }
        if case .posix(let code) = error { return .posixFailure(code.rawValue) }
        if case .dns(let code) = error { return .dnsFailure(code) }
        return .unavailable
    }
    private func handleNativeFailure(_ error: Error) {
        guard (state == .ready || state == .draining), !readEnded else { close(error); return }
        state = .draining; nativeStateFailure = error; terminalError = error
        connection.stateUpdateHandler = nil
        // Network can publish a terminal state while receive bytes remain
        // buffered natively. Keep the bounded reader usable until a real
        // final/error callback. Pausing at our buffer cap must not truncate
        // the remaining stream. There is no retry/new connection here.
        let failed = pending.filter { !$0.value.read }
        for (id, operation) in failed {
            pending.removeValue(forKey: id)
            operation.deadline?.cancel(); operation.fail(error)
        }
        if nativeReadOutstanding { scheduleDrainDeadline() }
        else { armReceive() }
    }
    private func scheduleDrainDeadline() {
        drainDeadline?.cancel()
        guard let error = nativeStateFailure else { return }
        // Bound a native callback with no consumer deadline. No timer runs
        // while prefetch is paused at capacity: without an outstanding
        // receive there is no callback retaining this transport. A waiting
        // consumer retains its own original, potentially shorter deadline.
        let drain = DispatchWorkItem { [weak self] in self?.close(error) }
        drainDeadline = drain
        queue.asyncAfter(deadline: .now() + 1, execute: drain)
    }
    private func close(_ error: Error) {
        state = .closed; terminalError = error
        drainDeadline?.cancel(); drainDeadline = nil
        if nativeReadOutstanding || error is CancellationError || (error as? ProxyRelayTransportError) == .timeout {
            readAborted = true
            readBuffer.removeAll(); readEnded = false
        }
        readFailure = error
        deliverRead()
        readConsumer = nil; reading = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        let waiting = pending.values; pending.removeAll()
        for operation in waiting { operation.deadline?.cancel(); operation.fail(error) }
    }
}
