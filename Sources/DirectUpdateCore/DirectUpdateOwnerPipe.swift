import Darwin
import DirectUpdateBootstrapParent
import Foundation

final package class DirectUpdateOwnerPipeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    package init() {}
    package func cancel() { lock.lock(); stopped = true; lock.unlock() }
    fileprivate var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
/// Framing only: not authentication, consent, stopped authority or installation.
/// Every native call gets a real callback, including uncancellable phases.
package enum DirectUpdateOwnerPipe {
    package static func readFrame(_ descriptor: Int32, timeoutMS: UInt32,
                                  cancellation: DirectUpdateOwnerPipeCancellation? = nil) throws -> Data {
        var bytes = Data(count: 128 * 1_024), received = 0
        let raw = cancellation.map { Unmanaged.passUnretained($0).toOpaque() }
        let status = withExtendedLifetime(cancellation) {
            bytes.withUnsafeMutableBytes { buffer in
                neantik_update_pipe_read_frame(descriptor, buffer.bindMemory(to: UInt8.self).baseAddress,
                    buffer.count, &received, neantik_update_pipe_deadline(timeoutMS), min(timeoutMS, 5_000), ownerPipeCancellation, raw)
            }
        }
        try requireComplete(status)
        return bytes.prefix(received)
    }
    package static func writeFrame(_ bytes: Data, to descriptor: Int32, timeoutMS: UInt32 = 5_000) throws {
        let status = bytes.withUnsafeBytes { buffer in
            neantik_update_pipe_write_frame(descriptor, buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count, neantik_update_pipe_deadline(timeoutMS), ownerPipeCancellation, nil)
        }
        try requireComplete(status)
    }
    package static func expectEOF(_ descriptor: Int32, timeoutMS: UInt32 = 10_000) throws {
        try requireComplete(neantik_update_pipe_expect_eof(descriptor, neantik_update_pipe_deadline(timeoutMS), ownerPipeCancellation, nil))
    }
    private static func requireComplete(_ status: Int32) throws {
        switch Int(status) {
        case NUB_COMPLETE: return
        case NUB_CANCELLED: throw CancellationError()
        case NUB_TIMEOUT: throw DirectUpdateInstallSessionError.timeout
        default: throw DirectUpdateInstallSessionError.io
        }
    }
}
private func ownerPipeCancellation(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    return Unmanaged<DirectUpdateOwnerPipeCancellation>.fromOpaque(raw).takeUnretainedValue().isCancelled ? 1 : 0
}

/// One reply per operation, including when EOF fails after the frame was sent.
/// Wire acknowledgement alone never proves process cleanup or installation.
package struct DirectUpdateOwnerCancellationReply {
    private var attempted = false
    package init() {}
    package mutating func acknowledge(_ request: DirectUpdateOwnerInit,
        input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, timeoutMS: UInt32 = 10_000) throws {
        guard !attempted else { throw DirectUpdateOwnerProtocolError.binding }
        attempted = true
        try DirectUpdateOwnerPipe.writeFrame(DirectUpdateOwnerConsent.cancelled(request: request), to: output)
        try DirectUpdateOwnerPipe.expectEOF(input, timeoutMS: timeoutMS)
    }
}
