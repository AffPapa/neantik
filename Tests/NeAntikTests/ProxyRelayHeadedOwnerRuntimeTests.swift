import Darwin
import Foundation
import Testing
@testable import NeAntik

/// Exact headed owned-fixture observation. This does not enable a listener,
/// send credentials, bypass sandboxing or authorize production relay use.
struct ProxyRelayHeadedOwnerRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_PRIVATE_PIPE_FIXTURE"] == "1"))
    func privatePipeRoleBindsLiveCodeAndSocketWithoutArguments() throws {
        let env = ProcessInfo.processInfo.environment
        let main = try #require(env["NEANTIK_RELAY_MAIN_PID"].flatMap(Int32.init))
        let request = try #require(env["NEANTIK_RELAY_PIPE_REQUEST_ID"].flatMap(Int.init))
        let fixture = try #require(env["NEANTIK_RELAY_PIPE_RESPONSE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let child = try ProxyRelayBrowserRoleDecoder.networkService(in: data, requestID: request, browserPID: main)
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(child))
        try #require(identity.userID == geteuid() && identity.parentProcessID == main)
        let text = "341376139777922eb29ee9ed199bec7dd8b639e5", bytes = Array(text.utf8)
        var hash = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            hash.append(try #require(UInt8(String(bytes: bytes[index..<(index+2)], encoding: .ascii)!, radix: 16)))
        }
        let pin = try ProxyRelayExpectedCode(identifier: "app.neantik.runtime.helper", teamIdentifier: "H6VGU2M6JD", cdHash: hash)
        try #require(ProxyRelayLiveCodeVerifier.matches(processID: child, expectedProcess: identity, expectedCode: pin))
        let client = try #require(env["NEANTIK_RELAY_CLIENT_PORT"].flatMap(UInt16.init))
        let relay = try #require(env["NEANTIK_RELAY_PORT"].flatMap(UInt16.init))
        guard case .matched(let evidence) = ProxyRelaySocketOwnerInspector.inspect(processID: child, expected: identity, clientPort: client, relayPort: relay) else {
            throw FixtureFailure.networkServiceSocketNotObserved
        }
        try #require(ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: identity, clientPort: client, relayPort: relay))
        #expect(throws: (any Error).self) { try ProxyRelayBrowserRoleDecoder.networkService(in: data, requestID: request+1, browserPID: main) }
        #expect(throws: (any Error).self) { try ProxyRelayBrowserRoleDecoder.networkService(in: data, requestID: request, browserPID: main+1) }
        print("OWNED_PRIVATE_PIPE_ROLE_PROOF {\"privatePipeRoleDecoded\":true,\"dynamicHelperCodePinVerified\":true,\"kernelIdentityAndSocketMatched\":true,\"wrongRequestRejected\":true,\"wrongBrowserRejected\":true,\"processArgumentsRead\":false,\"relayAuthorizationQualified\":false}")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_HEADED_LIVE_CODE_FIXTURE"] == "1"))
    func exactHeadedHelperDynamicCodeMatchesQualifiedPin() throws {
        let env = ProcessInfo.processInfo.environment
        let main = try #require(env["NEANTIK_RELAY_MAIN_PID"].flatMap(Int32.init))
        let child = try #require(env["NEANTIK_RELAY_NETWORK_PID"].flatMap(Int32.init))
        let hashText = try #require(env["NEANTIK_RELAY_EXPECTED_HELPER_CDHASH"])
        try #require(hashText.utf8.count == 40)
        let bytes = Array(hashText.utf8)
        var hash = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let pair = String(bytes: bytes[index..<(index+2)], encoding: .ascii)
            hash.append(try #require(pair.flatMap { UInt8($0, radix: 16) }))
        }
        let identifier = try #require(env["NEANTIK_RELAY_EXPECTED_HELPER_ID"])
        let team = try #require(env["NEANTIK_RELAY_EXPECTED_HELPER_TEAM"])
        let pin = try ProxyRelayExpectedCode(identifier: identifier, teamIdentifier: team, cdHash: hash)
        if env["NEANTIK_RELAY_OWNER_PHASE"] == "stopped" {
            let absent = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 0, startMicroseconds: 0), userID: geteuid(), parentProcessID: main)
            try #require(!ProxyRelayLiveCodeVerifier.matches(processID: child, expectedProcess: absent, expectedCode: pin))
            print("OWNED_HEADED_LIVE_CODE_STOPPED {\"stoppedPIDRejected\":true}")
            return
        }
        let identity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(child))
        try #require(identity.userID == geteuid() && identity.parentProcessID == main)
        try #require(ProxyRelayLiveCodeVerifier.matches(processID: child, expectedProcess: identity, expectedCode: pin), "Exact live helper code pin refused")
        var wrongHash = hash; wrongHash[0] ^= 1
        for wrong in [try ProxyRelayExpectedCode(identifier: identifier+".wrong", teamIdentifier: team, cdHash: hash),
                      try ProxyRelayExpectedCode(identifier: identifier, teamIdentifier: "ABC123DEF4", cdHash: hash),
                      try ProxyRelayExpectedCode(identifier: identifier, teamIdentifier: team, cdHash: wrongHash)] {
            try #require(!ProxyRelayLiveCodeVerifier.matches(processID: child, expectedProcess: identity, expectedCode: wrong))
        }
        let wrongGeneration = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: identity.generation.startSeconds+1, startMicroseconds: identity.generation.startMicroseconds), userID: identity.userID, parentProcessID: identity.parentProcessID)
        try #require(!ProxyRelayLiveCodeVerifier.matches(processID: child, expectedProcess: wrongGeneration, expectedCode: pin))
        let mainIdentity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(main))
        try #require(!ProxyRelayLiveCodeVerifier.matches(processID: main, expectedProcess: mainIdentity, expectedCode: pin))
        let testIdentity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        try #require(!ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: testIdentity, expectedCode: pin))
        print("OWNED_HEADED_LIVE_CODE_PROOF {\"dynamicHelperCodePinVerified\":true,\"wrongIdentifierRejected\":true,\"wrongTeamRejected\":true,\"wrongCDHashRejected\":true,\"wrongGenerationRejected\":true,\"signedMainRejected\":true,\"testProcessRejected\":true,\"relayAuthorizationQualified\":false}")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_RELAY_HEADED_OWNER_FIXTURE"] == "1"))
    func exactHeadedNetworkServiceOwnsObservedProxySocket() throws {
        let env = ProcessInfo.processInfo.environment
        let main = try #require(env["NEANTIK_RELAY_MAIN_PID"].flatMap(Int32.init))
        let child = try #require(env["NEANTIK_RELAY_NETWORK_PID"].flatMap(Int32.init))
        if env["NEANTIK_RELAY_OWNER_PHASE"] == "stopped" {
            #expect(ProxyRelaySocketOwnerInspector.processIdentity(child) == nil)
            #expect(ProxyRelaySocketOwnerInspector.processIdentity(main) == nil)
            print("OWNED_HEADED_OWNER_STOPPED {\"mainAndNetworkServiceGone\":true}")
            return
        }
        let clientPort = try #require(env["NEANTIK_RELAY_CLIENT_PORT"].flatMap(UInt16.init))
        let relayPort = try #require(env["NEANTIK_RELAY_PORT"].flatMap(UInt16.init))
        let mainIdentity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(main))
        let childIdentity = try #require(ProxyRelaySocketOwnerInspector.processIdentity(child))
        #expect(mainIdentity.userID == geteuid() && childIdentity.userID == geteuid())
        #expect(childIdentity.parentProcessID == main)
        let mainArgs = try #require(arguments(main))
        let childArgs = try #require(arguments(child))
        let browserData = try #require(env["NEANTIK_RELAY_OWN_BROWSER_DATA"])
        #expect(mainArgs.arguments.filter { $0.hasPrefix("--user-data-dir=") } == ["--user-data-dir=" + browserData])
        #expect(mainArgs.executablePath == env["NEANTIK_RELAY_MAIN_EXECUTABLE"])
        #expect(childArgs.executablePath == env["NEANTIK_RELAY_HELPER_EXECUTABLE"])
        #expect(childArgs.arguments.filter { $0.hasPrefix("--type=") } == ["--type=utility"])
        #expect(childArgs.arguments.filter { $0.hasPrefix("--utility-sub-type=") } == ["--utility-sub-type=network.mojom.NetworkService"])
        let evidence: ProxyRelaySocketOwnerEvidence
        switch ProxyRelaySocketOwnerInspector.inspect(processID: child, expected: childIdentity, clientPort: clientPort, relayPort: relayPort) {
        case .matched(let observed): evidence = observed
        default: throw FixtureFailure.networkServiceSocketNotObserved
        }
        #expect(ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: childIdentity, clientPort: clientPort, relayPort: relayPort))
        if case .matched = ProxyRelaySocketOwnerInspector.inspect(processID: main, expected: mainIdentity, clientPort: clientPort, relayPort: relayPort) { Issue.record("Browser main mistaken for socket owner") }
        #expect(ProxyRelaySocketOwnerInspector.processIdentity(main) == mainIdentity)
        #expect(ProxyRelaySocketOwnerInspector.processIdentity(child) == childIdentity)
        print("OWNED_HEADED_OWNER_PROOF {\"networkServicePIDGenerationAndParentMatched\":true,\"proxySocketMatched\":true,\"mainProcessNegativeRejected\":true,\"profilePathMatched\":true,\"relayAuthorizationQualified\":false}")
    }
    private func arguments(_ pid: pid_t) -> BrowserProcessArguments? {
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
        defer { bytes.withUnsafeMutableBytes { _ = Darwin.memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
        var size = bytes.count, mib = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = mib.withUnsafeMutableBufferPointer { values in
            bytes.withUnsafeMutableBytes { data in sysctl(values.baseAddress, u_int(values.count), data.baseAddress, &size, nil, 0) }
        }
        guard result == 0 else { return nil }
        return BrowserProcessArgumentParser.decode(bytes, byteCount: size)
    }
    private enum FixtureFailure: Error { case networkServiceSocketNotObserved }
}
