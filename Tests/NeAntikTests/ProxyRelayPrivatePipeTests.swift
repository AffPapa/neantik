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
    @Test func pipeFailuresHaveDistinctSecretFreeDescriptions() {
        let failures: [ProxyRelayPrivatePipe.Failure] = [
            .unsafeDescriptor, .invalidLimit, .timeout, .closed, .malformed
        ]
        let descriptions = failures.compactMap(\.errorDescription)
        #expect(descriptions.count == failures.count)
        #expect(descriptions.allSatisfy { !$0.isEmpty })
        #expect(Set(descriptions).count == failures.count)
        #expect(descriptions.allSatisfy { !$0.contains("@")} )
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
        for value in [0.0, -1, ProxyRelayPrivatePipe.maximumTimeout + 1, .infinity, .nan] {
            #expect(throws: ProxyRelayPrivatePipe.Failure.invalidLimit) { try ProxyRelayPrivatePipe.readFrame(input, timeout: value) }
        }
    }
    @Test func webKitStartupAndCloseBudgetsRemainWithinPipeContract() throws {
        let (input, output) = try pair(); defer { close(input); close(output) }
        for timeout in [15.0, 30.0] {
            let frame = Data("bounded".utf8)
            try ProxyRelayPrivatePipe.writeFrame(output, data: frame, timeout: timeout)
            #expect(try ProxyRelayPrivatePipe.readFrame(input, timeout: timeout) == frame)
        }
        #expect(throws: ProxyRelayPrivatePipe.Failure.invalidLimit) {
            try ProxyRelayPrivatePipe.readFrame(input, timeout: 31)
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
    @Test func onlyTimeoutBeforeAnyHeaderByteCanBeRetried() throws {
        let (input, output) = try pair()
        defer { close(input); close(output) }
        #expect(throws: ProxyRelayPrivatePipe.Failure.timeout) {
            try ProxyRelayPrivatePipe.readFrame(input, timeout: 0.01)
        }
        let complete = Data("after idle timeout".utf8)
        try ProxyRelayPrivatePipe.writeFrame(output, data: complete, timeout: 1)
        #expect(try ProxyRelayPrivatePipe.readFrame(input, timeout: 1) == complete)

        for partial in [[UInt8(0), 0], [0, 0, 0, 3], [0, 0, 0, 3, 1]] {
            let (reader, writer) = try pair()
            defer { close(reader); close(writer) }
            let written = partial.withUnsafeBytes { Darwin.write(writer, $0.baseAddress!, $0.count) }
            try #require(written == partial.count)
            #expect(throws: ProxyRelayPrivatePipe.Failure.malformed) {
                try ProxyRelayPrivatePipe.readFrame(reader, timeout: 0.01)
            }
        }
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
    @Test func onlyExplicitAnonymousSocketsUseDuplexTransport() throws {
        let (parent, child) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        defer { try? parent.close(); try? child.close() }
        for (sender, receiver) in [(parent, child), (child, parent)] {
            #expect(fcntl(sender.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
            try ProxyRelayPrivatePipe.writeFrame(sender.fileDescriptor, data: Data([1]), timeout: 1)
            #expect(try ProxyRelayPrivatePipe.readFrame(receiver.fileDescriptor, timeout: 1) == Data([1]))
            #expect(throws: ProxyRelayPrivatePipe.Failure.unsafeDescriptor) {
                try ProxyRelayPrivatePipe.prepare(sender.fileDescriptor, writable: true)
            }
        }
        let (reader, writer) = try pair()
        defer { close(reader); close(writer) }
        #expect(throws: ProxyRelayPrivatePipe.Failure.unsafeDescriptor) {
            try ProxyRelayPrivatePipe.prepareAnonymousSocket(reader)
        }
    }

    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
    @Test func previewHasSeparateSizeLimitAndExactGeneration() async throws {
        let (manager, host) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        defer { try? manager.close(); try? host.close() }
        let generation = UUID()
        let frame = Data(repeating: 0x7f, count: ProxyRelayPrivatePipe.maximumFrameBytes * 3)
        let hostFD = host.fileDescriptor
        #expect(throws: ProxyRelayPrivatePipe.Failure.invalidLimit) {
            try ProxyRelayPrivatePipe.writeFrame(hostFD, data: frame, timeout: 1)
        }
        async let write: Void = Task.detached {
            try ProxyRelayPrivatePipe.writePreview(hostFD, png: frame, generation: generation)
        }.value
        #expect(try ProxyRelayPrivatePipe.readPreview(manager.fileDescriptor, generation: generation).png == frame)
        try await write
        try ProxyRelayPrivatePipe.writePreview(hostFD, png: Data([1]), generation: generation)
        #expect(throws: ProxyRelayPrivatePipe.Failure.malformed) {
            try ProxyRelayPrivatePipe.readPreview(manager.fileDescriptor, generation: UUID())
        }
    }
    @Test func clickablePreviewAndReverseInputBindExactGeneration() throws {
        let (manager, host) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        defer { try? manager.close(); try? host.close() }
        let generation = UUID()
        let png = Data([0x89, 0x50])
        try ProxyRelayPrivatePipe.writePreview(host.fileDescriptor, png: png, generation: generation)
        #expect(try !ProxyRelayPrivatePipe.readPreview(manager.fileDescriptor, generation: generation).acceptsClick)
        try ProxyRelayPrivatePipe.writePreview(host.fileDescriptor, png: png, generation: generation, acceptsClick: true)
        let preview = try ProxyRelayPrivatePipe.readPreview(manager.fileDescriptor, generation: generation)
        #expect(preview.acceptsClick && preview.png == png)

        let click = ProxyRelayPrivatePipe.PreviewClick(x: 0.25, y: 0.5, screenX: -12, screenY: 50)
        try ProxyRelayPrivatePipe.writePreviewClick(manager.fileDescriptor, click: click, generation: generation)
        #expect(try ProxyRelayPrivatePipe.readPreviewClick(host.fileDescriptor, generation: generation) == click)

        let updatedPNG = Data([0x89, 0x51])
        try ProxyRelayPrivatePipe.writePreview(host.fileDescriptor, png: updatedPNG, generation: generation)
        let updated = try ProxyRelayPrivatePipe.readPreview(manager.fileDescriptor, generation: generation)
        #expect(updated.png == updatedPNG && !updated.acceptsClick)

        try ProxyRelayPrivatePipe.writePreviewClick(manager.fileDescriptor, click: click, generation: UUID())
        #expect(throws: ProxyRelayPrivatePipe.Failure.malformed) {
            try ProxyRelayPrivatePipe.readPreviewClick(host.fileDescriptor, generation: generation)
        }
        let outside = ProxyRelayPrivatePipe.PreviewClick(x: 1, y: 0.5, screenX: 0, screenY: 0)
        #expect(throws: ProxyRelayPrivatePipe.Failure.malformed) {
            try ProxyRelayPrivatePipe.writePreviewClick(manager.fileDescriptor, click: outside, generation: generation)
        }
    }
    #endif
}
