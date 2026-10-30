import Darwin
import Foundation
import Testing
@testable import DirectUpdateCore

struct DirectUpdateOwnerPipeTests {
    private func descriptors() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(pipe(&descriptors) == 0); return descriptors
    }
    @Test func cancellationReplyIsNotRepeatedAfterEOFSuccessTimeoutOrTrailingData() throws {
        for condition in ["eof", "timeout", "trailing"] {
            var input = try descriptors(); let output = try descriptors()
            defer { close(input[0]); if input[1] >= 0 { close(input[1]) }; close(output[0]); close(output[1]) }
            if condition == "eof" { close(input[1]); input[1] = -1 }
            if condition == "trailing" {
                var byte: UInt8 = 7
                try #require(Darwin.write(input[1], &byte, 1) == 1)
            }
            let request = try DirectUpdateOwnerInit(archive: URL(fileURLWithPath: "/synthetic/archive.zip"), manifest: Data([1]))
            var reply = DirectUpdateOwnerCancellationReply()
            if condition == "eof" {
                try reply.acknowledge(request, input: input[0], output: output[1], timeoutMS: 30)
            } else {
                #expect(throws: DirectUpdateInstallSessionError.self) {
                    try reply.acknowledge(request, input: input[0], output: output[1], timeoutMS: 30)
                }
            }
            #expect(try DirectUpdateOwnerPipe.readFrame(output[0], timeoutMS: 100) == DirectUpdateOwnerConsent.cancelled(request: request))
            #expect(throws: DirectUpdateOwnerProtocolError.binding) {
                try reply.acknowledge(request, input: input[0], output: output[1], timeoutMS: 30)
            }
            // Native reader made this descriptor nonblocking; no second frame
            // was emitted even if the first acknowledgement's EOF failed.
            var extra: UInt8 = 0
            #expect(Darwin.read(output[0], &extra, 1) == -1 && errno == EAGAIN)
        }
    }
    @Test func actualFramesAndEOFWorkInUncancellableOwnerPhases() throws {
        var fds = try descriptors(); defer { close(fds[0]); if fds[1] >= 0 { close(fds[1]) } }
        let request = try DirectUpdateOwnerInit(archive: URL(fileURLWithPath: "/synthetic/archive.zip"), manifest: Data([1, 2]))
        for frame in [request.bytes, Data([1, 2]), DirectUpdateOwnerConsent.cancelled(request: request)] {
            try DirectUpdateOwnerPipe.writeFrame(frame, to: fds[1])
            let read = try DirectUpdateOwnerPipe.readFrame(fds[0], timeoutMS: 1_000)
            #expect(read == frame)
        }
        close(fds[1]); fds[1] = -1
        try DirectUpdateOwnerPipe.expectEOF(fds[0], timeoutMS: 100)
    }
    @Test func cancellationTimeoutTrailingBytesAndNonPipeAreRefused() throws {
        let fds = try descriptors(); defer { close(fds[0]); close(fds[1]) }
        let token = DirectUpdateOwnerPipeCancellation(); token.cancel()
        #expect(throws: CancellationError.self) { try DirectUpdateOwnerPipe.readFrame(fds[0], timeoutMS: 100, cancellation: token) }
        #expect(throws: DirectUpdateInstallSessionError.timeout) { try DirectUpdateOwnerPipe.readFrame(fds[0], timeoutMS: 20) }
        var byte: UInt8 = 3
        try #require(Darwin.write(fds[1], &byte, 1) == 1)
        #expect(throws: DirectUpdateInstallSessionError.io) { try DirectUpdateOwnerPipe.expectEOF(fds[0], timeoutMS: 100) }
        let file = open("/dev/null", O_RDONLY); defer { close(file) }
        #expect(throws: DirectUpdateInstallSessionError.io) { try DirectUpdateOwnerPipe.readFrame(file, timeoutMS: 100) }
        #expect(throws: DirectUpdateInstallSessionError.io) { try DirectUpdateOwnerPipe.writeFrame(Data(), to: fds[1]) }
    }
}
