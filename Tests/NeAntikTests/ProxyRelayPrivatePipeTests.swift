import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayPrivatePipeTests {
    private func pair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        try #require(pipe(&fds) == 0)
        try ProxyRelayPrivatePipe.prepare(fds[0], writable: false)
        try ProxyRelayPrivatePipe.prepare(fds[1], writable: true)
        return (fds[0], fds[1])
    }
    @Test func twoFramesPreserveBoundaries() throws {
        let (input, output) = try pair(); defer { close(input); close(output) }
        for value in [Data("fixture-one".utf8), Data("fixture-two".utf8)] {
            try ProxyRelayPrivatePipe.writeFrame(output, data: value, timeout: 1)
            #expect(try ProxyRelayPrivatePipe.readFrame(input, timeout: 1) == value)
        }
    }
    @Test func emptyOversizedAndInvalidBudgetsAreRefused() throws {
        let (input, output) = try pair(); defer { close(input); close(output) }
        for value in [Data(), Data(count: ProxyRelayPrivatePipe.maximumFrameBytes + 1)] {
            #expect(throws: ProxyRelayPrivatePipe.Failure.invalidLimit) { try ProxyRelayPrivatePipe.writeFrame(output, data: value, timeout: 1) }
        }
        for value in [0.0, -1, 11, .infinity, .nan] {
            #expect(throws: ProxyRelayPrivatePipe.Failure.invalidLimit) { try ProxyRelayPrivatePipe.readFrame(input, timeout: value) }
        }
    }
    @Test func truncatedAndExcessivePeerFramesAreRefused() throws {
        for bytes in [[UInt8](arrayLiteral: 0,0,0,8,1,2), [0,0,65,0], [0,0,0,0]] {
            let (input, output) = try pair(); defer { close(input) }
            _ = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress!, bytes.count) }; close(output)
            #expect(throws: (any Error).self) { try ProxyRelayPrivatePipe.readFrame(input, timeout: 1) }
        }
    }
    @Test func timeoutEOFAndBrokenWriterDoNotHangOrRaiseSIGPIPE() throws {
        let (input, output) = try pair(); defer { close(output) }
        #expect(throws: ProxyRelayPrivatePipe.Failure.timeout) { try ProxyRelayPrivatePipe.readFrame(input, timeout: 0.01) }
        close(input)
        #expect(throws: ProxyRelayPrivatePipe.Failure.closed) { try ProxyRelayPrivatePipe.writeFrame(output, data: Data([1]), timeout: 1) }
        let (nextInput, nextOutput) = try pair(); defer { close(nextInput) }; close(nextOutput)
        #expect(throws: ProxyRelayPrivatePipe.Failure.closed) { try ProxyRelayPrivatePipe.readFrame(nextInput, timeout: 1) }
    }
    @Test func cancellationStopsBlockedRead() async throws {
        let (input, output) = try pair(); defer { close(input); close(output) }
        let task = Task.detached { try ProxyRelayPrivatePipe.readFrame(input, timeout: 5) }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func regularFilesAreNotPrivateBootstrapPipes() throws {
        let fd = Darwin.open("/dev/null", O_RDONLY); defer { close(fd) }
        #expect(throws: ProxyRelayPrivatePipe.Failure.unsafeDescriptor) { try ProxyRelayPrivatePipe.prepare(fd, writable: false) }
    }
}
