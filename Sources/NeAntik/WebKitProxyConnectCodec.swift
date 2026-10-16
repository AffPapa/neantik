#if DEBUG
import Foundation

/// Qualification-only HTTP CONNECT frontend. It parses no browsing payload,
/// performs no DNS, and never logs or reflects the local bearer credential.
enum WebKitProxyConnectCodec {
    enum Failure: Error { case malformed, limit }
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
        guard let text = String(data: header, encoding: .ascii) else { throw Failure.malformed }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.allSatisfy({ $0.utf8.allSatisfy { (32...126).contains($0) || $0 == 9 } }),
              let first = lines.first else { throw Failure.malformed }
        let parts = first.components(separatedBy: " ")
        guard parts.count == 3, parts[0] == "CONNECT", parts[2] == "HTTP/1.1" else { throw Failure.malformed }
        let destination = try authority(parts[1])
        var host: String?, authorization: Data?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw Failure.malformed }
            let name = String(line[..<colon])
            let tokens = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            guard name.allSatisfy({ tokens.contains($0) }) else { throw Failure.malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "host":
                guard host == nil else { throw Failure.malformed }
                host = value
            case "proxy-authorization":
                guard authorization == nil, value.count <= 256 else { throw Failure.malformed }
                let fields = value.components(separatedBy: " ")
                guard fields.count == 2, fields[0].lowercased() == "basic",
                      let decoded = Data(base64Encoded: fields[1]), !decoded.isEmpty,
                      decoded.base64EncodedString() == fields[1] else { throw Failure.malformed }
                authorization = decoded
            // CONNECT has no request body here. Reject ambiguous framing and
            // origin credentials rather than forwarding them to an upstream.
            case "transfer-encoding", "content-length", "authorization", "expect": throw Failure.malformed
            default: break
            }
        }
        guard let host, try authority(host) == destination else { throw Failure.malformed }
        return Request(consumed: consumed, destination: destination, authorization: authorization)
    }

    private static func authority(_ text: String) throws -> ProxyRelayDestination {
        guard let separator = text.lastIndex(of: ":"),
              let port = Int(text[text.index(after: separator)...]),
              String(port) == text[text.index(after: separator)...] else { throw Failure.malformed }
        let host = String(text[..<separator])
        guard !host.contains(":" ) || (host.hasPrefix("[") && host.hasSuffix("]")) else { throw Failure.malformed }
        return try ProxyRelayDestination(host: host, port: port)
    }
}
#endif
