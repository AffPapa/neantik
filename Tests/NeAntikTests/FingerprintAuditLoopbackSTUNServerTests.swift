import Foundation
import Network
import Testing
@testable import NeAntik

struct FingerprintAuditLoopbackSTUNServerTests {
    private let endpoint = NWEndpoint.hostPort(
        host: "127.0.0.1",
        port: 49_152
    )

    @Test
    func buildsBoundedBindingSuccessWithoutPersistedEndpointData() throws {
        let transaction = Array(UInt8(1)...UInt8(12))
        let request = Data(
            [
                0x00, 0x01,
                0x00, 0x00,
                0x21, 0x12, 0xA4, 0x42
            ] + transaction
        )

        let response = try #require(
            FingerprintAuditLoopbackSTUNServer.response(
                for: request,
                remoteEndpoint: endpoint
            )
        )
        let bytes = [UInt8](response)

        #expect(response.count == 32)
        #expect(bytes[0] == 0x01)
        #expect(bytes[1] == 0x01)
        #expect(Array(bytes[8..<20]) == transaction)
        #expect(bytes[20] == 0x00)
        #expect(bytes[21] == 0x20)
        #expect(!String(decoding: response, as: UTF8.self).contains("127.0.0.1"))
    }

    @Test
    func rejectsMalformedOrNonLoopbackDatagrams() {
        let valid = Data(
            [
                0x00, 0x01,
                0x00, 0x00,
                0x21, 0x12, 0xA4, 0x42
            ] + Array(repeating: UInt8(0x11), count: 12)
        )
        let nonLoopback = NWEndpoint.hostPort(
            host: "192.0.2.1",
            port: 49_152
        )
        var badCookie = valid
        badCookie[4] = 0
        var badLength = valid
        badLength[3] = 4

        #expect(
            FingerprintAuditLoopbackSTUNServer.response(
                for: Data(),
                remoteEndpoint: endpoint
            ) == nil
        )
        #expect(
            FingerprintAuditLoopbackSTUNServer.response(
                for: badCookie,
                remoteEndpoint: endpoint
            ) == nil
        )
        #expect(
            FingerprintAuditLoopbackSTUNServer.response(
                for: badLength,
                remoteEndpoint: endpoint
            ) == nil
        )
        #expect(
            FingerprintAuditLoopbackSTUNServer.response(
                for: valid,
                remoteEndpoint: nonLoopback
            ) == nil
        )
        #expect(
            FingerprintAuditLoopbackSTUNServer.response(
                for: Data(repeating: 0, count: 1_025),
                remoteEndpoint: endpoint
            ) == nil
        )
    }

    @Test
    func startsWithSelfTestExcludedFromBrowserEvidence() async throws {
        let server = try await FingerprintAuditLoopbackSTUNServer.start()
        defer { server.stop() }

        #expect(server.port.rawValue != 0)
        #expect(server.acceptedRequestCount == 0)
    }
}
