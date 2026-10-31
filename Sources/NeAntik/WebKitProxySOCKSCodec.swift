#if DEBUG
import Foundation

/// RFC 1928/1929 parsing for the isolated WebKit experiment. Authentication
/// is mandatory; this does not reuse Chromium's anonymous, PID-bound listener.
/// Parsers consume one frame and leave coalesced tunnel bytes with the caller.
enum WebKitProxySOCKSCodec {
    struct Greeting {
        let consumed: Int
        let acceptsPassword: Bool
    }
    struct Authentication: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let consumed: Int
        let authorization: Data
        var description: String { "WebKitSOCKSAuthentication(<redacted>)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    static let maximumGreetingBytes = 257
    static let maximumAuthenticationBytes = 513
    static let selectedPassword = Data([5, 2])
    static let noAcceptableMethod = Data([5, 255])
    static let authenticated = Data([1, 0])
    static let authenticationRefused = Data([1, 1])
    static let commandRefused = Data([5, 7, 0, 1, 0, 0, 0, 0, 0, 0])

    static func established(bound: ProxyRelayDestination) throws -> Data {
        var reply = try ProxyRelayWireCodec.socksConnect(bound)
        reply[1] = 0 // BND address is the connected upstream socket, never requested target.
        return reply
    }

    static func greeting(_ data: Data) throws -> Greeting? {
        let bytes = [UInt8](data.prefix(maximumGreetingBytes))
        if let first = bytes.first, first != 5 { throw ProxyRelayClientWireError.malformed }
        guard bytes.count >= 2 else { return nil }
        let count = Int(bytes[1])
        guard count > 0 else { throw ProxyRelayClientWireError.malformed }
        guard bytes.count >= count + 2 else { return nil }
        return .init(consumed: count + 2, acceptsPassword: bytes[2..<(count + 2)].contains(2))
    }

    static func authentication(_ data: Data) throws -> Authentication? {
        let bytes = [UInt8](data.prefix(maximumAuthenticationBytes))
        if let first = bytes.first, first != 1 { throw ProxyRelayClientWireError.malformed }
        guard bytes.count >= 2 else { return nil }
        let usernameLength = Int(bytes[1])
        guard usernameLength > 0 else { throw ProxyRelayClientWireError.malformed }
        guard bytes.count >= usernameLength + 3 else { return nil }
        let passwordLength = Int(bytes[usernameLength + 2])
        guard passwordLength > 0 else { throw ProxyRelayClientWireError.malformed }
        let end = usernameLength + passwordLength + 3
        guard bytes.count >= end else { return nil }
        let username = bytes[2..<(usernameLength + 2)]
        // Session usernames never contain ':'. Refusing it here preserves the
        // existing constant-time username:password comparison without aliases.
        guard !username.contains(58) else { throw ProxyRelayClientWireError.malformed }
        var authorization = Data(username)
        authorization.append(58)
        authorization.append(contentsOf: bytes[(usernameLength + 3)..<end])
        return .init(consumed: end, authorization: authorization)
    }
}
#endif
