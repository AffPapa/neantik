import Foundation
import Testing
@testable import NeAntik

@Suite struct MCPGUIControlAuthorityTests {
    typealias Wire = MCPGUIControlProtocol
    let root = String(repeating: "a", count: 64)

    private func request(_ authority: MCPGUIControlAuthority, client: MCPGUIControlAuthority.Client? = nil,
                         sequence: UInt64 = 1, operation: Wire.Command = .connect, profileID: UUID? = nil,
                         revision: UInt64? = nil) -> Wire.Request {
        Wire.Request(endpointGeneration: authority.endpointGeneration, libraryIdentitySHA256: root,
            connectionGeneration: client?.generation, sequence: sequence, operation: operation,
            profileID: profileID, expectedRevision: revision)
    }

    @Test func signedPeerAloneDoesNotGrantProfilePermission() throws {
        var authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        let connection = UUID(), profile = UUID()
        let client = try authority.connect(request(authority), transportID: connection)
        let start = request(authority, client: client, sequence: 2, operation: .start, profileID: profile, revision: 7)
        #expect(throws: Wire.Failure.consentRequired) { try authority.authorize(start, transportID: connection) }
        try authority.approve(transportID: connection, profiles: [profile])
        // A failed consent request was consumed, never silently replayed.
        #expect(throws: Wire.Failure.staleSession) { try authority.authorize(start, transportID: connection) }
        let next = request(authority, client: client, sequence: 3, operation: .start, profileID: profile, revision: 7)
        try authority.authorize(next, transportID: connection)
        #expect(authority.clients[connection]?.approvedProfiles == [profile])
    }

    @Test func twoClientsCannotStopEachOthersOrManualWindows() throws {
        var authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        let a = UUID(), b = UUID(), profile = UUID(), browser = UUID()
        let ca = try authority.connect(request(authority), transportID: a)
        let cb = try authority.connect(request(authority), transportID: b)
        try authority.approve(transportID: a, profiles: [profile]); try authority.approve(transportID: b, profiles: [profile])
        let start = request(authority, client: ca, sequence: 2, operation: .start, profileID: profile, revision: 7)
        try authority.authorize(start, transportID: a)
        try authority.recordLaunch(start, transportID: a, browserGeneration: browser)
        let foreign = request(authority, client: cb, sequence: 2, operation: .stop, profileID: profile)
        try authority.authorize(foreign, transportID: b)
        #expect(throws: Wire.Failure.ownershipLost) { try authority.ownedGeneration(foreign, transportID: b) }
        let stop = request(authority, client: ca, sequence: 3, operation: .stop, profileID: profile)
        try authority.authorize(stop, transportID: a)
        #expect(try authority.state(stop, transportID: a, currentBrowserGeneration: UUID(), saveFailed: false) == .ownershipLost)
        #expect(throws: Wire.Failure.ownershipLost) { try authority.markStopRequested(stop, transportID: a, currentBrowserGeneration: UUID()) }
        #expect(try authority.state(stop, transportID: a, currentBrowserGeneration: browser, saveFailed: false) == .managed)
    }

    @Test func stopRemainsPendingUntilRealCloseAndSaveSettlement() throws {
        var authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        let connection = UUID(), profile = UUID(), browser = UUID()
        let client = try authority.connect(request(authority), transportID: connection)
        try authority.approve(transportID: connection, profiles: [profile])
        let start = request(authority, client: client, sequence: 2, operation: .start, profileID: profile, revision: 0)
        try authority.authorize(start, transportID: connection); try authority.recordLaunch(start, transportID: connection, browserGeneration: browser)
        let stop = request(authority, client: client, sequence: 3, operation: .stop, profileID: profile)
        try authority.authorize(stop, transportID: connection)
        try authority.markStopRequested(stop, transportID: connection, currentBrowserGeneration: browser)
        #expect(try authority.state(stop, transportID: connection, currentBrowserGeneration: browser, saveFailed: false) == .stopPending)
        #expect(try authority.state(stop, transportID: connection, currentBrowserGeneration: browser, saveFailed: true) == .saveFailed)
        #expect(try authority.state(stop, transportID: connection, currentBrowserGeneration: nil, saveFailed: true) == .saveFailed)
        #expect(try authority.state(stop, transportID: connection, currentBrowserGeneration: nil, saveFailed: false) == .ownershipLost)
        _ = authority.observeClosed(profileID: profile, browserGeneration: browser)
        #expect(try authority.state(stop, transportID: connection, currentBrowserGeneration: nil, saveFailed: false) == .stopped)
    }

    @Test func revocationDuringAwaitAndReconnectCannotInheritAuthority() throws {
        var authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        let connection = UUID(), profile = UUID(), browser = UUID()
        let old = try authority.connect(request(authority), transportID: connection)
        try authority.approve(transportID: connection, profiles: [profile])
        let start = request(authority, client: old, sequence: 2, operation: .start, profileID: profile, revision: 9)
        try authority.authorize(start, transportID: connection)
        authority.disconnect(connection)
        #expect(throws: Wire.Failure.staleSession) { try authority.recordLaunch(start, transportID: connection, browserGeneration: browser) }
        let fresh = try authority.connect(request(authority), transportID: connection)
        #expect(fresh.generation != old.generation && fresh.isPending)
        #expect(throws: Wire.Failure.staleSession) { try authority.requireScope(start, transportID: connection) }
        try authority.approve(transportID: connection, profiles: [profile])
        let status = request(authority, client: fresh, sequence: 2, operation: .status, profileID: profile)
        try authority.authorize(status, transportID: connection)
        #expect(throws: Wire.Failure.ownershipLost) { try authority.ownedGeneration(status, transportID: connection) }
    }

    @Test func operationRequiresCurrentSuccessfulAdmissionAndCannotCommitTwice() throws {
        var authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        let connection = UUID(), profile = UUID()
        let client = try authority.connect(request(authority), transportID: connection)
        let start = request(authority, client: client, sequence: 2, operation: .start, profileID: profile, revision: 1)
        #expect(throws: Wire.Failure.consentRequired) { try authority.authorize(start, transportID: connection) }
        try authority.approve(transportID: connection, profiles: [profile])
        // Approval after a refused request must not revive that operation.
        #expect(throws: Wire.Failure.staleSession) { try authority.recordLaunch(start, transportID: connection, browserGeneration: UUID()) }
        let unadmitted = request(authority, client: client, sequence: 3, operation: .start, profileID: profile, revision: 1)
        #expect(throws: Wire.Failure.staleSession) { try authority.recordLaunch(unadmitted, transportID: connection, browserGeneration: UUID()) }
        try authority.authorize(unadmitted, transportID: connection)
        let next = request(authority, client: client, sequence: 4, operation: .start, profileID: profile, revision: 1)
        try authority.authorize(next, transportID: connection)
        #expect(throws: Wire.Failure.staleSession) { try authority.recordLaunch(unadmitted, transportID: connection, browserGeneration: UUID()) }
        try authority.recordLaunch(next, transportID: connection, browserGeneration: UUID())
        #expect(throws: Wire.Failure.staleSession) { try authority.recordLaunch(next, transportID: connection, browserGeneration: UUID()) }
    }

    @Test func newLaunchRequiresMatchingSettledCloseOfPreviousGeneration() throws {
        var authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        let connection = UUID(), profile = UUID(), browser = UUID()
        let client = try authority.connect(request(authority), transportID: connection)
        try authority.approve(transportID: connection, profiles: [profile])
        let first = request(authority, client: client, sequence: 2, operation: .start, profileID: profile, revision: 1)
        try authority.authorize(first, transportID: connection); try authority.recordLaunch(first, transportID: connection, browserGeneration: browser)
        let second = request(authority, client: client, sequence: 3, operation: .start, profileID: profile, revision: 2)
        try authority.authorize(second, transportID: connection)
        #expect(throws: Wire.Failure.busy) { try authority.recordLaunch(second, transportID: connection, browserGeneration: UUID()) }
        let wrongClose = authority.observeClosed(profileID: profile, browserGeneration: UUID())
        #expect(!wrongClose)
        #expect(throws: Wire.Failure.busy) { try authority.recordLaunch(second, transportID: connection, browserGeneration: UUID()) }
        let matchingClose = authority.observeClosed(profileID: profile, browserGeneration: browser)
        #expect(matchingClose)
        try authority.recordLaunch(second, transportID: connection, browserGeneration: UUID())
        let staleClose = authority.observeClosed(profileID: profile, browserGeneration: browser)
        #expect(!staleClose)
    }

    @Test func scopeAndEndpointDoNotExpandThroughUntrustedRequests() throws {
        var authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        let connection = UUID(), allowed = UUID()
        let client = try authority.connect(request(authority), transportID: connection)
        #expect(throws: Wire.Failure.denied) { try authority.approve(transportID: connection, profiles: []) }
        #expect(throws: Wire.Failure.denied) { try authority.approve(transportID: connection, profiles: Set((0..<65).map { _ in UUID() })) }
        try authority.approve(transportID: connection, profiles: [allowed])
        #expect(throws: Wire.Failure.staleSession) { try authority.approve(transportID: connection, profiles: [allowed, UUID()]) }
        let outside = request(authority, client: client, sequence: 2, operation: .start, profileID: UUID(), revision: 1)
        #expect(throws: Wire.Failure.denied) { try authority.authorize(outside, transportID: connection) }
        let anotherRoot = Wire.Request(endpointGeneration: authority.endpointGeneration, libraryIdentitySHA256: String(repeating: "b", count: 64),
            connectionGeneration: client.generation, sequence: 3, operation: .status, profileID: allowed)
        #expect(throws: Wire.Failure.staleSession) { try authority.authorize(anotherRoot, transportID: connection) }
        let anotherEndpoint = Wire.Request(endpointGeneration: UUID(), libraryIdentitySHA256: root,
            connectionGeneration: client.generation, sequence: 3, operation: .status, profileID: allowed)
        #expect(throws: Wire.Failure.staleSession) { try authority.authorize(anotherEndpoint, transportID: connection) }
        let valid = request(authority, client: client, sequence: 3, operation: .status, profileID: allowed)
        try authority.authorize(valid, transportID: connection)
        authority.revokeAll()
        #expect(throws: Wire.Failure.staleSession) { try authority.requireScope(valid, transportID: connection) }
    }

    @Test func clientsAreBoundedAndReconnectDoesNotReuseSequence() throws {
        var authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        for _ in 0..<8 { _ = try authority.connect(request(authority), transportID: UUID()) }
        #expect(throws: Wire.Failure.busy) { try authority.connect(request(authority), transportID: UUID()) }
        authority.revokeAll(); #expect(authority.clients.isEmpty)
    }

    @Test func wireRejectsUnknownDuplicateNestedAndAmbiguousFields() throws {
        let authority = MCPGUIControlAuthority(libraryIdentitySHA256: root)
        let valid = request(authority)
        let encoded = try JSONEncoder().encode(valid)
        #expect(try Wire.decodeRequest(encoded) == valid)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, value) in [("url", "https://example.com/" as Any), ("script", "not executable" as Any),
                             ("sequence", "01" as Any), ("sequence", 1 as Any), ("schemaVersion", true as Any),
                             ("operation", "shell" as Any), ("profileID", UUID().uuidString as Any),
                             ("libraryIdentitySHA256", "bad" as Any)] {
            var malformed = object; malformed[key] = value
            let data = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: (any Error).self) { try Wire.decodeRequest(data) }
        }
        let text = try #require(String(data: encoded, encoding: .utf8))
        let duplicate = Data((text.dropLast() + ",\"sequence\":\"1\"}").utf8)
        #expect(throws: (any Error).self) { try Wire.decodeRequest(duplicate) }
        #expect(throws: (any Error).self) { try Wire.decodeRequest(Data(repeating: 32, count: Wire.maximumMessageBytes + 1)) }
        object["expectedRevision"] = "0"
        #expect(throws: (any Error).self) { try Wire.decodeRequest(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func replyMustMatchThisExactRequestAndConnection() throws {
        let authority = MCPGUIControlAuthority(libraryIdentitySHA256: root), connection = UUID()
        let connect = request(authority)
        let reply = Wire.Reply(request: connect, connectionGeneration: connection, state: .pendingConsent)
        let data = try JSONEncoder().encode(reply)
        #expect(try Wire.decodeReply(data, request: connect, expectedConnection: nil) == reply)
        #expect(throws: (any Error).self) { try Wire.decodeReply(data, request: connect, expectedConnection: UUID()) }
        let ambiguous = Wire.Reply(request: connect, connectionGeneration: connection, state: .connected, failure: .denied)
        #expect(throws: (any Error).self) { try Wire.decodeReply(JSONEncoder().encode(ambiguous), request: connect, expectedConnection: nil) }
        let impossible = Wire.Reply(request: connect, connectionGeneration: connection, state: .stopped, revision: 7)
        #expect(throws: (any Error).self) { try Wire.decodeReply(JSONEncoder().encode(impossible), request: connect, expectedConnection: nil) }
        let failedRevision = Wire.Reply(request: connect, connectionGeneration: connection, revision: 7, failure: .denied)
        #expect(throws: (any Error).self) { try Wire.decodeReply(JSONEncoder().encode(failedRevision), request: connect, expectedConnection: nil) }
        let different = Wire.Request(endpointGeneration: UUID(), libraryIdentitySHA256: root, sequence: 1, operation: .connect)
        #expect(throws: (any Error).self) { try Wire.decodeReply(data, request: different, expectedConnection: nil) }
    }
}
