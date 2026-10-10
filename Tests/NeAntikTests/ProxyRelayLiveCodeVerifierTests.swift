import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayLiveCodeVerifierTests {
    @Test func unsafeRequirementInputsCannotCompile() throws {
        let hash = Data(repeating: 1, count: 20)
        for id in ["", "bad\" or true", "app\nhelper", String(repeating: "a", count: 201), "app.🙃"] {
            #expect(throws: ProxyRelayExpectedCode.Failure.invalidIdentity) { try ProxyRelayExpectedCode(identifier: id, teamIdentifier: "H6VGU2M6JD", cdHash: hash) }
        }
        for team in ["", "abc", "h6vgu2m6jd", "H6VGU2M6J\""] {
            #expect(throws: ProxyRelayExpectedCode.Failure.invalidIdentity) { try ProxyRelayExpectedCode(identifier: "app.neantik.runtime.helper", teamIdentifier: team, cdHash: hash) }
        }
        for count in [0,19,21,32] {
            #expect(throws: ProxyRelayExpectedCode.Failure.invalidIdentity) { try ProxyRelayExpectedCode(identifier: "app.neantik.runtime.helper", teamIdentifier: "H6VGU2M6JD", cdHash: Data(repeating: 0, count: count)) }
        }
    }
    @Test func missingOrWrongGenerationCannotBecomeLiveCodeProof() throws {
        let code = try ProxyRelayExpectedCode(identifier: "app.neantik.runtime.helper", teamIdentifier: "H6VGU2M6JD", cdHash: Data(repeating: 1, count: 20))
        let own = try #require(ProxyRelaySocketOwnerInspector.processIdentity(getpid()))
        let wrong = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: own.generation.startSeconds+1, startMicroseconds: own.generation.startMicroseconds), userID: own.userID, parentProcessID: own.parentProcessID)
        #expect(!ProxyRelayLiveCodeVerifier.matches(processID: 0, expectedProcess: own, expectedCode: code))
        #expect(!ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: wrong, expectedCode: code))
    }
}
