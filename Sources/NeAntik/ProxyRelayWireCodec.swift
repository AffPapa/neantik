import Darwin
import Foundation

/// Independent wire primitives for the development relay. These do not open
/// sockets or confer client ownership. A caller must authenticate its browser
/// client, enforce deadlines/cancellation and use TLS for an HTTPS upstream.
/// References: RFC 1928, RFC 1929, RFC 9110 §9.3.6, RFC 9112 §6.3.
enum ProxyRelayWireError: Error, Equatable {
    case invalidDestination, credentialsLength, credentialsInvalid
    case malformed, unsupportedMethod, authenticationRejected, tunnelRejected(Int), headerLimit
}

struct ProxyRelayDestination: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let host: String
    let port: UInt16

    init(host: String, port: Int) throws {
        guard (1...65535).contains(port), !host.isEmpty, host.utf8.count <= 253,
              host == host.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ProxyRelayWireError.invalidDestination
        }
        let normalized = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if host.hasPrefix("[") || host.hasSuffix("]") || normalized.contains(":") {
            var ipv6 = in6_addr()
            guard normalized.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else {
                throw ProxyRelayWireError.invalidDestination
            }
        }
        // DNS is sent to the upstream, never resolved by this codec. A rooted
        // DNS name is valid, but empty labels inside a name are not.
        let validatingHost = normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
        guard ProxyConfiguration(kind: .http, host: validatingHost, port: port, username: "").isValid else {
            throw ProxyRelayWireError.invalidDestination
        }
        self.host = normalized; self.port = UInt16(port)
    }
    var authority: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }
    var description: String { "ProxyRelayDestination(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Never Codable and deliberately opaque to logging/debug reflection. Only a
/// private helper bootstrap is allowed to provide these values in production.
struct ProxyRelayCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let username: String
    fileprivate let password: String
    init(username: String, password: String) throws {
        guard !username.isEmpty, !username.contains(":"), PersistedInlineText.isSafe(username),
              PersistedInlineText.isSafe(password) else { throw ProxyRelayWireError.credentialsInvalid }
        guard username.utf8.count <= ProxyConfiguration.maximumUsernameUTF8Bytes,
              password.utf8.count <= ProxyImportParser.maximumPasswordBytes else { throw ProxyRelayWireError.credentialsLength }
        self.username = username; self.password = password
    }
    var description: String { "ProxyRelayCredentials(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

enum ProxyRelayWireCodec {
    enum SOCKSMethod: Equatable { case none, usernamePassword }
    enum CONNECTReply: Equatable { case incomplete, informational(consumed: Int), established(consumed: Int) }
    static let maximumHeaderBytes = 16 * 1024

    static func socksGreeting(credentials: ProxyRelayCredentials?) -> Data {
        // With configured credentials offer only username/password. A server
        // cannot silently downgrade this request to an anonymous session.
        Data(credentials == nil ? [5, 1, 0] : [5, 1, 2])
    }
    static func socksSelectedMethod(_ data: Data, credentials: ProxyRelayCredentials?) throws -> SOCKSMethod? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data.prefix(2))
        guard bytes[0] == 5 else { throw ProxyRelayWireError.malformed }
        if bytes[1] == 0 && credentials == nil { return .none }
        if bytes[1] == 2 && credentials != nil { return .usernamePassword }
        throw ProxyRelayWireError.unsupportedMethod
    }
    static func socksAuthentication(_ credentials: ProxyRelayCredentials) throws -> Data {
        let user = Array(credentials.username.utf8), password = Array(credentials.password.utf8)
        guard (1...255).contains(user.count), (1...255).contains(password.count) else { throw ProxyRelayWireError.credentialsLength }
        return Data([1, UInt8(user.count)] + user + [UInt8(password.count)] + password)
    }
    static func socksAuthenticationAccepted(_ data: Data) throws -> Bool? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data.prefix(2))
        guard bytes[0] == 1 else { throw ProxyRelayWireError.malformed }
        guard bytes[1] == 0 else { throw ProxyRelayWireError.authenticationRejected }
        return true
    }
    static func socksConnect(_ destination: ProxyRelayDestination) throws -> Data {
        var ipv4 = in_addr(), ipv6 = in6_addr()
        let address: [UInt8]
        if destination.host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            address = [1] + withUnsafeBytes(of: &ipv4) { Array($0) }
        } else if destination.host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            address = [4] + withUnsafeBytes(of: &ipv6) { Array($0) }
        } else {
            let domain = Array(destination.host.utf8)
            guard (1...255).contains(domain.count) else { throw ProxyRelayWireError.invalidDestination }
            address = [3, UInt8(domain.count)] + domain
        }
        return Data([5, 1, 0] + address + [UInt8(destination.port >> 8), UInt8(destination.port & 255)])
    }
    /// Returns only frame length; any coalesced tunnel bytes remain untouched.
    static func socksConnectReplyLength(_ data: Data) throws -> Int? {
        guard data.count >= 4 else { return nil }
        let prefix = [UInt8](data.prefix(5))
        guard prefix[0] == 5, prefix[2] == 0 else { throw ProxyRelayWireError.malformed }
        guard prefix[1] == 0 else { throw ProxyRelayWireError.tunnelRejected(Int(prefix[1])) }
        let count: Int
        switch prefix[3] {
        case 1: count = 10
        case 4: count = 22
        case 3:
            guard prefix.count >= 5 else { return nil }
            guard prefix[4] > 0 else { throw ProxyRelayWireError.malformed }
            count = 7 + Int(prefix[4])
        default: throw ProxyRelayWireError.malformed
        }
        return data.count >= count ? count : nil
    }
    static func httpConnect(_ destination: ProxyRelayDestination, credentials: ProxyRelayCredentials?) throws -> Data {
        var text = "CONNECT \(destination.authority) HTTP/1.1\r\nHost: \(destination.authority)\r\n"
        if let credentials {
            let value = Data((credentials.username + ":" + credentials.password).utf8).base64EncodedString()
            text += "Proxy-Authorization: Basic \(value)\r\n"
        }
        text += "\r\n"
        guard text.utf8.count <= maximumHeaderBytes else { throw ProxyRelayWireError.headerLimit }
        return Data(text.utf8)
    }
    static func httpConnectReply(_ data: Data) throws -> CONNECTReply {
        let terminator = Data([13, 10, 13, 10])
        // Bound work even if a caller hands us a large coalesced tunnel chunk.
        guard let range = data.prefix(maximumHeaderBytes).range(of: terminator) else {
            guard data.count < maximumHeaderBytes else { throw ProxyRelayWireError.headerLimit }
            return .incomplete
        }
        let consumed = data.distance(from: data.startIndex, to: range.upperBound)
        guard consumed <= maximumHeaderBytes else { throw ProxyRelayWireError.headerLimit }
        let header = data.prefix(consumed - 4)
        guard header.allSatisfy({ $0 == 9 || $0 == 13 || $0 == 10 || $0 >= 32 && $0 != 127 }),
              let text = String(data: header, encoding: .isoLatin1) else { throw ProxyRelayWireError.malformed }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }) else { throw ProxyRelayWireError.malformed }
        let statusLine = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusLine.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(statusLine[0])),
              statusLine[1].utf8.count == 3, statusLine[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let status = Int(statusLine[1]), (100...599).contains(status) else { throw ProxyRelayWireError.malformed }
        let tokens = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].utf8.allSatisfy(tokens.contains),
                  !line.contains("\r"), !line.contains("\n") else { throw ProxyRelayWireError.malformed }
        }
        if (100...199).contains(status) {
            guard status != 101 else { throw ProxyRelayWireError.malformed }
            return .informational(consumed: consumed)
        }
        guard (200...299).contains(status) else {
            if status == 407 { throw ProxyRelayWireError.authenticationRejected }
            throw ProxyRelayWireError.tunnelRejected(status)
        }
        // A successful CONNECT becomes a tunnel immediately after headers.
        // RFC 9110/9112 require ignoring CL/TE here, not consuming a fake body.
        return .established(consumed: consumed)
    }
}
