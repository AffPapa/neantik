import Foundation

/// A discovery request contains only an address. It cannot accidentally carry
/// the profile's login/password, Keychain handle or health evidence.
struct ProxyProtocolEndpoint: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    let destination: ProxyRelayDestination
    init(host: String, port: Int) throws {
        destination = try .init(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    }
    var description: String { "ProxyProtocolEndpoint(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

enum ProxyProtocolFinding: Equatable, Sendable {
    case socks5, httpAuthenticationChallenge, unknown
    var kind: ProxyKind? {
        switch self { case .socks5: .socks5; case .httpAuthenticationChallenge: .http; case .unknown: nil }
    }
    var message: String {
        switch self {
        case .socks5: "Сервер ответил как SOCKS5. Авторизация и доступ к сайтам ещё не проверены."
        case .httpAuthenticationChallenge: "HTTP-прокси запросил авторизацию. Логин и пароль не отправлялись."
        case .unknown: "Не удалось однозначно определить тип. Уточни протокол и порт у провайдера. HTTPS и HTTP без подтверждённого ответа выбираются вручную."
        }
    }
}

/// A→B→A edits must not resurrect a response from the first A request.
/// This ephemeral state never becomes profile metadata or route evidence.
struct ProxyProtocolDiscovery: Sendable {
    struct Ticket: Equatable, Sendable {
        let id: UUID
        let endpoint: ProxyProtocolEndpoint
    }
    private(set) var ticket: Ticket?
    private(set) var finding: ProxyProtocolFinding?
    mutating func begin(endpoint: ProxyProtocolEndpoint) -> Ticket {
        let request = Ticket(id: UUID(), endpoint: endpoint)
        ticket = request; finding = nil; return request
    }
    @discardableResult
    mutating func finish(_ request: Ticket, finding: ProxyProtocolFinding,
                         currentEndpoint: ProxyProtocolEndpoint?) -> Bool {
        guard ticket == request, currentEndpoint == request.endpoint else { return false }
        self.finding = finding; return true
    }
    func applicableKind(at endpoint: ProxyProtocolEndpoint?) -> ProxyKind? {
        guard endpoint != nil, ticket?.endpoint == endpoint else { return nil }
        return finding?.kind
    }
    mutating func invalidate() { ticket = nil; finding = nil }
}

struct ProxyProtocolDetector: Sendable {
    enum Wire: Sendable {
        case socks5, http
        var request: Data {
            switch self {
            // Advertise methods, never perform RFC1929 authentication.
            case .socks5: Data([5, 2, 0, 2])
            // Reserved destination: no IP/GeoIP service and no real website.
            case .http: Data("CONNECT neantik-protocol-probe.invalid:443 HTTP/1.1\r\nHost: neantik-protocol-probe.invalid:443\r\nConnection: close\r\n\r\n".utf8)
            }
        }
    }
    enum Reply: Equatable { case incomplete, recognized(ProxyProtocolFinding), unrecognized }
    typealias Probe = @Sendable (ProxyProtocolEndpoint, Wire, TimeInterval) async throws -> Data
    static let maximumResponseBytes = 4096

    func detect(endpoint: ProxyProtocolEndpoint, timeout: TimeInterval = 4,
                probe: Probe = { endpoint, wire, timeout in
                    try await Self.probe(endpoint: endpoint, wire: wire, timeout: timeout)
                }) async throws -> ProxyProtocolFinding {
        guard timeout.isFinite, timeout >= 0.1, timeout <= 10 else { throw ProxyRelayTransportError.invalidLimit }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeout * 1e9)))
        for wire in [Wire.socks5, .http] {
            try Task.checkCancellation()
            let components = ContinuousClock.now.duration(to: deadline).components
            let remaining = Double(components.seconds) + Double(components.attoseconds) / 1e18
            guard remaining > 0 else { break }
            let budget = wire == .socks5 ? min(remaining, timeout / 2) : remaining
            do {
                let data = try await probe(endpoint, wire, budget)
                try Task.checkCancellation()
                if case .recognized(let finding) = Self.reply(data, wire: wire) { return finding }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw CancellationError() }
                // A refusal, TLS response or timeout is not a known protocol.
                // No raw native error, peer response or credential is exposed.
            }
        }
        return .unknown
    }

    static func reply(_ data: Data, wire: Wire) -> Reply {
        guard data.count <= maximumResponseBytes else { return .unrecognized }
        if wire == .socks5 {
            guard data.first == nil || data.first == 5 else { return .unrecognized }
            guard data.count >= 2 else { return .incomplete }
            guard data.count == 2, [UInt8(0), 2, 255].contains(data[data.startIndex + 1]) else { return .unrecognized }
            return .recognized(.socks5)
        }
        guard let end = data.range(of: Data([13,10,13,10])) else {
            return data.count < maximumResponseBytes ? .incomplete : .unrecognized
        }
        guard let text = String(data: data[..<end.lowerBound], encoding: .ascii) else { return .unrecognized }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.allSatisfy({ $0.utf8.allSatisfy { (32...126).contains($0) || $0 == 9 } }),
              let first = lines.first else { return .unrecognized }
        let status = first.split(separator: " ", omittingEmptySubsequences: false)
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(status[0]), status[1] == "407" else { return .unrecognized }
        let tokens = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var challenged = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].utf8.allSatisfy(tokens.contains) else { return .unrecognized }
            if line[..<colon].lowercased() == "proxy-authenticate" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard let scheme = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                      !scheme.isEmpty, scheme.utf8.allSatisfy(tokens.contains) else { return .unrecognized }
                challenged = true
            }
        }
        // HTTP200, including a generic web server's response to CONNECT, is
        // deliberately insufficient. Discovery is not a verified tunnel.
        return challenged ? .recognized(.httpAuthenticationChallenge) : .unrecognized
    }

    static func probe(endpoint: ProxyProtocolEndpoint, wire: Wire, timeout: TimeInterval) async throws -> Data {
        // .http selects plain TCP transport here; establish/auth is NEVER called.
        let transport = ProxyRelayUpstreamTransport(kind: .http, upstream: endpoint.destination)
        defer { transport.cancel() }
        return try await withTaskCancellationHandler {
            let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeout * 1e9)))
            func remaining() throws -> TimeInterval {
                let components = ContinuousClock.now.duration(to: deadline).components
                let value = Double(components.seconds) + Double(components.attoseconds) / 1e18
                guard value > 0 else { throw ProxyRelayTransportError.timeout }; return value
            }
            try Task.checkCancellation()
            try await transport.open(timeout: remaining())
            try await transport.send(wire.request, timeout: remaining())
            var data = Data()
            while reply(data, wire: wire) == .incomplete {
                let chunk = try await transport.receive(maximumBytes: min(512, maximumResponseBytes - data.count), timeout: remaining())
                if chunk.data.isEmpty { break }
                data.append(chunk.data)
            }
            try Task.checkCancellation()
            return data
        } onCancel: { transport.cancel() }
    }
}
