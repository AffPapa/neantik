import Foundation
import Testing
@testable import IsolationCore

@Suite struct QALoopbackFilterScopeTests {
    @Test func exactOwnedPortsAndBothLoopbackFamilies() throws {
        let scope = try QALoopbackFilterScope(ports: [54322, 54321])
        #expect(scope.ports == [54321, 54322])
        #expect(scope.contains(host: "127.0.0.1", port: 54321))
        #expect(scope.contains(host: "::1", port: 54322))
    }
    @Test func neverBroadensToWildcardPrivateOrDNSNames() throws {
        let scope = try QALoopbackFilterScope(ports: [54321])
        for host in ["0.0.0.0", "::", "localhost", "127.0.0.2", "127.0.0.1.invalid", "192.168.1.1", "::ffff:127.0.0.1"] {
            #expect(!scope.contains(host: host, port: 54321))
        }
        #expect(!scope.contains(host: "127.0.0.1", port: 54322))
    }
    @Test func refusesWildcardEmptyDuplicateAndUnboundedPorts() {
        let cases: [[UInt16]] = [[], [0], [54321, 54321], [1, 2, 3, 4, 5]]
        for ports in cases {
            #expect(throws: IsolationRefusal.self) { try QALoopbackFilterScope(ports: ports) }
        }
    }
}
