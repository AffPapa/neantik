import Foundation

/// A disposable filter may see only its own bounded loopback server ports.
/// This scope is not a production firewall or an exemption for a local relay.
public struct QALoopbackFilterScope: Equatable, Sendable {
    public let ports: [UInt16]
    public init(ports: [UInt16]) throws {
        guard !ports.isEmpty, ports.count <= 4, !ports.contains(0),
              Set(ports).count == ports.count else { throw IsolationRefusal.invalidToken }
        self.ports = ports.sorted()
    }
    public func contains(host: String, port: UInt16) -> Bool {
        ["127.0.0.1", "::1"].contains(host) && ports.contains(port)
    }
}
