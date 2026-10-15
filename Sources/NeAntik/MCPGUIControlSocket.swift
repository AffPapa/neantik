import Darwin
import DirectUpdateCore
import Foundation

/// Dedicated GUI control transport, separate from relay observation authority.
/// Persistent connections make EOF revoke exactly one client's window rights.
enum MCPGUIControlSocket {
    typealias Wire = MCPGUIControlProtocol
    typealias Endpoint = MCPGUIControlEndpoint
    typealias Handler = @MainActor @Sendable (Wire.Request, UUID, Connection) async -> Wire.Reply
    typealias Disconnected = @MainActor @Sendable (UUID) -> Void
    fileprivate typealias Verifier = @Sendable (ProxyRelayControlPeerEvidence) -> Bool

    final class Connection: @unchecked Sendable {
        private let lock = NSLock()
        fileprivate let descriptor: Int32
        private let peer: ProxyRelayControlPeerEvidence
        private let verifier: Verifier
        private let custody: @Sendable () -> Bool
        private let readEvents: Int32
        private var active = true

        fileprivate init(descriptor: Int32, peer: ProxyRelayControlPeerEvidence, verifier: @escaping Verifier,
                         custody: @escaping @Sendable () -> Bool) throws {
            let queue = kqueue()
            guard queue >= 0 else { throw Wire.Failure.unavailable }
            var change = kevent64_s()
            change.ident = UInt64(descriptor); change.filter = Int16(EVFILT_READ); change.flags = UInt16(EV_ADD | EV_ENABLE)
            guard fcntl(queue, F_SETFD, FD_CLOEXEC) == 0, Darwin.kevent64(queue, &change, 1, nil, 0, 0, nil) == 0 else {
                _ = Darwin.close(queue); throw Wire.Failure.unavailable
            }
            self.descriptor = descriptor; self.peer = peer; self.verifier = verifier; self.custody = custody
            readEvents = queue
        }
        var isCurrent: Bool { validate(code: false) }
        func authenticate() -> Bool { validate(code: true) }
        private func validate(code: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard active else { return false }
            guard readSideIsOpen(), custody(), ProxyRelayControlPeerInspector.revalidate(peer), !code || verifier(peer),
                  readSideIsOpen(), custody(), ProxyRelayControlPeerInspector.revalidate(peer) else {
                active = false; _ = shutdown(descriptor, SHUT_RDWR); return false
            }
            return true
        }
        /// EV_EOF detects a writer's shutdown even with unread bytes queued.
        /// This consumes kernel events, never application bytes. Like the
        /// code/peer proof it observes a point in time, not a future lease.
        private func readSideIsOpen() -> Bool {
            while true {
                var event = kevent64_s(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
                let count = Darwin.kevent64(readEvents, nil, 0, &event, 1, 0, &timeout)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { return false }
                if count == 0 { return true }
                return event.ident == UInt64(descriptor) && event.filter == Int16(EVFILT_READ) && event.flags & UInt16(EV_EOF | EV_ERROR) == 0
            }
        }
        func invalidate() {
            lock.lock(); defer { lock.unlock() }
            guard active else { return }; active = false; _ = shutdown(descriptor, SHUT_RDWR)
        }
        fileprivate func waitForRequest() async throws {
            while isCurrent {
                try Task.checkCancellation()
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&event, 1, 0)
                if result < 0, errno == EINTR { continue }
                guard result >= 0, event.revents & Int16(POLLERR | POLLNVAL | POLLHUP) == 0 else { throw Wire.Failure.unavailable }
                if event.revents & Int16(POLLIN) != 0 { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Wire.Failure.unavailable
        }
        /// Independent of the request handler, including while it awaits disk.
        fileprivate func watchEOF() async {
            while !Task.isCancelled, isCurrent {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            invalidate()
        }
        deinit { _ = Darwin.close(readEvents); _ = Darwin.close(descriptor) }
#if DEBUG
        var kernelPeerIsCurrentForTesting: Bool { ProxyRelayControlPeerInspector.revalidate(peer) }
        func peekByteForTesting() -> UInt8? {
            var byte: UInt8 = 0
            return recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 1 ? byte : nil
        }
#endif
    }

    private final class Registry: @unchecked Sendable {
        struct Item { let connection: Connection; var task: Task<Void, Never>? }
        private let lock = NSLock()
        private var items: [UUID: Item] = [:]
        private var active = true
        var canAccept: Bool { lock.lock(); defer { lock.unlock() }; return active && items.count < 8 }
        func reserve(_ connection: Connection, id: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard active, items.count < 8 else { return false }
            items[id] = Item(connection: connection); return true
        }
        func attach(_ task: Task<Void, Never>, id: UUID) {
            lock.lock(); defer { lock.unlock() }
            guard items[id] != nil else { task.cancel(); return }
            items[id]!.task = task
            if !active { task.cancel(); items[id]!.connection.invalidate() }
        }
        func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; items.removeValue(forKey: id) }
        func invalidate(_ id: UUID) {
            lock.lock(); let item = items[id]; lock.unlock()
            item?.connection.invalidate(); item?.task?.cancel()
        }
        func cancelAll() -> [Task<Void, Never>] {
            lock.lock(); active = false; let values = Array(items.values); lock.unlock()
            for value in values { value.connection.invalidate(); value.task?.cancel() }
            return values.compactMap(\.task)
        }
    }

    final class Server: @unchecked Sendable {
        private let registry: Registry
        private let task: Task<Void, Never>
        let endpointGeneration: UUID

        convenience init(endpoint: Endpoint.Listener, expectedClientCode: ProxyRelayExpectedCode,
             handler: @escaping Handler, disconnected: @escaping Disconnected) {
            self.init(endpoint: endpoint, verifier: { ProxyRelayControlPeerInspector.matchesLiveCode($0, expected: expectedClientCode) },
                      handler: handler, disconnected: disconnected)
        }
        private init(endpoint: Endpoint.Listener, verifier: @escaping Verifier, monitorEOF: Bool = true,
                     handler: @escaping Handler, disconnected: @escaping Disconnected) {
            let registry = Registry(); self.registry = registry; endpointGeneration = endpoint.value.generation
            task = Task.detached(priority: .utility) {
                while !Task.isCancelled, endpoint.isCurrent {
                    var event = pollfd(fd: endpoint.descriptor, events: Int16(POLLIN), revents: 0)
                    let status = Darwin.poll(&event, 1, 0)
                    if status < 0, errno == EINTR { continue }
                    if status < 0 || event.revents & Int16(POLLERR | POLLNVAL | POLLHUP) != 0 { break }
                    if event.revents & Int16(POLLIN) == 0 {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { break }; continue
                    }
                    let fd = Darwin.accept(endpoint.descriptor, nil, nil)
                    if fd < 0 { if errno == EAGAIN || errno == EINTR { continue }; break }
                    guard registry.canAccept else { _ = Darwin.close(fd); continue }
                    do { try Endpoint.prepareSocket(fd) } catch { _ = Darwin.close(fd); continue }
                    guard let peer = ProxyRelayControlPeerInspector.currentPeer(descriptor: fd), verifier(peer), endpoint.isCurrent else { _ = Darwin.close(fd); continue }
                    let connection: Connection
                    do { connection = try Connection(descriptor: fd, peer: peer, verifier: verifier, custody: { endpoint.isCurrent }) }
                    catch { _ = Darwin.close(fd); continue }
                    let id = UUID()
                    guard registry.reserve(connection, id: id) else { connection.invalidate(); continue }
                    let worker = Task.detached(priority: .utility) {
                        let monitor = Task.detached(priority: .utility) {
                            if monitorEOF {
                                await connection.watchEOF()
                                if !Task.isCancelled { await disconnected(id) }
                            }
                        }
                        do {
                            while !Task.isCancelled, connection.isCurrent {
                                try await connection.waitForRequest()
                                let bytes = try ProxyRelayPrivatePipe.readFrame(fd, timeout: 2)
                                guard connection.authenticate() else { throw Wire.Failure.unavailable }
                                let request = try Wire.decodeRequest(bytes)
                                let reply = await handler(request, id, connection)
                                guard connection.authenticate(), !Task.isCancelled else { throw Wire.Failure.unavailable }
                                let encoded = try JSONEncoder().encode(reply)
                                guard encoded.count <= Wire.maximumMessageBytes else { throw Wire.Failure.malformed }
                                try ProxyRelayPrivatePipe.writeFrame(fd, data: encoded, timeout: 2)
                            }
                        } catch { /* Refuse this connection without logging its data. */ }
                        connection.invalidate(); monitor.cancel(); await monitor.value
                        await disconnected(id); registry.remove(id)
                    }
                    registry.attach(worker, id: id)
                }
                let workers = registry.cancelAll()
                for worker in workers { await worker.value }
                // Join all accept/connection users before closing listener FDs.
                endpoint.cleanup()
            }
        }
        func disconnect(_ id: UUID) { registry.invalidate(id) }
        func requestStop() { task.cancel(); _ = registry.cancelAll() }
        func stop() async { requestStop(); await task.value }
        deinit { task.cancel(); _ = registry.cancelAll() }

#if DEBUG
        static func forTesting(endpoint: Endpoint.Listener, monitorEOF: Bool = true, handler: @escaping Handler,
                               disconnected: @escaping Disconnected) -> Server {
            Server(endpoint: endpoint, verifier: { ProxyRelayControlPeerInspector.revalidate($0) }, monitorEOF: monitorEOF, handler: handler, disconnected: disconnected)
        }
#endif
    }

    final class Client: @unchecked Sendable {
        let endpointGeneration: UUID
        let libraryIdentitySHA256: String
        private let connection: Connection
        private let exchangeLock = NSLock()

        static func connect(root: URL, expectedServerCode: ProxyRelayExpectedCode) throws -> Client {
            try connect(root: root, verifier: { ProxyRelayControlPeerInspector.matchesLiveCode($0, expected: expectedServerCode) })
        }
        private static func connect(root: URL, verifier: @escaping Verifier) throws -> Client {
            let library = try Endpoint.Library(root: root, exclusive: false)
            let (value, file) = try library.read()
            guard Endpoint.socketIsCurrent(value), let manager = ProxyRelaySocketOwnerInspector.processIdentity(value.managerPID),
                  manager.generation.startSeconds == value.managerStartSeconds,
                  manager.generation.startMicroseconds == value.managerStartMicroseconds else { throw Wire.Failure.unavailable }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Wire.Failure.unavailable }
            var transferred = false
            defer { if !transferred { _ = Darwin.close(fd) } }
            try Endpoint.prepareSocket(fd)
            try Endpoint.withAddress(Endpoint.rootPath(value.generation) + "/socket") { address, size in
                if Darwin.connect(fd, address, size) < 0 {
                    guard errno == EINPROGRESS else { throw Wire.Failure.unavailable }
                    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                    var ready = false
                    while DispatchTime.now().uptimeNanoseconds < deadline {
                        try Task.checkCancellation()
                        var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let result = Darwin.poll(&event, 1, 50)
                        if result < 0, errno == EINTR { continue }
                        guard result >= 0, event.revents & Int16(POLLERR | POLLNVAL | POLLHUP) == 0 else { throw Wire.Failure.unavailable }
                        if event.revents & Int16(POLLOUT) != 0 { ready = true; break }
                    }
                    var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                    guard ready, getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw Wire.Failure.unavailable }
                }
            }
            guard case .matched(let peer) = ProxyRelayControlPeerInspector.inspect(descriptor: fd, expectedProcessID: value.managerPID, expectedProcess: manager),
                  verifier(peer), library.fileIsCurrent(file), Endpoint.socketIsCurrent(value) else { throw Wire.Failure.unavailable }
            let connection = try Connection(descriptor: fd, peer: peer, verifier: verifier,
                custody: { library.fileIsCurrent(file) && Endpoint.socketIsCurrent(value) })
            transferred = true
            return Client(connection: connection, value: value)
        }
        private init(connection: Connection, value: Endpoint.Descriptor) {
            self.connection = connection; endpointGeneration = value.generation; libraryIdentitySHA256 = value.libraryIdentitySHA256
        }
        func exchange(_ request: Wire.Request) throws -> Wire.Reply {
            exchangeLock.lock(); defer { exchangeLock.unlock() }
            do {
                try request.validate()
                guard request.endpointGeneration == endpointGeneration, request.libraryIdentitySHA256 == libraryIdentitySHA256,
                      connection.authenticate() else { throw Wire.Failure.unavailable }
                let encoded = try JSONEncoder().encode(request)
                guard encoded.count <= Wire.maximumMessageBytes else { throw Wire.Failure.malformed }
                try ProxyRelayPrivatePipe.writeFrame(connection.descriptor, data: encoded, timeout: 2)
                let data = try ProxyRelayPrivatePipe.readFrame(connection.descriptor, timeout: 8)
                guard connection.authenticate() else { throw Wire.Failure.unavailable }
                return try Wire.decodeReply(data, request: request, expectedConnection: request.connectionGeneration)
            } catch { connection.invalidate(); throw error }
        }
        func invalidate() { connection.invalidate() }
        deinit { connection.invalidate() }
#if DEBUG
        static func connectForTesting(root: URL) throws -> Client {
            try connect(root: root, verifier: { ProxyRelayControlPeerInspector.revalidate($0) })
        }
        func halfCloseForTesting() { _ = shutdown(connection.descriptor, SHUT_WR) }
        func sendByteForTesting(_ byte: UInt8) throws {
            var byte = byte
            guard send(connection.descriptor, &byte, 1, 0) == 1 else { throw Wire.Failure.unavailable }
        }
#endif
    }

    /// Existing Developer ID only; no certificate or Keychain changes.
    static func currentExecutableCode() throws -> ProxyRelayExpectedCode {
        guard let executable = Bundle.main.executableURL, let identifier = Bundle.main.bundleIdentifier else { throw Wire.Failure.unavailable }
        return try ProxyRelayExpectedCode.qualifiedPin(at: executable, expectedIdentifier: identifier, expectedTeamIdentifier: "H6VGU2M6JD")
    }
}
