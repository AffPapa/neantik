import Darwin
import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized)
struct ProxyRelayObservationSocketTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock(); private var reads = 0
        func admit() -> Bool { lock.lock(); reads += 1; lock.unlock(); return true }
        var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }
    private func binding() throws -> ProxyRelayObservationProtocol.Binding {
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        return .init(profileID: UUID(), sessionGeneration: UUID(), profileRevision: 4,
            runtimeExecutableSHA256: String(repeating: "a", count: 64), runtimeFrameworkSHA256: String(repeating: "b", count: 64),
            configurationSHA256: String(repeating: "c", count: 64), owner: .init(pid: getpid(), identity: identity), browser: .init(pid: getpid() + 1, identity: identity))
    }
    private func impossibleCode() throws -> ProxyRelayExpectedCode {
        try .init(identifier: "app.neantik.synthetic.invalid", teamIdentifier: "H6VGU2M6JD", cdHash: Data(repeating: 0, count: 20))
    }
    private static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyRelayObservationProtocol.Failure.unavailable }
        do {
            #expect(fcntl(fd, F_SETNOSIGPIPE, 1) == 0)
            #expect(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
            #expect(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(path.utf8) + [UInt8(0)]
            try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            try #require(result == 0)
            return fd
        } catch { _ = Darwin.close(fd); throw error }
    }
    @Test func refusedRealPeerAndMalformedFrameDoNotStopTheEndpoint() async throws {
        let context = try binding(), probe = Probe()
        let server = try ProxyRelayObservationSocket.start(binding: context, expectedManagerCode: impossibleCode(), sessionValid: { probe.admit() }, snapshot: { BrowserRelayActivity().snapshot() })
        let path = ProxyRelayObservationSocket.rootPath(context.sessionGeneration) + "/socket"
        defer { server.cancel() }
        try await Task.detached {
            let malformed = try Self.connect(path)
            var header: [UInt8] = [0, 0, 0, 0]
            try #require(Darwin.write(malformed, &header, header.count) == header.count)
            #expect(throws: (any Error).self) { try ProxyRelayPrivatePipe.readFrame(malformed, timeout: 2) }
            _ = Darwin.close(malformed)
            let refused = try Self.connect(path); defer { _ = Darwin.close(refused) }
            let request = ProxyRelayObservationProtocol.Request(schema: 1, challenge: UUID(), binding: context)
            try ProxyRelayPrivatePipe.writeFrame(refused, data: JSONEncoder().encode(request), timeout: 2)
            #expect(throws: (any Error).self) { try ProxyRelayPrivatePipe.readFrame(refused, timeout: 2) }
        }.value
        #expect(probe.count == 0) // code refusal occurs before session callback
        var node = stat(); #expect(lstat(path, &node) == 0)
        await server.stop()
    }
    @Test func exclusiveEndpointAndOwnedCleanup() async throws {
        let context = try binding(), root = ProxyRelayObservationSocket.rootPath(context.sessionGeneration)
        let code = try impossibleCode()
        let server = try ProxyRelayObservationSocket.start(binding: context, expectedManagerCode: code, sessionValid: { false }, snapshot: { BrowserRelayActivity().snapshot() })
        defer { server.cancel() }
        var info = stat(), node = stat()
        #expect(lstat(root, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(lstat(root + "/socket", &node) == 0 && node.st_mode & 0o777 == 0o600)
        #expect(throws: (any Error).self) { try ProxyRelayObservationSocket.start(binding: context, expectedManagerCode: code, sessionValid: { true }, snapshot: { BrowserRelayActivity().snapshot() }) }
        await server.stop()
        #expect(lstat(root, &info) != 0 && errno == ENOENT)
    }
    @Test func replacementBetweenCaptureAndFinalStatIsRefusedAndRetained() throws {
        let context = try binding(), root = ProxyRelayObservationSocket.rootPath(context.sessionGeneration)
        let path = root + "/socket", replacement = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(replacement >= 0)
        defer { _ = Darwin.close(replacement); _ = unlink(path); _ = rmdir(root) }
        var capturedReplacement = stat()
        #expect(throws: (any Error).self) {
            try ProxyRelayObservationSocket.startForTesting(binding: context, expectedManagerCode: impossibleCode()) {
                try #require(unlink(path) == 0)
                var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                let bytes = Array(path.utf8) + [UInt8(0)]
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(replacement, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                try #require(result == 0 && chmod(path, 0o600) == 0)
                try #require(lstat(path, &capturedReplacement) == 0)
            }
        }
        var retained = stat()
        #expect(lstat(path, &retained) == 0)
        #expect(retained.st_dev == capturedReplacement.st_dev && retained.st_ino == capturedReplacement.st_ino)
    }
    @Test func unknownContentsRetainedOnStop() async throws {
        let context = try binding(), root = ProxyRelayObservationSocket.rootPath(context.sessionGeneration)
        let server = try ProxyRelayObservationSocket.start(binding: context, expectedManagerCode: impossibleCode(), sessionValid: { false }, snapshot: { BrowserRelayActivity().snapshot() })
        let sentinel = URL(fileURLWithPath: root + "/unknown")
        try Data("owned-test-marker".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel); try? FileManager.default.removeItem(atPath: root) }
        await server.stop()
        #expect(try Data(contentsOf: sentinel) == Data("owned-test-marker".utf8))
        var socket = stat(); #expect(lstat(root + "/socket", &socket) != 0)
    }
    @Test func collidingSymlinkIsNotAdoptedOrDeleted() throws {
        let context = try binding(), root = ProxyRelayObservationSocket.rootPath(context.sessionGeneration)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-observation-target-\(UUID())")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        defer { _ = unlink(root); try? FileManager.default.removeItem(at: target) }
        #expect(symlink(target.path, root) == 0)
        #expect(throws: (any Error).self) { try ProxyRelayObservationSocket.start(binding: context, expectedManagerCode: impossibleCode(), sessionValid: { false }, snapshot: { BrowserRelayActivity().snapshot() }) }
        var entry = stat(); #expect(lstat(root, &entry) == 0 && entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
    }
}
