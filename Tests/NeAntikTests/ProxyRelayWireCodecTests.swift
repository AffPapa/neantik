import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayWireCodecTests {
    private var credentials: ProxyRelayCredentials { get throws { try .init(username: "own-user", password: "own-password") } }

    @Test func socksNegotiationRequiresOfferedMethodAndRedactsCredentials() throws {
        let secret = try credentials
        #expect(ProxyRelayWireCodec.socksGreeting(credentials: nil) == Data([5, 1, 0]))
        #expect(ProxyRelayWireCodec.socksGreeting(credentials: secret) == Data([5, 1, 2]))
        #expect(try ProxyRelayWireCodec.socksSelectedMethod(Data([5]), credentials: secret) == nil)
        #expect(try ProxyRelayWireCodec.socksSelectedMethod(Data([5, 2]), credentials: secret) == .usernamePassword)
        #expect(throws: ProxyRelayWireError.unsupportedMethod) { try ProxyRelayWireCodec.socksSelectedMethod(Data([5, 0]), credentials: secret) }
        #expect(throws: ProxyRelayWireError.unsupportedMethod) { try ProxyRelayWireCodec.socksSelectedMethod(Data([5, 2]), credentials: nil) }
        #expect(throws: ProxyRelayWireError.unsupportedMethod) { try ProxyRelayWireCodec.socksSelectedMethod(Data([5, 255]), credentials: nil) }
        #expect(throws: ProxyRelayWireError.malformed) { try ProxyRelayWireCodec.socksSelectedMethod(Data([4, 0]), credentials: nil) }
        #expect(!String(describing: secret).contains("own-password"))
        #expect(!String(reflecting: secret).contains("own-user"))
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }
    @Test func socksCredentialsUseOctetLengthsAndRejectOversizedUTF8() throws {
        let secret = try ProxyRelayCredentials(username: "é", password: "字")
        #expect(try ProxyRelayWireCodec.socksAuthentication(secret) == Data([1, 2, 0xc3, 0xa9, 3, 0xe5, 0xad, 0x97]))
        let oversized = try ProxyRelayCredentials(username: String(repeating: "é", count: 128), password: "own")
        #expect(throws: ProxyRelayWireError.credentialsLength) { try ProxyRelayWireCodec.socksAuthentication(oversized) }
        #expect(try ProxyRelayWireCodec.socksAuthenticationAccepted(Data([1])) == nil)
        #expect(try ProxyRelayWireCodec.socksAuthenticationAccepted(Data([1, 0])) == true)
        #expect(throws: ProxyRelayWireError.authenticationRejected) { try ProxyRelayWireCodec.socksAuthenticationAccepted(Data([1, 1])) }
        #expect(throws: ProxyRelayWireError.malformed) { try ProxyRelayWireCodec.socksAuthenticationAccepted(Data([5, 0])) }
        let emptyPassword = try ProxyRelayCredentials(username: "own", password: "")
        #expect(throws: ProxyRelayWireError.credentialsLength) { try ProxyRelayWireCodec.socksAuthentication(emptyPassword) }
        #expect(try ProxyRelayWireCodec.httpConnect(.init(host: "example.test", port: 443), credentials: emptyPassword).count > 0)
    }
    @Test func socksRemoteDNSAndLiteralsHaveIndependentKnownWireVectors() throws {
        let domain = try ProxyRelayDestination(host: "example.test", port: 443)
        #expect(try ProxyRelayWireCodec.socksConnect(domain) == Data([5, 1, 0, 3, 12] + Array("example.test".utf8) + [1, 187]))
        #expect(try ProxyRelayWireCodec.socksConnect(.init(host: "127.0.0.1", port: 80)) == Data([5, 1, 0, 1, 127, 0, 0, 1, 0, 80]))
        let ipv6 = try ProxyRelayDestination(host: "[::1]", port: 65535)
        #expect(ipv6.authority == "[::1]:65535")
        #expect(try ProxyRelayWireCodec.socksConnect(ipv6) == Data([5, 1, 0, 4] + Array(repeating: UInt8(0), count: 15) + [1, 255, 255]))
        #expect(!String(reflecting: ipv6).contains("::1"))
        #expect(Mirror(reflecting: ipv6).children.isEmpty)
        #expect(try ProxyRelayDestination(host: "example.test.", port: 443).authority == "example.test.:443")
    }
    @Test(arguments: ["[example.test]", "::1.", "a..test", "example.test\r\nInjected: x", "user@example.test", "example.test/path", "[::1", " "])
    func badDestinationsNeverProduceARequest(host: String) throws {
        #expect(throws: ProxyRelayWireError.invalidDestination) { try ProxyRelayDestination(host: host, port: 443) }
    }
    @Test func socksReplySplitsAndCoalescedTunnelBytesRemainDistinct() throws {
        let frames = [Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]), Data([5, 0, 0, 3, 3, 97, 98, 99, 0, 80]), Data([5, 0, 0, 4] + Array(repeating: UInt8(0), count: 16) + [0, 80])]
        for frame in frames {
            for end in 0..<frame.count { #expect(try ProxyRelayWireCodec.socksConnectReplyLength(Data(frame.prefix(end))) == nil) }
            #expect(try ProxyRelayWireCodec.socksConnectReplyLength(frame + Data([0x16, 3, 1])) == frame.count)
        }
        #expect(throws: ProxyRelayWireError.tunnelRejected(5)) { try ProxyRelayWireCodec.socksConnectReplyLength(Data([5, 5, 0, 1])) }
        for data in [Data([4, 0, 0, 1]), Data([5, 0, 1, 1]), Data([5, 0, 0, 2]), Data([5, 0, 0, 3, 0])] {
            #expect(throws: ProxyRelayWireError.malformed) { try ProxyRelayWireCodec.socksConnectReplyLength(data) }
        }
    }
    @Test func httpCONNECTIsBoundedAndTunnelFramingIgnoresCLTEAfterSuccess() throws {
        let request = try ProxyRelayWireCodec.httpConnect(.init(host: "example.test", port: 443), credentials: credentials)
        #expect(String(decoding: request, as: UTF8.self) == "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\nProxy-Authorization: Basic b3duLXVzZXI6b3duLXBhc3N3b3Jk\r\n\r\n")
        let header = Data("HTTP/1.1 200 Connected\r\nContent-Length: 999\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        for end in 0..<header.count { #expect(try ProxyRelayWireCodec.httpConnectReply(Data(header.prefix(end))) == .incomplete) }
        #expect(try ProxyRelayWireCodec.httpConnectReply(header + Data([0x16, 3, 1])) == .established(consumed: header.count))
        #expect(try ProxyRelayWireCodec.httpConnectReply(header + Data(repeating: 65, count: 1024 * 1024)) == .established(consumed: header.count))
        let info = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        #expect(try ProxyRelayWireCodec.httpConnectReply(info) == .informational(consumed: info.count))
        #expect(throws: ProxyRelayWireError.authenticationRejected) { try ProxyRelayWireCodec.httpConnectReply(Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8)) }
        #expect(throws: ProxyRelayWireError.tunnelRejected(502)) { try ProxyRelayWireCodec.httpConnectReply(Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8)) }
        #expect(throws: ProxyRelayWireError.headerLimit) { try ProxyRelayWireCodec.httpConnectReply(Data(repeating: 65, count: ProxyRelayWireCodec.maximumHeaderBytes)) }
    }
    @Test(arguments: ["HTTP/1.1 200 OK\nInjected: x\r\n\r\n", "HTTP/1.1 200 OK\r\n folded: x\r\n\r\n", "HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n", "HTTP/1.1 20 OK\r\n\r\n", "HTTP/1.1 200\r\n\r\n", "HTTP/2 200 OK\r\n\r\n", "HTTP/1.1 101 Switching Protocols\r\n\r\n", "HTTP/1.1 200 OK\r\nX: \u{0}\r\n\r\n"])
    func malformedHTTPRepliesNeverEstablishTunnel(text: String) throws {
        #expect(throws: ProxyRelayWireError.malformed) { try ProxyRelayWireCodec.httpConnectReply(Data(text.utf8)) }
    }
}
