import CryptoKit
import Foundation

/// One explicit, time-bounded diagnostic. No network request occurs when this
/// value is constructed/decoded. Its nonces are ephemeral and never exported.
enum BrowserRouteProbe {
    enum Failure: Error, Equatable { case invalidPlan, invalidRequest, invalidReceipt, wrongPhase, expired }
    enum Component: String, Codable, Sendable { case http, https }
    struct Plan: Codable, Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        let httpEndpoint: URL
        let httpsEndpoint: URL
        let verificationKey: Data
        let httpNonce: String
        let httpsNonce: String
        let lifetimeSeconds: Int
        var description: String { "BrowserRouteProbePlan(<redacted>)" }
        var customMirror: Mirror { Mirror(self, children: [:]) }
        static func make(httpEndpoint: URL, httpsEndpoint: URL, verificationKey: Data, lifetimeSeconds: Int = 60) throws -> Self {
            func nonce() -> String {
                SymmetricKey(size: .bits256).withUnsafeBytes { bytes in bytes.map { String(format: "%02x", $0) }.joined() }
            }
            let plan = Self(httpEndpoint: httpEndpoint, httpsEndpoint: httpsEndpoint, verificationKey: verificationKey,
                            httpNonce: nonce(), httpsNonce: nonce(), lifetimeSeconds: lifetimeSeconds)
            try plan.validate(); return plan
        }
        func validate() throws {
            guard (10...120).contains(lifetimeSeconds), verificationKey.count == 32,
                  httpNonce != httpsNonce, [httpNonce, httpsNonce].allSatisfy(Self.validNonce)
            else { throw Failure.invalidPlan }
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: verificationKey)
            try Self.validateEndpoint(httpEndpoint, scheme: "http")
            try Self.validateEndpoint(httpsEndpoint, scheme: "https")
        }
        private static func validNonce(_ s: String) -> Bool {
            s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        private static func validateEndpoint(_ url: URL, scheme: String) throws {
            guard url.absoluteString.utf8.count <= 2048,
                  let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == scheme,
                  let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
                  c.query == nil, c.fragment == nil,
                  !c.percentEncodedPath.contains("%"), !c.path.contains(".."),
                  c.path.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }),
                  c.url?.absoluteString == url.absoluteString
            else { throw Failure.invalidPlan }
            _ = try ProxyRelayDestination(host: host, port: c.port ?? (scheme == "https" ? 443 : 80))
        }
        func endpoint(_ component: Component) -> URL { component == .http ? httpEndpoint : httpsEndpoint }
        func nonce(_ component: Component) -> String { component == .http ? httpNonce : httpsNonce }
        func destination(_ component: Component) throws -> ProxyRelayDestination {
            let url = endpoint(component)
            return try .init(host: url.host!, port: url.port ?? (component == .http ? 80 : 443))
        }
        /// Different from proxy configuration: changing diagnostics policy
        /// cannot silently change the route configuration's identity.
        var policySHA256: String {
            let fields = [httpEndpoint.absoluteString, httpsEndpoint.absoluteString, verificationKey.base64EncodedString(), String(lifetimeSeconds)]
            let data = try! JSONSerialization.data(withJSONObject: fields)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Receipt: Codable, Sendable {
        let schema: Int
        let component: Component
        let nonce: String
        let endpointSHA256: String
        let expiresAt: Int64
    }
    enum Status: String, Codable, Sendable { case notStarted, waitingHTTP, waitingHTTPS, complete, expired, cancelled }
    /// Deliberately contains no endpoint, nonce, ID, fingerprint, IP or TLS
    /// payload. This is point-in-time evidence, not a continuous route verdict.
    struct Snapshot: Codable, Equatable, Sendable {
        let status: Status
        let httpResponseAcknowledged: Bool
        let httpsResponseAcknowledged: Bool
        let hostnameDelegationObserved: Bool
        let dnsResolution: String
        let policySHA256: String
        var expiresAtUptimeNanoseconds: UInt64 = 0

        /// Owner and manager share the same boot's monotonic clock. Carry the
        /// deadline internally so IPC/Security waits cannot preserve a green
        /// result after expiry. This field is not a public MCP timestamp.
        func current(at uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Self {
            guard status != .cancelled, status != .expired,
                  expiresAtUptimeNanoseconds > 0, uptime >= expiresAtUptimeNanoseconds else { return self }
            return .init(status: .expired, httpResponseAcknowledged: httpResponseAcknowledged,
                         httpsResponseAcknowledged: httpsResponseAcknowledged,
                         hostnameDelegationObserved: hostnameDelegationObserved,
                         dnsResolution: dnsResolution, policySHA256: policySHA256,
                         expiresAtUptimeNanoseconds: expiresAtUptimeNanoseconds)
        }

        /// A closed scalar receipt, never arbitrary endpoint data. Historical
        /// ACKs may survive expiry/cancellation, but must not contradict phases.
        func validate(expectedPolicySHA256: String, uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
            guard policySHA256 == expectedPolicySHA256,
                  policySHA256.utf8.count == 64,
                  policySHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  uptime <= UInt64.max - 120_000_000_000,
                  expiresAtUptimeNanoseconds <= uptime + 120_000_000_000,
                  dnsResolution == "notObserved",
                  !httpsResponseAcknowledged || httpResponseAcknowledged else { throw Failure.invalidReceipt }
            switch status {
            case .notStarted:
                guard !httpResponseAcknowledged, !httpsResponseAcknowledged, !hostnameDelegationObserved else { throw Failure.invalidReceipt }
            case .waitingHTTP:
                guard expiresAtUptimeNanoseconds > 0, !httpResponseAcknowledged, !httpsResponseAcknowledged else { throw Failure.invalidReceipt }
            case .waitingHTTPS:
                guard expiresAtUptimeNanoseconds > 0, httpResponseAcknowledged, !httpsResponseAcknowledged else { throw Failure.invalidReceipt }
            case .complete:
                guard expiresAtUptimeNanoseconds > 0, httpResponseAcknowledged, httpsResponseAcknowledged else { throw Failure.invalidReceipt }
            case .expired, .cancelled: break
            }
        }
    }
    struct Response: Sendable {
        let bytes: Data
    }

    /// Own fixed virtual HTTP resource reached *through admitted SOCKS*.
    /// A direct HTTP request to the SOCKS listener can never enter this path.
    final class Session: @unchecked Sendable {
        private let plan: Plan
        private let lock = NSLock()
        private let uptime: @Sendable () -> UInt64
        private let wallSeconds: @Sendable () -> Int64
        private var deadline: UInt64?
        private var port: UInt16?
        private var status: Status = .notStarted
        private var httpForwarded = false
        private var httpsTunnel = false
        private var httpAcknowledged = false
        private var httpsAcknowledged = false
        private var delegated = false
        static let entryPath = "/__neantik_route/start"
        static let callbackPath = "/__neantik_route/ack"
        init(plan: Plan, uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
             wallSeconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws {
            try plan.validate(); self.plan = plan; self.uptime = uptime; self.wallSeconds = wallSeconds
        }
        /// Owner activation, after durable browser lease commit. Before this
        /// phase neither a local page nor a receipt can start the diagnostic.
        func activate(port: UInt16) throws {
            lock.lock(); defer { lock.unlock() }
            guard deadline == nil, self.port == nil, port > 0, status == .notStarted else { throw Failure.wrongPhase }
            let now = uptime(), span = UInt64(plan.lifetimeSeconds) * 1_000_000_000
            guard now <= UInt64.max - span else { throw Failure.invalidPlan }
            self.port = port; deadline = now + span
        }
        func cancel() { lock.lock(); defer { lock.unlock() }; status = .cancelled }
        private func checkLive() throws {
            guard let deadline, let port, port > 0, status != .cancelled else { throw Failure.wrongPhase }
            guard uptime() < deadline else { status = .expired; throw Failure.expired }
        }
        func isVirtual(_ destination: ProxyRelayDestination) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return destination.host == "127.0.0.1" && destination.port == port
        }
        func matchesHTTP(_ destination: ProxyRelayDestination) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return (try? checkLive()) != nil && status == .waitingHTTP && (try? plan.destination(.http)) == destination
        }
        func observeTunnel(_ destination: ProxyRelayDestination) {
            lock.lock(); defer { lock.unlock() }
            guard (try? checkLive()) != nil, status == .waitingHTTPS,
                  (try? plan.destination(.https)) == destination else { return }
            httpsTunnel = true
            delegated = delegated || Self.isHostname(destination.host)
        }
        /// Called only after the exact bounded HTTP request was successfully
        /// written to the configured upstream tunnel. A CONNECT or byte count
        /// alone cannot satisfy the HTTP receipt's forwarding condition.
        func observeForwardedHTTP(_ data: Data, destination: ProxyRelayDestination) {
            lock.lock(); defer { lock.unlock() }
            guard (try? checkLive()) != nil, status == .waitingHTTP,
                  (try? plan.destination(.http)) == destination,
                  let request = try? HTTP.parse(data),
                  request.target == remoteTarget(.http),
                  HTTP.authority(request.authority, matches: destination) else { return }
            httpForwarded = true
            delegated = delegated || Self.isHostname(destination.host)
        }
        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            if deadline != nil, status != .cancelled { _ = try? checkLive() }
            return .init(status: status, httpResponseAcknowledged: httpAcknowledged,
                         httpsResponseAcknowledged: httpsAcknowledged, hostnameDelegationObserved: delegated,
                         dnsResolution: "notObserved", policySHA256: plan.policySHA256,
                         expiresAtUptimeNanoseconds: deadline ?? 0)
        }
        func respond(to data: Data) throws -> Response {
            guard let request = try HTTP.parse(data) else { throw Failure.invalidRequest }
            let target = request.target
            lock.lock(); defer { lock.unlock() }; try checkLive()
            guard HTTP.authority(request.authority, matches: try .init(host: "127.0.0.1", port: Int(port!))) else { throw Failure.invalidRequest }
            if target == Self.entryPath {
                guard status == .notStarted else { throw Failure.wrongPhase }
                status = .waitingHTTP; return redirect(.http)
            }
            guard target.hasPrefix(Self.callbackPath + "?"),
                  let c = URLComponents(string: "http://127.0.0.1" + target),
                  c.path == Self.callbackPath, c.fragment == nil,
                  let items = c.queryItems, items.count == 2,
                  Set(items.map(\.name)) == ["r", "s"],
                  let payloadText = items.first(where: { $0.name == "r" })?.value,
                  let signatureText = items.first(where: { $0.name == "s" })?.value,
                  let payload = Self.decodeBase64URL(payloadText, maximum: 1024),
                  let signature = Self.decodeBase64URL(signatureText, maximum: 64), signature.count == 64
            else { throw Failure.invalidReceipt }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: plan.verificationKey)
            guard key.isValidSignature(signature, for: payload) else { throw Failure.invalidReceipt }
            try ImportJSONShape.validate(payload)
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  Set(object.keys) == ["schema", "component", "nonce", "endpointSHA256", "expiresAt"]
            else { throw Failure.invalidReceipt }
            let receipt = try JSONDecoder().decode(Receipt.self, from: payload)
            let component: Component
            switch status {
            case .waitingHTTP: guard httpForwarded else { throw Failure.wrongPhase }; component = .http
            case .waitingHTTPS: guard httpsTunnel else { throw Failure.wrongPhase }; component = .https
            default: throw Failure.wrongPhase
            }
            let endpointHash = SHA256.hash(data: Data(plan.endpoint(component).absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            let now = wallSeconds()
            guard receipt.schema == 1, receipt.component == component, receipt.nonce == plan.nonce(component),
                  receipt.endpointSHA256 == endpointHash, now >= 0, now <= Int64.max - Int64(plan.lifetimeSeconds),
                  receipt.expiresAt >= now, receipt.expiresAt <= now + Int64(plan.lifetimeSeconds)
            else { throw Failure.invalidReceipt }
            try checkLive() // signature/decoding/wall-clock work must not cross the monotonic commit deadline
            if component == .http { httpAcknowledged = true; status = .waitingHTTPS; return redirect(.https) }
            httpsAcknowledged = true; status = .complete
            return .init(bytes: HTTP.response(status: "200 OK", body: "<!doctype html><meta charset=utf-8><title>NeAntik: проверка маршрута</title><h1>Ответы HTTP и HTTPS получены браузером</h1><p>Проверка относится к этому запуску. DNS и постоянная защита отдельно не измерялись.</p>"))
        }
        private func remoteTarget(_ component: Component) -> String {
            var c = URLComponents(url: plan.endpoint(component), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "nonce", value: plan.nonce(component)),
                            .init(name: "callback", value: "http://127.0.0.1:\(port!)/" + String(Self.callbackPath.dropFirst()))]
            return (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath) + "?" + c.percentEncodedQuery!
        }
        private func redirect(_ component: Component) -> Response {
            let url = plan.endpoint(component)
            let origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let authority = origin.host!.contains(":") ? "[\(origin.host!)]" : origin.host!
            let location = "\(origin.scheme!)://\(authority)" + (origin.port.map { ":\($0)" } ?? "") + remoteTarget(component)
            return .init(bytes: HTTP.response(status: "303 See Other", location: location, body: ""))
        }
        private static func isHostname(_ host: String) -> Bool {
            !host.contains(":") && host.contains(where: { $0.isLetter })
        }
        private static func decodeBase64URL(_ text: String, maximum: Int) -> Data? {
            guard !text.isEmpty, text.utf8.count <= maximum * 2,
                  text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.count % 4) % 4)
            guard let data = Data(base64Encoded: padded), data.count <= maximum,
                  data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == text else { return nil }
            return data
        }
    }
    enum HTTP {
        static let maximumBytes = 4096
        struct Request { let target: String; let authority: String }
        static func target(_ data: Data) throws -> String? { try parse(data)?.target }
        static func authority(_ value: String, matches destination: ProxyRelayDestination) -> Bool {
            guard !value.isEmpty, let c = URLComponents(string: "http://" + value),
                  c.user == nil, c.password == nil, c.path.isEmpty, c.query == nil, c.fragment == nil,
                  c.host?.lowercased() == destination.host.lowercased(), (c.port ?? 80) == Int(destination.port) else { return false }
            return true
        }
        static func parse(_ data: Data) throws -> Request? {
            guard data.count <= maximumBytes else { throw Failure.invalidRequest }
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            guard end.upperBound == data.endIndex, let text = String(data: data, encoding: .ascii) else { throw Failure.invalidRequest }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", first[1].first == "/",
                  !first[1].hasPrefix("//"), first[1].utf8.allSatisfy({ $0 >= 33 && $0 < 127 }) else { throw Failure.invalidRequest }
            var names = Set<String>(), host: String?
            for line in lines.dropFirst().dropLast(2) {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw Failure.invalidRequest }
                let name = line[..<colon].lowercased()
                guard name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }), names.insert(name).inserted,
                      name != "content-length", name != "transfer-encoding",
                      line.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) })
                else { throw Failure.invalidRequest }
                if name == "host" { host = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
            }
            guard let host, !host.isEmpty else { throw Failure.invalidRequest }
            return .init(target: String(first[1]), authority: host)
        }
        static func response(status: String, location: String? = nil, body: String) -> Data {
            let b = Data(body.utf8)
            let headers = "HTTP/1.1 \(status)\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(b.count)\r\n" + (location.map { "Location: \($0)\r\n" } ?? "") + "\r\n"
            return Data(headers.utf8) + b
        }
    }
}
