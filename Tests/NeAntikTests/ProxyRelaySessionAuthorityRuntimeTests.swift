import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelaySessionAuthorityRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_SESSION_AUTHORITY_FIXTURE"] == "1"))
    func realHeadedSignedProfileOwnsOnlyItsProxySocket() throws {
        let env = ProcessInfo.processInfo.environment
        let pid = try #require(env["NEANTIK_RELAY_MAIN_PID"].flatMap(Int32.init))
        let browser = try #require(ProxyRelaySocketOwnerInspector.processIdentity(pid))
        let mainURL = URL(fileURLWithPath: try #require(env["NEANTIK_RELAY_MAIN_EXECUTABLE"]))
        let helperURL = URL(fileURLWithPath: try #require(env["NEANTIK_RELAY_HELPER_EXECUTABLE"]))
        let mainID = try #require(env["NEANTIK_RELAY_EXPECTED_MAIN_ID"])
        let helperID = try #require(env["NEANTIK_RELAY_EXPECTED_HELPER_ID"])
        let team = try #require(env["NEANTIK_RELAY_EXPECTED_HELPER_TEAM"])
        let main = try ProxyRelayExpectedCode.qualifiedPin(at: mainURL, expectedIdentifier: mainID, expectedTeamIdentifier: team)
        let helper = try ProxyRelayExpectedCode.qualifiedPin(at: helperURL, expectedIdentifier: helperID, expectedTeamIdentifier: team)
        let live = ProxyRelaySessionAuthority.Inspector.live(mainCode: main, helperCode: helper)
        let peer = ProxyRelayLoopbackServer.Peer(clientPort: try #require(env["NEANTIK_RELAY_CLIENT_PORT"].flatMap(UInt16.init)),
                                               relayPort: try #require(env["NEANTIK_RELAY_PORT"].flatMap(UInt16.init)))
        let binding = try ProxyRelaySessionAuthority.Binding(profileID: UUID(), sessionGeneration: UUID(),
            runtimeExecutableSHA256: try #require(env["NEANTIK_RELAY_RUNTIME_EXE_SHA256"]),
            runtimeFrameworkSHA256: try #require(env["NEANTIK_RELAY_RUNTIME_FW_SHA256"]),
            configurationSHA256: String(repeating: "f", count: 64), browserPID: pid, browserIdentity: browser)
        let authority = ProxyRelaySessionAuthority(binding: binding, inspector: live)
        try #require(live.mainCode(pid, browser), "Exact main dynamic code pin refused")
        let candidates = try #require(live.children(pid), "Kernel child-list observation unavailable")
        try #require(!candidates.isEmpty, "No direct runtime children observed")
        let observations = candidates.map { child -> [String: Bool] in
            guard let identity = live.identity(child) else { return ["identity": false] }
            return ["identity": true, "parent": identity.parentProcessID == pid,
                    "uid": identity.userID == browser.userID,
                    "socket": live.socket(child, identity, peer), "code": live.helperCode(child, identity)]
        }
        print("OWNED_SESSION_AUTHORITY_DIAGNOSTIC " + String(data: try JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys]), encoding: .utf8)!)
        try #require(authority.admits(peer), "Live signed browser children did not own the exact fixture socket")
        #expect(!authority.admits(.init(clientPort: peer.clientPort, relayPort: peer.relayPort == 65535 ? 1 : peer.relayPort + 1)))
        let wrongGeneration = try ProxyRelaySessionAuthority.Binding(profileID: binding.profileID, sessionGeneration: binding.sessionGeneration,
            runtimeExecutableSHA256: binding.runtimeExecutableSHA256, runtimeFrameworkSHA256: binding.runtimeFrameworkSHA256,
            configurationSHA256: binding.configurationSHA256, browserPID: pid,
            browserIdentity: .init(generation: .init(startSeconds: browser.generation.startSeconds + 1, startMicroseconds: browser.generation.startMicroseconds),
                                   userID: browser.userID, parentProcessID: browser.parentProcessID))
        #expect(!ProxyRelaySessionAuthority(binding: wrongGeneration, inspector: live).admits(peer))
        // Another correctly signed browser helper is not sufficient: the main
        // executable pin must identify the main rather than the helper role.
        #expect(!ProxyRelaySessionAuthority(binding: binding, inspector: .live(mainCode: helper, helperCode: helper)).admits(peer))
        #expect(!ProxyRelaySessionAuthority(binding: binding, inspector: .live(mainCode: main, helperCode: main)).admits(peer))
        authority.revoke(); #expect(!authority.admits(peer))
        #expect(throws: (any Error).self) { try ProxyRelayExpectedCode.qualifiedPin(at: helperURL, expectedIdentifier: helperID + ".wrong", expectedTeamIdentifier: team) }
        #expect(throws: (any Error).self) { try ProxyRelayExpectedCode.qualifiedPin(at: helperURL, expectedIdentifier: helperID, expectedTeamIdentifier: "ABC1234567") }
        print("OWNED_SESSION_AUTHORITY_PROOF {\"signedProfileSocketAdmitted\":true,\"wrongSocketRefused\":true,\"wrongGenerationRefused\":true,\"wrongMainCodeRefused\":true,\"wrongHelperCodeRefused\":true,\"revocationRefused\":true,\"upstreamCredentialsUsed\":false,\"productionRelayEnabled\":false}")
    }
}
