import Darwin
import Foundation

/// Local read-only endpoint for the persistent signed owner. One worker and
/// one accepted FD at a time; slow/malformed requests cannot spawn more tasks
/// or revoke the browser. I/O is bounded; Security checks are synchronous and
/// are not claimed to have a hard execution deadline.
enum ProxyRelayObservationSocket {
    typealias Binding = ProxyRelayObservationProtocol.Binding
    private typealias Failure = ProxyRelayObservationProtocol.Failure
    fileprivate struct Entry {
        let device: dev_t; let inode: ino_t; let uid: uid_t; let type: mode_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino; uid = value.st_uid; type = value.st_mode & mode_t(S_IFMT) }
        func matches(_ value: stat) -> Bool { device == value.st_dev && inode == value.st_ino && uid == value.st_uid && type == value.st_mode & mode_t(S_IFMT) }
    }
    fileprivate final class Endpoint: @unchecked Sendable {
        let root: String; let directory: Int32; let listener: Int32
        let directoryEntry: Entry; let socketEntry: Entry
        init(root: String, directory: Int32, listener: Int32, directoryEntry: Entry, socketEntry: Entry) {
            self.root = root; self.directory = directory; self.listener = listener
            self.directoryEntry = directoryEntry; self.socketEntry = socketEntry
        }
        var isCurrent: Bool {
            var path = stat(), fd = stat(), socket = stat()
            return lstat(root, &path) == 0 && fstat(directory, &fd) == 0 && directoryEntry.matches(path) && directoryEntry.matches(fd) &&
                fstatat(directory, "socket", &socket, AT_SYMLINK_NOFOLLOW) == 0 && socketEntry.matches(socket)
        }
        func cleanup() {
            _ = Darwin.close(listener)
            if isCurrent { _ = unlinkat(directory, "socket", 0) }
            var path = stat()
            if lstat(root, &path) == 0 && directoryEntry.matches(path) { _ = Darwin.rmdir(root) }
            _ = Darwin.close(directory)
        }
    }
    final class Server: @unchecked Sendable {
        private let task: Task<Void, Never>
        fileprivate init(endpoint: Endpoint, binding: Binding, code: ProxyRelayExpectedCode,
                         sessionValid: @escaping @Sendable () -> Bool,
                         snapshot: @escaping @Sendable () -> BrowserRelayActivity.Snapshot) {
            task = Task.detached(priority: .utility) {
                defer { endpoint.cleanup() }
                while !Task.isCancelled && endpoint.isCurrent {
                    var poller = pollfd(fd: endpoint.listener, events: Int16(POLLIN), revents: 0)
                    let status = Darwin.poll(&poller, 1, 100)
                    if status < 0 && errno == EINTR { continue }
                    if status < 0 || poller.revents & Int16(POLLERR | POLLNVAL | POLLHUP) != 0 { break }
                    guard status > 0 else { continue }
                    let client = Darwin.accept(endpoint.listener, nil, nil)
                    if client < 0 { if errno == EAGAIN || errno == EINTR { continue }; break }
                    do {
                        defer { _ = Darwin.close(client) }
                        try prepare(client)
                        let deadline = uptime() + 1
                        let data = try ProxyRelayPrivatePipe.readFrame(client, timeout: remaining(deadline))
                        guard let peer = ProxyRelayControlPeerInspector.currentPeer(descriptor: client),
                              ProxyRelayControlPeerInspector.matchesLiveCode(peer, expected: code), endpoint.isCurrent,
                              sessionValid(), binding.processesAreCurrent else { throw Failure.unavailable }
                        let request = try ProxyRelayObservationProtocol.readRequest(data, expected: binding)
                        let reply = ProxyRelayObservationProtocol.Reply(schema: 1, challenge: request.challenge, binding: binding, activity: snapshot())
                        guard sessionValid(), binding.processesAreCurrent, endpoint.isCurrent,
                              ProxyRelayControlPeerInspector.matchesLiveCode(peer, expected: code) else { throw Failure.changed }
                        try ProxyRelayPrivatePipe.writeFrame(client, data: JSONEncoder().encode(reply), timeout: remaining(deadline))
                        // macOS clears LOCAL_PEERPID when the peer socket is
                        // closed, even while its reply is still queued. Keep
                        // this FD alive until the client finishes post-reply
                        // authentication. This receipt grants no authority and
                        // never acknowledges browser traffic. Lost clients are
                        // bounded by the same I/O deadline.
                        let receipt = try ProxyRelayPrivatePipe.readFrame(client, timeout: remaining(deadline))
                        guard receipt == Data(request.challenge.uuidString.utf8) else { throw Failure.malformed }
                    } catch {
                        // A refused observation closes only this FD. No native
                        // errors, peer paths, request IDs or bytes are logged.
                    }
                }
            }
        }
        func cancel() { task.cancel() }
        func stop() async { task.cancel(); await task.value }
        deinit { task.cancel() }
    }

    /// Collision refuses creation. Never adopt/remove an existing endpoint.
    static func start(binding: Binding, expectedManagerCode: ProxyRelayExpectedCode,
                      sessionValid: @escaping @Sendable () -> Bool,
                      snapshot: @escaping @Sendable () -> BrowserRelayActivity.Snapshot) throws -> Server {
        try create(binding: binding, expectedManagerCode: expectedManagerCode, sessionValid: sessionValid, snapshot: snapshot)
    }
#if DEBUG
    static func startForTesting(binding: Binding, expectedManagerCode: ProxyRelayExpectedCode,
                                afterSocketCapture: @escaping () throws -> Void) throws -> Server {
        try create(binding: binding, expectedManagerCode: expectedManagerCode, sessionValid: { false },
                   snapshot: { BrowserRelayActivity().snapshot() }, afterSocketCapture: afterSocketCapture)
    }
#endif
    private static func create(binding: Binding, expectedManagerCode: ProxyRelayExpectedCode,
                               sessionValid: @escaping @Sendable () -> Bool,
                               snapshot: @escaping @Sendable () -> BrowserRelayActivity.Snapshot,
                               afterSocketCapture: (() throws -> Void)? = nil) throws -> Server {
        try binding.validate()
        let root = rootPath(binding.sessionGeneration)
        guard mkdir(root, 0o700) == 0 else { throw Failure.unsafeEndpoint }
        var directory = Int32(-1), listener = Int32(-1), captured: Entry?, createdSocket: Entry?
        do {
            directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var info = stat(), path = stat()
            guard directory >= 0, fstat(directory, &info) == 0, lstat(root, &path) == 0,
                  info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o777 == 0o700,
                  Entry(info).matches(path) else { throw Failure.unsafeEndpoint }
            captured = Entry(info)
            listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            try prepare(listener)
            try address(root + "/socket") { pointer, size in
                guard Darwin.bind(listener, pointer, size) == 0 else { throw Failure.unsafeEndpoint }
            }
            var boundSocket = stat()
            guard fstatat(directory, "socket", &boundSocket, AT_SYMLINK_NOFOLLOW) == 0,
                  boundSocket.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), boundSocket.st_uid == geteuid()
            else { throw Failure.unsafeEndpoint }
            createdSocket = Entry(boundSocket)
#if DEBUG
            try afterSocketCapture?()
#endif
            guard fchmodat(directory, "socket", 0o600, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unsafeEndpoint }
            var socket = stat()
            guard fstatat(directory, "socket", &socket, AT_SYMLINK_NOFOLLOW) == 0,
                  socket.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), socket.st_uid == geteuid(), socket.st_mode & 0o777 == 0o600,
                  createdSocket?.matches(socket) == true,
                  Darwin.listen(listener, 4) == 0 else { throw Failure.unsafeEndpoint }
            let endpoint = Endpoint(root: root, directory: directory, listener: listener, directoryEntry: Entry(info), socketEntry: Entry(boundSocket))
            guard endpoint.isCurrent else { throw Failure.unsafeEndpoint }
            return Server(endpoint: endpoint, binding: binding, code: expectedManagerCode, sessionValid: sessionValid, snapshot: snapshot)
        } catch {
            if listener >= 0 { _ = Darwin.close(listener) }
            // Remove only entries captured from our successful bind. Replaced
            // ancestors/sockets and unknown contents are deliberately retained.
            var path = stat(), node = stat()
            if let captured, let createdSocket, lstat(root, &path) == 0, captured.matches(path),
               fstatat(directory, "socket", &node, AT_SYMLINK_NOFOLLOW) == 0, createdSocket.matches(node) {
                _ = unlinkat(directory, "socket", 0)
            }
            if let captured, lstat(root, &path) == 0, captured.matches(path) { _ = Darwin.rmdir(root) }
            if directory >= 0 { _ = Darwin.close(directory) }
            throw error
        }
    }

    /// Called off MainActor with context read from an exact still-owned lease.
    /// Neither path, UID nor echoed request confers authority: pin live owner
    /// code and kernel generation before and after the complete exchange.
    static func query(binding: Binding, expectedOwnerCode: ProxyRelayExpectedCode) throws -> BrowserRelayActivity.Snapshot {
        try performQuery(binding: binding, expectedOwnerCode: expectedOwnerCode, acknowledge: true)
    }
#if DEBUG
    /// Fault control for the signed isolated QA parent: close after reading a
    /// validated reply, without the receipt that keeps kernel peer PID alive.
    static func abandonReplyForQualification(binding: Binding, expectedOwnerCode: ProxyRelayExpectedCode) throws -> BrowserRelayActivity.Snapshot {
        try performQuery(binding: binding, expectedOwnerCode: expectedOwnerCode, acknowledge: false)
    }
#endif
    private static func performQuery(binding: Binding, expectedOwnerCode: ProxyRelayExpectedCode, acknowledge: Bool) throws -> BrowserRelayActivity.Snapshot {
        try binding.validate(); try Task.checkCancellation()
        guard binding.processesAreCurrent,
              let identity = ProxyRelaySocketOwnerInspector.processIdentity(binding.owner.pid),
              ProxyRelayLiveCodeVerifier.matches(processID: binding.owner.pid, expectedProcess: identity, expectedCode: expectedOwnerCode)
        else { throw Failure.ownerRefused }
        let root = rootPath(binding.sessionGeneration), path = root + "/socket"
        var directory = stat(), socket = stat()
        guard lstat(root, &directory) == 0, directory.st_uid == geteuid(), directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), directory.st_mode & 0o777 == 0o700,
              lstat(path, &socket) == 0, socket.st_uid == geteuid(), socket.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), socket.st_mode & 0o777 == 0o600
        else { throw Failure.unsafeEndpoint }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { _ = Darwin.close(fd) }
        try prepare(fd)
        let deadline = uptime() + 1
        try address(path) { pointer, size in
            if Darwin.connect(fd, pointer, size) != 0 {
                guard errno == EINPROGRESS else { throw Failure.unavailable }
                try writable(fd, deadline: deadline)
                var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw Failure.unavailable }
            }
        }
        // Pin the actual connected FD before sending even the private session
        // correlation fields. A live owner at another socket is not authority.
        guard case .matched(let connectedPeer) = ProxyRelayControlPeerInspector.inspect(descriptor: fd, expectedProcessID: binding.owner.pid, expectedProcess: identity),
              ProxyRelayControlPeerInspector.matchesLiveCode(connectedPeer, expected: expectedOwnerCode), binding.processesAreCurrent
        else { throw Failure.peerRefused }
        let request = ProxyRelayObservationProtocol.Request(schema: 1, challenge: UUID(), binding: binding)
        try ProxyRelayPrivatePipe.writeFrame(fd, data: JSONEncoder().encode(request), timeout: remaining(deadline))
        let data = try ProxyRelayPrivatePipe.readFrame(fd, timeout: remaining(deadline))
        var currentRoot = stat(), currentSocket = stat()
        guard lstat(root, &currentRoot) == 0, Entry(directory).matches(currentRoot),
              lstat(path, &currentSocket) == 0, Entry(socket).matches(currentSocket),
              ProxyRelayControlPeerInspector.matchesLiveCode(connectedPeer, expected: expectedOwnerCode), binding.processesAreCurrent
        else { throw Failure.changed }
        let activity = try ProxyRelayObservationProtocol.readReply(data, request: request)
        guard ProxyRelayControlPeerInspector.matchesLiveCode(connectedPeer, expected: expectedOwnerCode), binding.processesAreCurrent else { throw Failure.changed }
        try Task.checkCancellation()
        if acknowledge { try ProxyRelayPrivatePipe.writeFrame(fd, data: Data(request.challenge.uuidString.utf8), timeout: remaining(deadline)) }
        return activity
    }
    static func rootPath(_ generation: UUID) -> String { "/private/tmp/neantik-relay-observation-" + generation.uuidString.lowercased() }
    private static func prepare(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard fd >= 0, flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.unavailable }
    }
    private static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        let bytes = Array(path.utf8) + [UInt8(0)]
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unsafeEndpoint }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    private static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    private static func remaining(_ deadline: Double) throws -> Double {
        try Task.checkCancellation(); let remaining = deadline - uptime()
        guard remaining > 0 else { throw Failure.unavailable }; return remaining
    }
    private static func writable(_ fd: Int32, deadline: Double) throws {
        while true {
            let left = try remaining(deadline)
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let status = Darwin.poll(&event, 1, Int32(max(1, min(100, left * 1_000))))
            if status < 0 && errno == EINTR { continue }
            guard status >= 0, event.revents & Int16(POLLERR | POLLNVAL | POLLHUP) == 0 else { throw Failure.unavailable }
            if event.revents & Int16(POLLOUT) != 0 { return }
        }
    }
}
