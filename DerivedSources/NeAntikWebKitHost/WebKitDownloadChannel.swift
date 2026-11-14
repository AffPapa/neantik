import Darwin
import Foundation

/// A dedicated socket for intake and one socket per transfer. Proxy, frame,
/// input and save/close traffic keep their existing independent channels.
enum WebKitDownloadChannel {
    struct Offer: Codable, Equatable, Sendable {
        let generation: UUID
        let id: UUID
        let filename: String

        var isValid: Bool {
            !filename.isEmpty && filename.utf8.count <= 4_096 && filename != "." && filename != ".." &&
                !filename.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == "\\"
                }
        }
    }

    enum Decision: String, Codable, Sendable { case accept, cancel }
    enum Result: String, Codable, Sendable { case saved, cancelled, failed }

    enum Failure: Error { case invalidOffer, unsafeFile, failedCopy }

    static func offer(_ offer: Offer, on intake: FileHandle, timeout: TimeInterval) throws -> FileHandle {
        guard offer.isValid else { throw Failure.invalidOffer }
        let (host, manager) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        try ProxyRelayPrivatePipe.sendDescriptor(manager.fileDescriptor, to: intake.fileDescriptor, timeout: timeout)
        try write(offer, on: host, timeout: timeout)
        return host
    }

    static func accept(on intake: FileHandle, generation: UUID, timeout: TimeInterval) throws -> (Offer, FileHandle) {
        let channel = try ProxyRelayPrivatePipe.receiveDescriptor(from: intake.fileDescriptor, timeout: timeout)
        try ProxyRelayPrivatePipe.prepareAnonymousSocket(channel.fileDescriptor)
        guard let offer = try? read(Offer.self, on: channel, timeout: timeout),
              offer.isValid, offer.generation == generation else { throw Failure.invalidOffer }
        return (offer, channel)
    }

    static func write<Value: Encodable>(_ value: Value, on channel: FileHandle, timeout: TimeInterval) throws {
        try ProxyRelayPrivatePipe.writeFrame(channel.fileDescriptor, data: JSONEncoder().encode(value), timeout: timeout)
    }

    static func read<Value: Decodable>(_ type: Value.Type, on channel: FileHandle, timeout: TimeInterval) throws -> Value {
        let data = try ProxyRelayPrivatePipe.readFrame(channel.fileDescriptor, timeout: timeout)
        return try JSONDecoder().decode(type, from: data)
    }

    static func stop(_ channel: FileHandle) {
        _ = shutdown(channel.fileDescriptor, SHUT_RDWR)
    }

    static func waitForPeerClose(_ channel: FileHandle) {
        var descriptor = pollfd(fd: channel.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while !Task.isCancelled {
            let ready = Darwin.poll(&descriptor, 1, 500)
            if ready < 0, errno == EINTR { continue }
            if ready != 0 { return }
        }
    }

    static func peerReadyForResult(_ channel: FileHandle) -> Bool {
        var descriptor = pollfd(fd: channel.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = Darwin.poll(&descriptor, 1, 0)
            if ready < 0, errno == EINTR { continue }
            return ready == 0
        }
    }

    static func validatePayload(_ incoming: FileHandle) throws -> off_t {
        let fd = incoming.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        var info = stat()
        guard flags >= 0, (flags & O_ACCMODE) == O_RDONLY, fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size >= 0 else { throw Failure.unsafeFile }
        return info.st_size
    }

    /// Copy only the received bytes and quarantine metadata to a newly opened,
    /// private local file. Publication still checks the chosen path and uses
    /// no-replace rename on its own volume.
    static func copyPayload(_ incoming: FileHandle, to staging: FileHandle) throws {
        let count = try validatePayload(incoming)
        let input = incoming.fileDescriptor
        let output = staging.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        var offset: off_t = 0
        while offset < count {
            try Task.checkCancellation()
            let limit = min(buffer.count, Int(count - offset))
            let read = buffer.withUnsafeMutableBytes { pread(input, $0.baseAddress, limit, offset) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw Failure.failedCopy }
            var written = 0
            while written < read {
                let size = buffer.withUnsafeBytes {
                    Darwin.write(output, $0.baseAddress?.advanced(by: written), read - written)
                }
                if size < 0, errno == EINTR { continue }
                guard size > 0 else { throw Failure.failedCopy }
                written += size
            }
            offset += off_t(read)
        }
        let quarantine = "com.apple.quarantine"
        let attributeSize = fgetxattr(input, quarantine, nil, 0, 0, 0)
        if attributeSize >= 0 {
            guard attributeSize <= 8_192 else { throw Failure.unsafeFile }
            var data = Data(count: attributeSize)
            guard data.withUnsafeMutableBytes({ fgetxattr(input, quarantine, $0.baseAddress, $0.count, 0, 0) }) == attributeSize,
                  data.withUnsafeBytes({ fsetxattr(output, quarantine, $0.baseAddress, $0.count, 0, 0) }) == 0
            else { throw Failure.failedCopy }
        } else if errno != ENOATTR && errno != ENOTSUP {
            throw Failure.failedCopy
        }
        var info = stat()
        guard try validatePayload(incoming) == count, fstat(output, &info) == 0, info.st_size == count,
              fsync(output) == 0 else { throw Failure.failedCopy }
    }
}
