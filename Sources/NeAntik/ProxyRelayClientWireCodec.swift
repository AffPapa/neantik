import Darwin
import Foundation

enum ProxyRelayClientWireError: Error, Equatable {
    case malformed, unsupportedCommand, unsupportedAddress
}

/// RFC1928 local SOCKS5 framing only. An anonymous wire method is not consent:
/// the relay must prove its browser/session authority before using upstream
/// credentials. No DNS resolution, sockets or credential acceptance occurs.
enum ProxyRelayClientWireCodec {
    struct Greeting: Equatable {
        let consumed: Int
        let selectedMethod: UInt8
    }
    struct Connect: Equatable, CustomStringConvertible, CustomReflectable {
        let consumed: Int
        let destination: ProxyRelayDestination
        var description: String { "ProxyRelayClientConnect(<redacted>)" }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
    static let maximumFrameBytes = 263

    static func greeting(_ data: Data) throws -> Greeting? {
        let bytes = [UInt8](data.prefix(257))
        if let version = bytes.first, version != 5 { throw ProxyRelayClientWireError.malformed }
        guard bytes.count >= 2 else { return nil }
        let count = Int(bytes[1])
        guard count > 0 else { throw ProxyRelayClientWireError.malformed }
        guard bytes.count >= 2 + count else { return nil }
        return .init(consumed: 2 + count, selectedMethod: bytes[2..<(2 + count)].contains(0) ? 0 : 255)
    }
    static func connect(_ data: Data) throws -> Connect? {
        let bytes = [UInt8](data.prefix(maximumFrameBytes))
        if let version = bytes.first, version != 5 { throw ProxyRelayClientWireError.malformed }
        guard bytes.count >= 2 else { return nil }
        guard bytes[1] == 1 else { throw ProxyRelayClientWireError.unsupportedCommand }
        guard bytes.count >= 3 else { return nil }
        guard bytes[2] == 0 else { throw ProxyRelayClientWireError.malformed }
        guard bytes.count >= 4 else { return nil }
        let host: String, portOffset: Int
        switch bytes[3] {
        case 1:
            guard bytes.count >= 10 else { return nil }
            host = bytes[4..<8].map(String.init).joined(separator: "."); portOffset = 8
        case 3:
            guard bytes.count >= 5 else { return nil }
            let count = Int(bytes[4])
            guard count > 0 else { throw ProxyRelayClientWireError.malformed }
            guard bytes.count >= 7 + count else { return nil }
            guard let domain = String(bytes: bytes[5..<(5 + count)], encoding: .ascii) else { throw ProxyRelayClientWireError.malformed }
            host = domain; portOffset = 5 + count
        case 4:
            guard bytes.count >= 22 else { return nil }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let address = Array(bytes[4..<20])
            let converted = address.withUnsafeBytes { raw in inet_ntop(AF_INET6, raw.baseAddress, &output, socklen_t(output.count)) }
            guard converted != nil else { throw ProxyRelayClientWireError.malformed }
            host = String(cString: output); portOffset = 20
        default: throw ProxyRelayClientWireError.unsupportedAddress
        }
        let port = Int(bytes[portOffset]) * 256 + Int(bytes[portOffset + 1])
        return try .init(consumed: portOffset + 2, destination: .init(host: host, port: port))
    }
}
