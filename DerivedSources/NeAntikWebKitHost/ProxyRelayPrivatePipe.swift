import Darwin
import Foundation

/// Bounded framed IPC over inherited anonymous pipes. Credentials may pass
/// through this channel, never through argv/environment/files or diagnostics.
/// All calls run off MainActor. A timeout/cancel/EOF invalidates the exchange.
enum ProxyRelayPrivatePipe {
    enum Failure: LocalizedError {
        case unsafeDescriptor, invalidLimit, timeout, closed, malformed

        var errorDescription: String? {
            switch self {
            case .unsafeDescriptor:
                return "Канал обмена с процессом WebKit не прошёл проверку."
            case .invalidLimit:
                return "Ответ процесса WebKit нарушает ограничения протокола."
            case .timeout:
                return "Процесс WebKit не ответил вовремя."
            case .closed:
                return "Процесс WebKit закрыл канал запуска до подтверждения."
            case .malformed:
                return "Процесс WebKit вернул повреждённый ответ."
            }
        }
    }
    static let maximumFrameBytes = 16 * 1024
    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
    static let maximumPreviewBytes = 1024 * 1024
    struct Preview: Sendable {
        let png: Data
        let acceptsClick: Bool
    }

    struct PreviewClick: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let screenX: Double
        let screenY: Double

        var isValid: Bool {
            x >= 0 && x < 1 && y >= 0 && y < 1 &&
                abs(screenX) <= 100_000 && abs(screenY) <= 100_000
        }
    }

    private static let clickablePreviewTag: UInt8 = 1
    #endif
    // Covers the bounded WebKit route activation (15 s) and graceful save
    // acknowledgement (30 s); larger or unbounded waits remain invalid.
    static let maximumTimeout: TimeInterval = 30

    static func prepare(_ fd: Int32, writable: Bool) throws {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO), info.st_uid == geteuid()
        else { throw Failure.unsafeDescriptor }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              !writable || fcntl(fd, F_SETNOSIGPIPE, 1) == 0
        else { throw Failure.unsafeDescriptor }
    }

    static func anonymousSocketPair() throws -> (FileHandle, FileHandle) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw Failure.unsafeDescriptor
        }
        let parent = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        try prepareAnonymousSocket(fds[0])
        try prepareAnonymousSocket(fds[1])
        return (parent, child)
    }

    static func prepareAnonymousSocket(_ fd: Int32) throws {
        var info = stat()
        var type: Int32 = 0
        var typeSize = socklen_t(MemoryLayout<Int32>.size)
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        var local = sockaddr_un()
        var peer = sockaddr_un()
        var localSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        var peerSize = localSize
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeSize) == 0, type == SOCK_STREAM,
              getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid(),
              withUnsafeMutablePointer(to: &local, { pointer in
                  pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &localSize) }
              }) == 0,
              withUnsafeMutablePointer(to: &peer, { pointer in
                  pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &peerSize) }
              }) == 0,
              local.sun_family == sa_family_t(AF_UNIX), peer.sun_family == sa_family_t(AF_UNIX),
              local.sun_path.0 == 0, peer.sun_path.0 == 0 else { throw Failure.unsafeDescriptor }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.unsafeDescriptor }
    }

    // Darwin CMSG_DATA/CMSG_SPACE align ancillary records to a 32-bit boundary.
    private static let rightsHeaderBytes = (MemoryLayout<cmsghdr>.size + 3) & ~3
    private static let descriptorBytes = MemoryLayout<Int32>.size
    private static let descriptorTag: UInt8 = 0x46

    /// Send one capability on the inherited, already authenticated socket.
    /// This direction must have no other active writer during the exchange.
    static func sendDescriptor(_ descriptor: Int32, to socket: Int32, timeout: TimeInterval) throws {
        guard descriptor >= 0 else { throw Failure.unsafeDescriptor }
        let deadline = try deadline(timeout)
        let length = rightsHeaderBytes + descriptorBytes
        var header = cmsghdr(cmsg_len: socklen_t(length), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
        var control = Data(bytes: &header, count: MemoryLayout<cmsghdr>.size)
        control.append(Data(count: rightsHeaderBytes - control.count))
        var descriptor = descriptor
        control.append(Data(bytes: &descriptor, count: descriptorBytes))
        var tag = descriptorTag
        while true {
            try wait(socket, events: Int16(POLLOUT), deadline: deadline)
            let count = control.withUnsafeMutableBytes {
                descriptorMessage(socket, control: $0, tag: &tag, sending: true).count
            }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count == 1 else { throw Failure.closed }
            return
        }
    }

    /// Receive before the child starts WebKit or spawns further helpers.
    /// Darwin requires setting close-on-exec on the received descriptor.
    static func receiveDescriptor(from socket: Int32, timeout: TimeInterval) throws -> FileHandle {
        let deadline = try deadline(timeout)
        var control = Data(count: rightsHeaderBytes + 4 * descriptorBytes)
        var tag: UInt8 = 0
        while true {
            try wait(socket, events: Int16(POLLIN), deadline: deadline)
            let result = control.withUnsafeMutableBytes {
                descriptorMessage(socket, control: $0, tag: &tag, sending: false)
            }
            if result.count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard result.count == 1 else { throw Failure.closed }
            var descriptors: [Int32] = []
            defer { for fd in descriptors { Darwin.close(fd) } }
            let onlyRights = control.withUnsafeBytes { bytes -> Bool in
                let end = min(bytes.count, result.controlLength)
                var offset = 0
                var records = 0
                var valid = true
                while end - offset >= rightsHeaderBytes {
                    let header = bytes.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                    let length = Int(header.cmsg_len)
                    guard length >= rightsHeaderBytes, length <= end - offset else { return false }
                    let first = offset + rightsHeaderBytes
                    if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                        for position in stride(from: first, through: offset + length - descriptorBytes, by: descriptorBytes) {
                            descriptors.append(bytes.loadUnaligned(fromByteOffset: position, as: Int32.self))
                        }
                        valid = valid && length == rightsHeaderBytes + descriptorBytes
                    } else {
                        valid = false
                    }
                    records += 1
                    offset += (length + 3) & ~3
                }
                return valid && records == 1 && offset == end
            }
            guard onlyRights, tag == descriptorTag, result.flags & (MSG_CTRUNC | MSG_TRUNC) == 0,
                  descriptors.count == 1, let fd = descriptors.first,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.malformed }
            descriptors.removeAll()
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }

    private static func descriptorMessage(_ socket: Int32, control: UnsafeMutableRawBufferPointer,
                                          tag: inout UInt8, sending: Bool)
        -> (count: Int, controlLength: Int, flags: Int32) {
        withUnsafeMutablePointer(to: &tag) { byte in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(byte), iov_len: 1)
            return withUnsafeMutablePointer(to: &vector) { vector in
                var message = msghdr()
                message.msg_iov = vector
                message.msg_iovlen = 1
                message.msg_control = control.baseAddress
                message.msg_controllen = socklen_t(control.count)
                let count = sending ? sendmsg(socket, &message, 0) : recvmsg(socket, &message, 0)
                return (count, Int(message.msg_controllen), message.msg_flags)
            }
        }
    }

    static func readFrame(_ fd: Int32, timeout: TimeInterval) throws -> Data {
        try readFrame(fd, timeout: timeout, limit: maximumFrameBytes)
    }

    private static func readFrame(_ fd: Int32, timeout: TimeInterval, limit: Int) throws -> Data {
        let deadline = try deadline(timeout)
        let header = try read(fd, count: 4, deadline: deadline, allowsIdleTimeout: true)
        let bytes = [UInt8](header)
        let count = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard count > 0, count <= limit else { throw Failure.invalidLimit }
        return try read(fd, count: count, deadline: deadline, allowsIdleTimeout: false)
    }

    static func writeFrame(_ fd: Int32, data: Data, timeout: TimeInterval) throws {
        try writeFrame(fd, data: data, timeout: timeout, limit: maximumFrameBytes)
    }

    private static func writeFrame(_ fd: Int32, data: Data, timeout: TimeInterval, limit: Int) throws {
        guard !data.isEmpty, data.count <= limit else { throw Failure.invalidLimit }
        let deadline = try deadline(timeout), count = UInt32(data.count)
        let packet = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + data
        var offset = 0
        while offset < packet.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let result = packet.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), packet.count - offset) }
            if result < 0, errno == EINTR || errno == EAGAIN { continue }
            guard result > 0 else { throw Failure.closed }
            offset += result
        }
    }

    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
    static func writePreview(_ fd: Int32, png: Data, generation: UUID, acceptsClick: Bool = false) throws {
        guard !png.isEmpty, png.count <= maximumPreviewBytes else { throw Failure.invalidLimit }
        let key = Data(generation.uuidString.utf8)
        // PNG starts with 0x89. Keep the original payload for read-only runtimes.
        let payload = acceptsClick ? Data([clickablePreviewTag]) + png : png
        try writeFrame(fd, data: key + payload, timeout: 3, limit: maximumPreviewBytes + key.count + 1)
    }

    static func readPreview(_ fd: Int32, generation: UUID) throws -> Preview {
        let key = Data(generation.uuidString.utf8)
        let packet = try readFrame(fd, timeout: 15, limit: maximumPreviewBytes + key.count + 1)
        guard packet.starts(with: key) else { throw Failure.malformed }
        let payload = packet.dropFirst(key.count)
        let acceptsClick = payload.first == clickablePreviewTag
        let png = payload.dropFirst(acceptsClick ? 1 : 0)
        guard !png.isEmpty, png.count <= maximumPreviewBytes else { throw Failure.malformed }
        return Preview(png: Data(png), acceptsClick: acceptsClick)
    }

    static func writePreviewClick(_ fd: Int32, click: PreviewClick, generation: UUID) throws {
        guard click.isValid else { throw Failure.malformed }
        let key = Data(generation.uuidString.utf8)
        try writeFrame(fd, data: key + JSONEncoder().encode(click), timeout: 1, limit: 512)
    }

    static func readPreviewClick(_ fd: Int32, generation: UUID) throws -> PreviewClick {
        let key = Data(generation.uuidString.utf8)
        let packet = try readFrame(fd, timeout: 10, limit: 512)
        guard packet.starts(with: key),
              let click = try? JSONDecoder().decode(PreviewClick.self, from: packet.dropFirst(key.count)),
              click.isValid else { throw Failure.malformed }
        return click
    }
    #endif

    private static func deadline(_ timeout: TimeInterval) throws -> Double {
        guard timeout.isFinite, timeout > 0, timeout <= maximumTimeout else { throw Failure.invalidLimit }
        return uptime() + timeout
    }
    private static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    private static func wait(_ fd: Int32, events: Int16, deadline: Double) throws {
        while true {
            try Task.checkCancellation()
            let remaining = deadline - uptime()
            guard remaining > 0 else { throw Failure.timeout }
            var event = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&event, 1, Int32(max(1, min(100, remaining * 1000))))
            if result < 0, errno == EINTR { continue }
            guard result >= 0, event.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw Failure.closed }
            if event.revents & events != 0 { return }
            guard event.revents & Int16(POLLHUP) == 0 else { throw Failure.closed }
        }
    }
    private static func read(_ fd: Int32, count: Int, deadline: Double, allowsIdleTimeout: Bool) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            do {
                try wait(fd, events: Int16(POLLIN), deadline: deadline)
            } catch Failure.timeout where offset > 0 || !allowsIdleTimeout {
                // Once a frame has started, the next read cannot safely restart at its header.
                throw Failure.malformed
            }
            let result = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if result < 0, errno == EINTR || errno == EAGAIN { continue }
            guard result > 0 else { throw Failure.closed }
            offset += result
        }
        try Task.checkCancellation()
        return data
    }
}
