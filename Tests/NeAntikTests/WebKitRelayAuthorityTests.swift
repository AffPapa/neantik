import Foundation
import Testing
@testable import NeAntik

struct WebKitRelayAuthorityTests {
    private func scope(profile: UUID = UUID(), session: UUID = UUID(), revision: UInt64 = 1) -> WebKitRelayAuthority.Scope {
        .init(profileID: profile, storeID: profile, sessionID: session, revision: revision)
    }
    private func bytes(_ capability: WebKitRelayAuthority.Capability) -> Data {
        capability.withCredentials { Data(($0 + ":" + $1).utf8) }
    }
    @Test func rejectsInvalidAndDuplicateScopesBeforeIssuing() throws {
        let authority = WebKitRelayAuthority(), a = scope()
        for bad in [scope(profile: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!),
                    scope(revision: 0), .init(profileID: a.profileID, storeID: UUID(), sessionID: a.sessionID, revision: 1)] {
            #expect(throws: WebKitRelayAuthority.Failure.invalidScope) { try authority.register(scope: bad, route: .direct) }
        }
        try authority.register(scope: a, route: .direct)
        #expect(throws: WebKitRelayAuthority.Failure.duplicateProfile) {
            try authority.register(scope: scope(profile: a.profileID), route: .direct)
        }
        #expect(throws: WebKitRelayAuthority.Failure.unavailable) { try authority.issue(for: scope(profile: a.profileID)) }
        _ = try authority.issue(for: a)
        #expect(throws: WebKitRelayAuthority.Failure.alreadyIssued) { try authority.issue(for: a) }
    }
    @Test func capabilitiesSelectTheirOwnRouteAndHideSecrets() throws {
        let authority = WebKitRelayAuthority(), a = scope(), b = scope()
        try authority.register(scope: a, route: .direct)
        try authority.register(scope: b, route: .proxy(kind: .socks5,
            upstream: .init(host: "upstream.invalid", port: 1080), credentials: nil))
        let ca = try authority.issue(for: a), cb = try authority.issue(for: b)
        #expect(bytes(ca) != bytes(cb))
        let pa = try #require(authority.authorize(bytes(ca))), pb = try #require(authority.authorize(bytes(cb)))
        #expect(pa.scope == a && pb.scope == b)
        if case .direct = pa.route {} else { Issue.record("Direct capability selected another route") }
        if case .proxy(let kind, let endpoint, _) = pb.route {
            #expect(kind == .socks5 && endpoint.host == "upstream.invalid" && endpoint.port == 1080)
        } else { Issue.record("Proxy capability became Direct") }
        #expect(String(reflecting: ca) == "WebKitRelayCapability(<redacted>)")
        #expect(Mirror(reflecting: ca).children.isEmpty)
        #expect(authority.authorize(nil) == nil)
        #expect(authority.authorize(Data("other:wrong".utf8)) == nil)
        var damaged = bytes(ca); damaged[damaged.startIndex] ^= 1
        #expect(authority.authorize(damaged) == nil)
        let mixed = ca.withCredentials { username, _ in cb.withCredentials { _, password in Data((username + ":" + password).utf8) } }
        #expect(authority.authorize(mixed) == nil)
    }
    @Test func staleRevocationAndReusedProfileCannotAffectNewGeneration() throws {
        let authority = WebKitRelayAuthority(), a = scope(), b = scope()
        try authority.register(scope: a, route: .direct); try authority.register(scope: b, route: .direct)
        let old = try authority.issue(for: a), other = try authority.issue(for: b)
        let permit = try #require(authority.authorize(bytes(old)))
        #expect(!authority.revoke(scope(profile: a.profileID)))
        #expect(authority.isCurrent(permit))
        #expect(authority.revoke(a)); #expect(!authority.isCurrent(permit))
        #expect(authority.authorize(bytes(old)) == nil)
        let next = scope(profile: a.profileID, revision: 2)
        try authority.register(scope: next, route: .direct)
        let fresh = try authority.issue(for: next)
        #expect(!authority.revoke(a))
        #expect(authority.authorize(bytes(old)) == nil)
        #expect(authority.authorize(bytes(fresh))?.scope == next)
        #expect(authority.authorize(bytes(other))?.scope == b)
    }
    @Test func closingIsTerminalAndCapacityIsBounded() throws {
        let authority = WebKitRelayAuthority()
        for _ in 0..<WebKitRelayAuthority.maximumProfiles { try authority.register(scope: scope(), route: .direct) }
        #expect(throws: WebKitRelayAuthority.Failure.capacity) { try authority.register(scope: scope(), route: .direct) }
        authority.close(); authority.close()
        #expect(throws: WebKitRelayAuthority.Failure.unavailable) { try authority.register(scope: scope(), route: .direct) }
        #expect(authority.authorize(Data("unknown".utf8)) == nil)
    }
}
