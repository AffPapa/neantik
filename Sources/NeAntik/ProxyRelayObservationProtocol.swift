import Darwin
import Foundation

/// Closed read-only owner exchange. IDs and public payload hashes bind the
/// exchange; they are correlation, never authority. Not exported to MCP.
enum ProxyRelayObservationProtocol {
    enum Failure: Error { case unavailable, malformed, changed, unsafeEndpoint, ownerRefused, peerRefused }
    struct ProcessBinding: Codable, Equatable, Sendable {
        let pid: pid_t
        let uid: uid_t
        let seconds: Int64
        let microseconds: Int32
        init(pid: pid_t, identity: ProxyRelayOwnerProcessIdentity) {
            self.pid = pid; uid = identity.userID
            seconds = identity.generation.startSeconds; microseconds = identity.generation.startMicroseconds
        }
        func matches(_ identity: ProxyRelayOwnerProcessIdentity?) -> Bool {
            guard let identity else { return false }
            return uid == identity.userID && seconds == identity.generation.startSeconds && microseconds == identity.generation.startMicroseconds
        }
        func validate() throws {
            guard pid > 1, uid == geteuid(), seconds > 0, (0..<1_000_000).contains(microseconds) else { throw Failure.malformed }
        }
    }
    struct Binding: Codable, Equatable, Sendable {
        let profileID: UUID
        let sessionGeneration: UUID
        let profileRevision: UInt64
        let runtimeExecutableSHA256: String
        let runtimeFrameworkSHA256: String
        let configurationSHA256: String
        let owner: ProcessBinding
        let browser: ProcessBinding
        func validate() throws {
            try owner.validate(); try browser.validate()
            guard owner.pid != browser.pid,
                  [runtimeExecutableSHA256, runtimeFrameworkSHA256, configurationSHA256].allSatisfy({
                      $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                  }) else { throw Failure.malformed }
        }
        var processesAreCurrent: Bool {
            owner.matches(ProxyRelaySocketOwnerInspector.processIdentity(owner.pid)) &&
                browser.matches(ProxyRelaySocketOwnerInspector.processIdentity(browser.pid))
        }
    }
    struct Request: Codable, Sendable { let schema: Int; let challenge: UUID; let binding: Binding }
    struct Reply: Codable, Sendable { let schema: Int; let challenge: UUID; let binding: Binding; let activity: BrowserRelayActivity.Snapshot }

    static func readRequest(_ data: Data, expected: Binding) throws -> Request {
        try shape(data, keys: ["schema", "challenge", "binding"])
        let request = try JSONDecoder().decode(Request.self, from: data)
        try request.binding.validate()
        guard request.schema == 1, request.binding == expected else { throw Failure.changed }
        return request
    }
    static func readReply(_ data: Data, request: Request) throws -> BrowserRelayActivity.Snapshot {
        try shape(data, keys: ["schema", "challenge", "binding", "activity"])
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        try reply.binding.validate()
        guard reply.schema == 1, reply.challenge == request.challenge, reply.binding == request.binding else { throw Failure.changed }
        let s = reply.activity, limit: UInt64 = 9_007_199_254_740_991
        let counts = [s.sequence, s.admittedConnections, s.upstreamTunnels, s.successRepliesSent,
                      s.completedConnections, s.failedConnections, s.cancelledConnections]
        guard s.schema == 1, (0...64).contains(s.activeConnections), counts.allSatisfy({ $0 <= limit }),
              s.successRepliesSent <= s.upstreamTunnels, s.upstreamTunnels <= s.admittedConnections,
              (s.lastFailure == nil) == (s.lastFailureSequence == nil), s.lastFailure?.isFailure != false,
              s.lastFailureSequence.map({ $0 <= s.sequence }) ?? true,
              s.lastEventAgeMilliseconds.map({ $0 <= limit }) ?? true
        else { throw Failure.malformed }
        if !s.countersSaturated {
            guard s.completedConnections + s.failedConnections + s.cancelledConnections + UInt64(s.activeConnections) == s.admittedConnections else { throw Failure.malformed }
        }
        return s
    }
    private static func shape(_ data: Data, keys: Set<String>) throws {
        guard !data.isEmpty, data.count <= ProxyRelayPrivatePipe.maximumFrameBytes else { throw Failure.malformed }
        try ImportJSONShape.validate(data) // rejects duplicate/escaped equivalent keys before decoding
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys else { throw Failure.malformed }
    }
}
