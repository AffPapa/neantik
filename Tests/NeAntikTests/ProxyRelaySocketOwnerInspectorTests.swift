import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelaySocketOwnerInspectorTests {
    @Test func unavailableProcessAndWrongIdentityCannotBecomeOwner() {
        let impossible: pid_t = Int32.max
        #expect(ProxyRelaySocketOwnerInspector.processIdentity(impossible) == nil)
        let wrong = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 0, startMicroseconds: 0), userID: geteuid(), parentProcessID: 0)
        if case .matched = ProxyRelaySocketOwnerInspector.inspect(processID: impossible, expected: wrong, clientPort: 1, relayPort: 2) { Issue.record("Absent PID matched") }
        if case .matched = ProxyRelaySocketOwnerInspector.inspect(processID: getpid(), expected: wrong, clientPort: 1, relayPort: 2) { Issue.record("Wrong generation matched") }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_OWNER_FIXTURE"] == "1"))
    func realLoopbackPeerMatchesOnlyOwningPIDGenerationAndTuple() throws {
        let env = ProcessInfo.processInfo.environment
        let pid = try #require(env["NEANTIK_RELAY_OWNER_PID"].flatMap(Int32.init))
        let clientPort = try #require(env["NEANTIK_RELAY_OWNER_CLIENT_PORT"].flatMap(UInt16.init))
        let unrelatedPort = try #require(env["NEANTIK_RELAY_OTHER_CLIENT_PORT"].flatMap(UInt16.init))
        let relayPort = try #require(env["NEANTIK_RELAY_OWNER_RELAY_PORT"].flatMap(UInt16.init))
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(pid))
        let evidence: ProxyRelaySocketOwnerEvidence
        switch ProxyRelaySocketOwnerInspector.inspect(processID: pid, expected: identity, clientPort: clientPort, relayPort: relayPort) {
        case .matched(let value): evidence = value
        default: throw FixtureFailure.expectedOwnerNotMatched
        }
        #expect(ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: identity, clientPort: clientPort, relayPort: relayPort))
        #expect(!String(describing: evidence).contains(String(pid)))
        #expect(Mirror(reflecting: evidence).children.isEmpty)
        let wrong = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: identity.generation.startSeconds + 1, startMicroseconds: identity.generation.startMicroseconds), userID: identity.userID, parentProcessID: identity.parentProcessID)
        for (expected, port, endpoint) in [(wrong, clientPort, relayPort), (identity, unrelatedPort, relayPort), (identity, clientPort, UInt16(relayPort == 65535 ? 1 : relayPort + 1))] {
            if case .matched = ProxyRelaySocketOwnerInspector.inspect(processID: pid, expected: expected, clientPort: port, relayPort: endpoint) { Issue.record("Wrong generation/other-process tuple/port matched") }
            #expect(!ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: expected, clientPort: port, relayPort: endpoint))
        }
        let controlPort = try #require(env["NEANTIK_RELAY_OWNER_CONTROL_PORT"].flatMap(UInt16.init))
        let control = Process(); control.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        control.arguments = ["-c", "import socket,sys;s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=2);s.sendall(b'reuse\\n');assert s.recv(2)==b'OK'", String(controlPort)]
        control.standardOutput = FileHandle.nullDevice; control.standardError = FileHandle.nullDevice
        try control.run(); control.waitUntilExit(); #expect(control.terminationStatus == 0)
        #expect(!ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: identity, clientPort: clientPort, relayPort: relayPort))
        print("OWNED_RELAY_OWNER_PROOF {\"kernelSocketMatched\":true,\"revalidationPassed\":true,\"negativeControls\":4,\"closedReusedFDRejected\":true,\"browserAuthorityQualified\":false}")
    }
    private enum FixtureFailure: Error { case expectedOwnerNotMatched }
}
