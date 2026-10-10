import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayBrowserRoleDecoderTests {
    private func process(_ type: String, _ pid: Any) -> [String: Any] { ["type":type,"id":pid,"cpuTime":0.125] }
    private func response(_ processes: [[String: Any]], id: Any = 7) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id":id,"result":["processInfo":processes]])
    }
    @Test func matchesOnlyBoundBrowserAndExactNetworkServiceRole() throws {
        let value = try response([process("browser",123),process("renderer",234),process("network.mojom.NetworkService",345)])
        #expect(try ProxyRelayBrowserRoleDecoder.networkService(in: value, requestID: 7, browserPID: 123) == 345)
        #expect(throws: ProxyRelayBrowserRoleDecoder.Failure.missingRole) { try ProxyRelayBrowserRoleDecoder.networkService(in: value, requestID: 7, browserPID: 124) }
        #expect(throws: ProxyRelayBrowserRoleDecoder.Failure.wrongResponse) { try ProxyRelayBrowserRoleDecoder.networkService(in: value, requestID: 8, browserPID: 123) }
        for role in ["utility","network","renderer","network.mojom.NetworkService.wrong"] {
            let wrong = try response([process("browser",123),process(role,345)])
            #expect(throws: ProxyRelayBrowserRoleDecoder.Failure.missingRole) { try ProxyRelayBrowserRoleDecoder.networkService(in: wrong, requestID: 7, browserPID: 123) }
        }
    }
    @Test func rejectsAmbiguousMissingAndMalformedProcessIdentities() throws {
        for processes in [[],[process("browser",123)],
                          [process("browser",123),process("network.mojom.NetworkService",345),process("network.mojom.NetworkService",456)],
                          [process("browser",123),process("network.mojom.NetworkService",123)],
                          [process("browser",123),process("browser",456),process("network.mojom.NetworkService",345)]] {
            let value = try response(processes)
            #expect(throws: (any Error).self) { try ProxyRelayBrowserRoleDecoder.networkService(in: value, requestID: 7, browserPID: 123) }
        }
        for pid in [true,0,-1,345.5,Double(Int32.max)+1] as [Any] {
            let value = try response([process("browser",123),process("network.mojom.NetworkService",pid)])
            #expect(throws: ProxyRelayBrowserRoleDecoder.Failure.malformed) { try ProxyRelayBrowserRoleDecoder.networkService(in: value, requestID: 7, browserPID: 123) }
        }
        let boolID = try response([process("browser",123),process("network.mojom.NetworkService",345)], id: true)
        #expect(throws: ProxyRelayBrowserRoleDecoder.Failure.wrongResponse) { try ProxyRelayBrowserRoleDecoder.networkService(in: boolID, requestID: 1, browserPID: 123) }
    }
    @Test func rejectsProtocolErrorsUnknownFieldsAndBudgets() throws {
        for text in ["{", "[]", "{\"id\":7,\"error\":{\"code\":-32000}}", "{\"id\":7,\"result\":{},\"sessionId\":\"other\"}"] {
            #expect(throws: (any Error).self) { try ProxyRelayBrowserRoleDecoder.networkService(in: Data(text.utf8), requestID: 7, browserPID: 123) }
        }
        let excessive = try response((1...513).map { process("renderer",$0) })
        #expect(throws: ProxyRelayBrowserRoleDecoder.Failure.wrongResponse) { try ProxyRelayBrowserRoleDecoder.networkService(in: excessive, requestID: 7, browserPID: 123) }
        #expect(throws: ProxyRelayBrowserRoleDecoder.Failure.invalidLimit) { try ProxyRelayBrowserRoleDecoder.networkService(in: Data(repeating: 32, count: 65537), requestID: 7, browserPID: 123) }
    }
}
