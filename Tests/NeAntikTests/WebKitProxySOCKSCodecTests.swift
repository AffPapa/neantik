import Foundation
import Darwin
import Testing
@testable import NeAntik

enum WebKitProxyQualificationClosure {
    static func isConnectionTermination(_ error: Error) -> Bool {
        guard let error = error as? ProxyRelayTransportError else { return false }
        switch error {
        case .closed, .posixFailure(ECONNRESET): return true
        default: return false
        }
    }
}

/// Pure byte/model tests: no listeners, interfaces, views or Keychain.
struct WebKitProxySOCKSCodecTests {
    private func authentication(_ username: [UInt8] = Array("fixture".utf8),
                                _ password: [UInt8] = Array("only".utf8)) -> Data {
        Data([1, UInt8(username.count)] + username + [UInt8(password.count)] + password)
    }
    @Test func requiresPasswordMethodIncludingMixedOffer() throws {
        let mixed = Data([5, 3, 0, 2, 1])
        for count in 0..<mixed.count {
            #expect(try WebKitProxySOCKSCodec.greeting(Data(mixed.prefix(count))) == nil)
        }
        let parsed = try #require(try WebKitProxySOCKSCodec.greeting(mixed + Data([1, 1, 65])))
        #expect(parsed.consumed == mixed.count && parsed.acceptsPassword)
        #expect(try WebKitProxySOCKSCodec.greeting(Data([5, 1, 0]))?.acceptsPassword == false)
        #expect(try WebKitProxySOCKSCodec.greeting(Data([5, 1, 255]))?.acceptsPassword == false)
        #expect(WebKitProxySOCKSCodec.selectedPassword == Data([5, 2]))
        #expect(WebKitProxySOCKSCodec.noAcceptableMethod == Data([5, 255]))
        #expect(throws: ProxyRelayClientWireError.malformed) { try WebKitProxySOCKSCodec.greeting(Data([4])) }
        #expect(throws: ProxyRelayClientWireError.malformed) { try WebKitProxySOCKSCodec.greeting(Data([5, 0])) }
    }
    @Test func fragmentsAndCoalescedStagesPreserveDestinationAndPayload() throws {
        let auth = authentication()
        for count in 0..<auth.count {
            #expect(try WebKitProxySOCKSCodec.authentication(Data(auth.prefix(count))) == nil)
        }
        let target = try ProxyRelayDestination(host: "owned-fixture.invalid", port: 8443)
        let connect = try ProxyRelayWireCodec.socksConnect(target)
        let payload = Data([0, 255, 1, 5, 2, 0, 10, 13])
        var buffer = Data([5, 2, 0, 2]) + auth + connect + payload
        let greeting = try #require(try WebKitProxySOCKSCodec.greeting(buffer))
        buffer = Data(buffer.dropFirst(greeting.consumed))
        let parsed = try #require(try WebKitProxySOCKSCodec.authentication(buffer))
        #expect(parsed.authorization == Data("fixture:only".utf8))
        buffer = Data(buffer.dropFirst(parsed.consumed))
        let request = try #require(try ProxyRelayClientWireCodec.connect(buffer))
        #expect(request.destination == target)
        #expect(Data(buffer.dropFirst(request.consumed)) == payload)
    }
    @Test func boundedMaximumFramesAndRedactedProof() throws {
        let greeting = Data([5, 255] + Array(repeating: UInt8(2), count: 255))
        #expect(try WebKitProxySOCKSCodec.greeting(greeting)?.consumed == WebKitProxySOCKSCodec.maximumGreetingBytes)
        let auth = authentication(Array(repeating: 65, count: 255), Array(repeating: 66, count: 255))
        #expect(auth.count == WebKitProxySOCKSCodec.maximumAuthenticationBytes)
        let parsed = try #require(try WebKitProxySOCKSCodec.authentication(auth + Data(repeating: 67, count: 4096)))
        #expect(parsed.consumed == auth.count && parsed.authorization.count == 511)
        #expect(String(reflecting: parsed) == "WebKitSOCKSAuthentication(<redacted>)")
        #expect(Mirror(reflecting: parsed).children.isEmpty)
    }
    @Test func malformedAuthenticationAndAmbiguousUsernameAreRejected() {
        for data in [Data([0]), Data([1, 0]), Data([1, 1, 65, 0]), authentication(Array("a:b".utf8))] {
            #expect(throws: ProxyRelayClientWireError.malformed) { try WebKitProxySOCKSCodec.authentication(data) }
        }
        #expect(WebKitProxySOCKSCodec.authenticated == Data([1, 0]))
        #expect(WebKitProxySOCKSCodec.authenticationRefused == Data([1, 1]))
    }
    @Test func onlyTCPConnectAndActualBoundAddressReply() throws {
        for command: UInt8 in [2, 3] {
            #expect(throws: ProxyRelayClientWireError.unsupportedCommand) {
                try ProxyRelayClientWireCodec.connect(Data([5, command, 0, 1, 127, 0, 0, 1, 1, 1]))
            }
        }
        #expect(WebKitProxySOCKSCodec.commandRefused[1] == 7)
        for host in ["127.0.0.1", "::1"] {
            let bound = try ProxyRelayDestination(host: host, port: 12345)
            let reply = try WebKitProxySOCKSCodec.established(bound: bound)
            #expect(reply[0] == 5 && reply[1] == 0)
            var request = reply; request[1] = 1
            #expect(try ProxyRelayClientWireCodec.connect(request)?.destination == bound)
        }
    }
    @Test func unknownFrontendDoesNotSelectAnonymousOrHTTPFallback() throws {
        #expect(try WebKitProxySession.Frontend.requested(nil) == .httpCONNECT)
        #expect(try WebKitProxySession.Frontend.requested("socks5") == .socks5)
        for value in ["", "socks", "SOCKS5", "direct", "anonymous"] {
            #expect(throws: WebKitProxySession.Failure.scope) { try WebKitProxySession.Frontend.requested(value) }
        }
    }
    @Test func timeoutOrUnknownErrorIsNeverSuccessfulRevocation() {
        #expect(WebKitProxyQualificationClosure.isConnectionTermination(ProxyRelayTransportError.closed))
        #expect(WebKitProxyQualificationClosure.isConnectionTermination(ProxyRelayTransportError.posixFailure(ECONNRESET)))
        for error in [ProxyRelayTransportError.timeout, .unavailable, .tlsFailed, .dnsFailure(1), .posixFailure(EINVAL)] {
            #expect(!WebKitProxyQualificationClosure.isConnectionTermination(error))
        }
        #expect(!WebKitProxyQualificationClosure.isConnectionTermination(CancellationError()))
    }
}
