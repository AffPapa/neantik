import Foundation

/// Bounded HTTP CONNECT frontend. It parses no browsing payload,
/// performs no DNS, and never logs or reflects the local bearer credential.
enum WebKitProxyConnectCodec {
    enum Failure: Error, Equatable {
        case malformed(RejectStage)
        case limit
    }
    enum RejectStage: String, CaseIterable {
        case headerEncoding
        case requestLine
        case requestTargetSeparator
        case requestTargetPort
        case requestTargetHost
        case headerSyntax
        case headerPolicy
        case hostAuthority
    }
    enum QAMethodClass: Equatable { case connect, http, other }

    /// Classify only the first bounded method token for private QA counters.
    /// Never retain a URL, header, credential or request body.
    static func qaMethodClass(_ data: Data) -> QAMethodClass? {
        let prefix = Array(data.prefix(16))
        guard let separator = prefix.firstIndex(of: 0x20) else {
            return prefix.count == 16 ? .other : nil
        }
        let method = Array(prefix[..<separator])
        if method == Array("CONNECT".utf8) { return .connect }
        let httpMethods = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE"]
        return httpMethods.contains { method == Array($0.utf8) } ? .http : .other
    }
    struct Request: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let consumed: Int
        let destination: ProxyRelayDestination
        let authorization: Data?
        var description: String { "WebKitProxyRequest(<redacted>)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    static let maximumHeaderBytes = 8192
    static let authenticationRequired = Data((
        "HTTP/1.1 407 Proxy Authentication Required\r\n" +
        "Proxy-Authenticate: Basic realm=\"NeAntik session\"\r\n" +
        "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8)
    static let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    static func request(_ data: Data) throws -> Request? {
        guard let end = data.prefix(maximumHeaderBytes).range(of: Data([13, 10, 13, 10])) else {
            guard data.count < maximumHeaderBytes else { throw Failure.limit }
            return nil
        }
        let consumed = data.distance(from: data.startIndex, to: end.upperBound)
        let header = data.prefix(consumed - 4)
        // Ban bare CR/LF, controls and non-ASCII before any interpretation.
        guard let text = String(data: header, encoding: .ascii) else { throw Failure.malformed(.headerEncoding) }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.allSatisfy({ $0.utf8.allSatisfy { (32...126).contains($0) || $0 == 9 } }),
              let first = lines.first else { throw Failure.malformed(.headerSyntax) }
        let parts = first.components(separatedBy: " ")
        guard parts.count == 3, parts[0] == "CONNECT", parts[2] == "HTTP/1.1" else { throw Failure.malformed(.requestLine) }
        let destination = try authority(parts[1])
        var host: String?, authorization: Data?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw Failure.malformed(.headerSyntax) }
            let name = String(line[..<colon])
            let tokens = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            guard name.allSatisfy({ tokens.contains($0) }) else { throw Failure.malformed(.headerSyntax) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "host":
                guard host == nil else { throw Failure.malformed(.hostAuthority) }
                host = value
            case "proxy-authorization":
                guard authorization == nil, value.count <= 256 else { throw Failure.malformed(.headerPolicy) }
                let fields = value.components(separatedBy: " ")
                guard fields.count == 2, fields[0].lowercased() == "basic",
                      let decoded = Data(base64Encoded: fields[1]), !decoded.isEmpty,
                      decoded.base64EncodedString() == fields[1] else { throw Failure.malformed(.headerPolicy) }
                authorization = decoded
            // CONNECT has no request body here. Reject ambiguous framing and
            // origin credentials rather than forwarding them to an upstream.
            case "transfer-encoding", "content-length", "authorization", "expect": throw Failure.malformed(.headerPolicy)
            default: break
            }
        }
        guard let host else { throw Failure.malformed(.hostAuthority) }
        guard hostHeaderMatches(host, destination: destination) else {
            throw Failure.malformed(.hostAuthority)
        }
        return Request(consumed: consumed, destination: destination, authorization: authorization)
    }

    /// Host's port is optional by HTTP syntax. For CONNECT, the authority-form
    /// request target is authoritative and always contains the tunnel port.
    private static func hostHeaderMatches(_ value: String,
                                          destination: ProxyRelayDestination) -> Bool {
        let host: String
        let port: Int?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            host = String(value[...close])
            let suffix = value[value.index(after: close)...]
            if suffix.isEmpty {
                port = nil
            } else {
                guard suffix.first == ":" else { return false }
                let portText = String(suffix.dropFirst())
                guard let parsed = Int(portText), String(parsed) == portText,
                      (1...65_535).contains(parsed) else { return false }
                port = parsed
            }
        } else {
            let colons = value.indices.filter { value[$0] == ":" }
            if colons.isEmpty {
                host = value
                port = nil
            } else {
                guard colons.count == 1, let separator = colons.first else { return false }
                host = String(value[..<separator])
                let portText = String(value[value.index(after: separator)...])
                guard let parsed = Int(portText), String(parsed) == portText,
                      (1...65_535).contains(parsed) else { return false }
                port = parsed
            }
        }
        guard port == nil || port == Int(destination.port),
              let parsed = try? ProxyRelayDestination(host: host, port: Int(destination.port)) else {
            return false
        }
        let left = parsed.host.hasSuffix(".") ? String(parsed.host.dropLast()) : parsed.host
        let right = destination.host.hasSuffix(".") ? String(destination.host.dropLast()) : destination.host
        return left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static func authority(_ text: String) throws -> ProxyRelayDestination {
        guard let separator = text.lastIndex(of: ":") else { throw Failure.malformed(.requestTargetSeparator) }
        let portText = String(text[text.index(after: separator)...])
        guard let port = Int(portText), String(port) == portText,
              (1...65_535).contains(port) else { throw Failure.malformed(.requestTargetPort) }
        let host = String(text[..<separator])
        guard !host.contains(":" ) || (host.hasPrefix("[") && host.hasSuffix("]")) else { throw Failure.malformed(.requestTargetHost) }
        do { return try ProxyRelayDestination(host: host, port: port) }
        catch { throw Failure.malformed(.requestTargetHost) }
    }
}
