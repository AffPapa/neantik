import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayClientWireCodecTests {
    @Test func greetingsDoNotAcceptLocalCredentialsOrConsumePipelinedBytes() throws {
        let frame = Data([5, 2, 2, 0])
        for count in 0..<frame.count { #expect(try ProxyRelayClientWireCodec.greeting(Data(frame.prefix(count))) == nil) }
        #expect(try ProxyRelayClientWireCodec.greeting(frame + Data([5,1,0,1])) == .init(consumed: 4, selectedMethod: 0))
        #expect(try ProxyRelayClientWireCodec.greeting(Data([5,1,2])) == .init(consumed: 3, selectedMethod: 255))
        #expect(try ProxyRelayClientWireCodec.greeting(Data([5,255] + Array(repeating: 2, count: 255))) == .init(consumed: 257, selectedMethod: 255))
        #expect(throws: ProxyRelayClientWireError.malformed) { try ProxyRelayClientWireCodec.greeting(Data([4,1,0])) }
        #expect(throws: ProxyRelayClientWireError.malformed) { try ProxyRelayClientWireCodec.greeting(Data([5,0])) }
    }
    @Test func destinationRequestsHaveKnownIndependentVectorsAndEveryPrefixIsIncomplete() throws {
        let domain = Array("owned.example.test".utf8)
        let vectors: [(Data, String)] = [
            (Data([5,1,0,3,UInt8(domain.count)] + domain + [1,187]), "owned.example.test"),
            (Data([5,1,0,1,127,0,0,1,1,187]), "127.0.0.1"),
            (Data([5,1,0,4] + Array(repeating: 0, count: 15) + [1,1,187]), "::1")
        ]
        for (frame, host) in vectors {
            for count in 0..<frame.count { #expect(try ProxyRelayClientWireCodec.connect(Data(frame.prefix(count))) == nil) }
            let parsed = try #require(try ProxyRelayClientWireCodec.connect(frame + Data(repeating: 65, count: 1024 * 1024)))
            #expect(parsed.consumed == frame.count && parsed.destination.host == host && parsed.destination.port == 443)
            #expect(!String(describing: parsed).contains(host)); #expect(Mirror(reflecting: parsed).children.isEmpty)
        }
    }
    @Test(arguments: [Data([5,2,0,1]), Data([5,3,0,1])])
    func bindAndUDPAssociateRemainUnsupported(frame: Data) throws {
        #expect(throws: ProxyRelayClientWireError.unsupportedCommand) { try ProxyRelayClientWireCodec.connect(frame) }
    }
    @Test func malformedFieldsAndUnsafeDestinationsCannotProduceConnect() throws {
        let malformed = [Data([4,1,0,1]), Data([5,1,1,1]), Data([5,1,0,3,0])]
        for data in malformed { #expect(throws: ProxyRelayClientWireError.malformed) { try ProxyRelayClientWireCodec.connect(data) } }
        #expect(throws: ProxyRelayClientWireError.unsupportedAddress) { try ProxyRelayClientWireCodec.connect(Data([5,1,0,2])) }
        for host in ["bad/name", "bad\r\nHost:x", "@host", "x..test"] {
            let bytes = Array(host.utf8)
            #expect(throws: ProxyRelayWireError.invalidDestination) { try ProxyRelayClientWireCodec.connect(Data([5,1,0,3,UInt8(bytes.count)] + bytes + [1,187])) }
        }
        #expect(throws: ProxyRelayWireError.invalidDestination) { try ProxyRelayClientWireCodec.connect(Data([5,1,0,1,127,0,0,1,0,0])) }
        #expect(throws: ProxyRelayClientWireError.malformed) { try ProxyRelayClientWireCodec.connect(Data([5,1,0,3,1,255,1,187])) }
    }
}
