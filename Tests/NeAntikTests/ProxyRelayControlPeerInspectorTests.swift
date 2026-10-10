import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayControlPeerInspectorTests {
    @Test func realUnixStreamPinsKernelPeerAndRedactsEvidence() throws {
        let pair = try StreamPair(); defer { pair.close() }
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        let evidence = try matched(pair.first, identity)
        #expect(ProxyRelayControlPeerInspector.revalidate(evidence))
        #expect(String(describing: evidence) == "ProxyRelayControlPeerEvidence(<redacted>)")
        #expect(Mirror(reflecting: evidence).children.isEmpty)
        let duplicate = dup(pair.first); defer { Darwin.close(duplicate) }
        #expect(duplicate >= 0)
        // An alias of the same socket is observable; neither descriptor proves
        // exclusive ownership or a lease on the peer process.
        _ = try matched(duplicate, identity)
    }

    @Test func wrongPIDUserAndGenerationRefuseAdmission() throws {
        let pair = try StreamPair(); defer { pair.close() }
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        let generation = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: identity.generation.startSeconds + 1,
            startMicroseconds: identity.generation.startMicroseconds), userID: identity.userID, parentProcessID: identity.parentProcessID)
        let user = ProxyRelayOwnerProcessIdentity(generation: identity.generation, userID: identity.userID &+ 1,
            parentProcessID: identity.parentProcessID)
        for (pid, expected) in [(pid_t(Int32.max), identity), (getpid(), generation), (getpid(), user), (pid_t(0), identity)] {
            if case .matched = ProxyRelayControlPeerInspector.inspect(descriptor: pair.first, expectedProcessID: pid, expectedProcess: expected) {
                Issue.record("Wrong kernel identity admitted")
            }
        }
    }

    @Test func ordinaryQueuedCommandsDoNotChangeSocketIdentity() throws {
        let pair = try StreamPair(); defer { pair.close() }
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        let evidence = try matched(pair.first, identity)
        var byte: UInt8 = 73
        #expect(send(pair.second, &byte, 1, 0) == 1)
        // st_size now reports an unread byte. It is queue state, not socket
        // identity, and must not revoke the same live peer's observation.
        #expect(ProxyRelayControlPeerInspector.revalidate(evidence))
        _ = try matched(pair.first, identity)
        var received: UInt8 = 0
        #expect(recv(pair.first, &received, 1, 0) == 1)
        #expect(received == byte)
        #expect(ProxyRelayControlPeerInspector.revalidate(evidence))
    }

    @Test func closedAndReusedDescriptorInvalidateEvidence() throws {
        let original = try StreamPair(); defer { original.close() }
        let replacement = try StreamPair(); defer { replacement.close() }
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        let evidence = try matched(original.first, identity)
        #expect(dup2(replacement.first, original.first) == original.first)
        #expect(!ProxyRelayControlPeerInspector.revalidate(evidence))
        _ = try matched(original.first, identity)
        #expect(Darwin.close(original.first) == 0)
        original.first = -1
        #expect(!ProxyRelayControlPeerInspector.revalidate(evidence))
    }

    @Test func unrelatedDescriptorKindsAndUnconnectedSocketRefuseProof() throws {
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        var datagrams: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_DGRAM, 0, &datagrams) == 0)
        let unconnected = socket(AF_UNIX, SOCK_STREAM, 0)
        let tcp = socket(AF_INET, SOCK_STREAM, 0)
        let file = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { for fd in datagrams + [unconnected, tcp, file] where fd >= 0 { Darwin.close(fd) } }
        for fd in datagrams + [unconnected, tcp, file, -1] {
            if case .matched = ProxyRelayControlPeerInspector.inspect(descriptor: fd, expectedProcessID: getpid(), expectedProcess: identity) {
                Issue.record("Unconnected or non-Unix-stream descriptor admitted")
            }
        }
    }

    @Test func kernelPeerWithoutExactDeveloperIDCodeIsNotAuthorized() throws {
        let pair = try StreamPair(); defer { pair.close() }
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        let evidence = try matched(pair.first, identity)
        let code = try ProxyRelayExpectedCode(identifier: "app.neantik.majorqa.invalid", teamIdentifier: "H6VGU2M6JD", cdHash: Data(repeating: 0, count: 20))
        #expect(!ProxyRelayControlPeerInspector.matchesLiveCode(evidence, expected: code))
    }

    @Test func actualChildPeerMatchesChildInsteadOfManagerAndEndsCleanly() throws {
        let pair = try StreamPair(); defer { pair.close() }
        var actions: posix_spawn_file_actions_t?
        #expect(posix_spawn_file_actions_init(&actions) == 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        #expect(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        #expect(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        // Only this anonymous, synthetic IPC socket is deliberately inherited.
        let childFD: Int32 = 64
        #expect(pair.first != childFD && pair.second != childFD)
        #expect(posix_spawn_file_actions_adddup2(&actions, pair.second, childFD) == 0)
        #expect(posix_spawn_file_actions_addclose(&actions, pair.first) == 0)
        #expect(posix_spawn_file_actions_addclose(&actions, pair.second) == 0)
        let script = "import socket;s=socket.socket(fileno=64);s.settimeout(5);s.sendall(b'R');assert s.recv(1)==b'Q'"
        let strings = ["/usr/bin/python3", "-c", script].map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil], environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var child: pid_t = 0
        #expect(posix_spawn(&child, "/usr/bin/python3", &actions, &attributes, &argv, &environment) == 0)
        guard child > 0 else { throw Failure.activity }
        var reaped = false
        defer {
            if !reaped { kill(child, SIGKILL); var status: Int32 = 0; waitpid(child, &status, 0) }
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        #expect(setsockopt(pair.first, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        var ready: UInt8 = 0
        #expect(recv(pair.first, &ready, 1, 0) == 1)
        guard ready == 82 else { throw Failure.activity }
        let childIdentity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(child))
        let evidence: ProxyRelayControlPeerEvidence
        switch ProxyRelayControlPeerInspector.inspect(descriptor: pair.first, expectedProcessID: child, expectedProcess: childIdentity) {
        case .matched(let value): evidence = value
        default: throw Failure.unavailable
        }
        #expect(ProxyRelayControlPeerInspector.revalidate(evidence))
        let managerIdentity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        if case .matched = ProxyRelayControlPeerInspector.inspect(descriptor: pair.first, expectedProcessID: getpid(), expectedProcess: managerIdentity) {
            Issue.record("Manager admitted as child peer")
        }
        var stop: UInt8 = 81
        #expect(send(pair.first, &stop, 1, 0) == 1)
        var status: Int32 = 0
        #expect(waitpid(child, &status, 0) == child)
        reaped = true
        #expect(status == 0)
        #expect(!ProxyRelayControlPeerInspector.revalidate(evidence))
    }

    private func matched(_ fd: Int32, _ identity: ProxyRelayOwnerProcessIdentity) throws -> ProxyRelayControlPeerEvidence {
        switch ProxyRelayControlPeerInspector.inspect(descriptor: fd, expectedProcessID: getpid(), expectedProcess: identity) {
        case .matched(let evidence): return evidence
        case .unrelated: throw Failure.unrelated
        case .unavailable: throw Failure.unavailable
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_CONTROL_SIGNED_PEER_FIXTURE"] == "1"))
    func samePIDExecRevokesPreviousExactLiveCodeAdmission() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = try #require(environment["NEANTIK_CONTROL_SIGNED_PEER_ROOT"])
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixturePrefix = workspace.appendingPathComponent(
            "artifacts/neantik/looper-goals/20261008-fury-major/relay-signed-peer-"
        ).path
        guard directory.hasPrefix(fixturePrefix) else { throw Failure.activity }
        let first = directory + "/peer-a", second = directory + "/peer-b"
        func code(_ key: String, identifier: String) throws -> ProxyRelayExpectedCode {
            let text = try #require(environment[key])
            guard text.count == 40 else { throw Failure.activity }
            var bytes = Data()
            for index in stride(from: 0, to: 40, by: 2) {
                let start = text.index(text.startIndex, offsetBy: index), end = text.index(start, offsetBy: 2)
                bytes.append(try #require(UInt8(text[start..<end], radix: 16)))
            }
            return try .init(identifier: identifier, teamIdentifier: "H6VGU2M6JD", cdHash: bytes)
        }
        let codeA = try code("NEANTIK_CONTROL_SIGNED_PEER_A_CDHASH", identifier: "app.neantik.majorqa.peer-a")
        let codeB = try code("NEANTIK_CONTROL_SIGNED_PEER_B_CDHASH", identifier: "app.neantik.majorqa.peer-b")
        let pair = try StreamPair(); defer { pair.close() }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        #expect(posix_spawn_file_actions_init(&actions) == 0)
        #expect(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        #expect(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        #expect(pair.first != 64 && pair.second != 64)
        #expect(posix_spawn_file_actions_adddup2(&actions, pair.second, 64) == 0)
        #expect(posix_spawn_file_actions_addclose(&actions, pair.first) == 0)
        #expect(posix_spawn_file_actions_addclose(&actions, pair.second) == 0)
        let strings = [first, second].map { strdup($0) }; defer { strings.forEach { free($0) } }
        var argv = strings + [nil], env: [UnsafeMutablePointer<CChar>?] = [nil], child: pid_t = 0
        #expect(posix_spawn(&child, first, &actions, &attributes, &argv, &env) == 0)
        guard child > 0 else { throw Failure.activity }
        var reaped = false
        defer { if !reaped { kill(child, SIGKILL); var status: Int32 = 0; waitpid(child, &status, 0) } }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        #expect(setsockopt(pair.first, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        var signal: UInt8 = 0
        #expect(recv(pair.first, &signal, 1, 0) == 1)
        guard signal == 82 else { throw Failure.activity }
        let before = try #require(ProxyRelaySocketOwnerInspector.processIdentity(child))
        let evidence: ProxyRelayControlPeerEvidence
        switch ProxyRelayControlPeerInspector.inspect(descriptor: pair.first, expectedProcessID: child, expectedProcess: before) {
        case .matched(let value): evidence = value
        default: throw Failure.unavailable
        }
        try #require(ProxyRelayControlPeerInspector.matchesLiveCode(evidence, expected: codeA))
        try #require(!ProxyRelayControlPeerInspector.matchesLiveCode(evidence, expected: codeB))
        signal = 69
        #expect(send(pair.first, &signal, 1, 0) == 1)
        #expect(recv(pair.first, &signal, 1, 0) == 1)
        guard signal == 83 else { throw Failure.activity }
        let after = try #require(ProxyRelaySocketOwnerInspector.processIdentity(child))
        try #require(after == before)
        try #require(ProxyRelayControlPeerInspector.revalidate(evidence))
        try #require(!ProxyRelayControlPeerInspector.matchesLiveCode(evidence, expected: codeA))
        try #require(ProxyRelayControlPeerInspector.matchesLiveCode(evidence, expected: codeB))
        signal = 81
        #expect(send(pair.first, &signal, 1, 0) == 1)
        var status: Int32 = 0
        #expect(waitpid(child, &status, 0) == child)
        reaped = true
        try #require(status == 0)
        try #require(!ProxyRelayControlPeerInspector.revalidate(evidence))
        print("OWNED_CONTROL_SIGNED_EXEC_PROOF {\"samePIDGeneration\":true,\"oldLiveCodeRevoked\":true,\"newLiveCodeAdmitted\":true,\"exitedPeerRevoked\":true,\"productionRelayQualified\":false}")
    }
    private enum Failure: Error { case unrelated, unavailable, socketPair, activity }
    private final class StreamPair {
        var first: Int32, second: Int32
        init() throws {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Failure.socketPair }
            first = pair[0]; second = pair[1]
            var byte: UInt8 = 42, readByte: UInt8 = 0
            guard send(second, &byte, 1, 0) == 1, recv(first, &readByte, 1, 0) == 1, readByte == byte else {
                close(); throw Failure.activity
            }
        }
        func close() { if first >= 0 { Darwin.close(first); first = -1 }; if second >= 0 { Darwin.close(second); second = -1 } }
    }
}
