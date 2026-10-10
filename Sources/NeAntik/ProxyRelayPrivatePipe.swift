import Darwin
import Foundation

/// Bounded framed IPC over inherited anonymous pipes. Credentials may pass
/// through this channel, never through argv/environment/files or diagnostics.
/// All calls run off MainActor. A timeout/cancel/EOF invalidates the exchange.
enum ProxyRelayPrivatePipe {
    enum Failure: Error { case unsafeDescriptor, invalidLimit, timeout, closed, malformed }
    static let maximumFrameBytes = 16 * 1024

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

    static func readFrame(_ fd: Int32, timeout: TimeInterval) throws -> Data {
        let deadline = try deadline(timeout)
        let header = try read(fd, count: 4, deadline: deadline)
        let bytes = [UInt8](header)
        let count = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard count > 0, count <= maximumFrameBytes else { throw Failure.invalidLimit }
        return try read(fd, count: count, deadline: deadline)
    }

    static func writeFrame(_ fd: Int32, data: Data, timeout: TimeInterval) throws {
        guard !data.isEmpty, data.count <= maximumFrameBytes else { throw Failure.invalidLimit }
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

    private static func deadline(_ timeout: TimeInterval) throws -> Double {
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw Failure.invalidLimit }
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
    private static func read(_ fd: Int32, count: Int, deadline: Double) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let result = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if result < 0, errno == EINTR || errno == EAGAIN { continue }
            guard result > 0 else { throw Failure.closed }
            offset += result
        }
        try Task.checkCancellation()
        return data
    }
}
