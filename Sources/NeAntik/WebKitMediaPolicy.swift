import WebKit

/// Profile policy never grants hardware access. WebKit and macOS own prompts;
/// denying media capture is independent of WebRTC/DataChannel network routing.
enum WebKitMediaPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, deny
    var id: String { rawValue }
    var title: String { self == .ask ? "Спрашивать у сайта" : "Запретить" }

    static func permitsOrigin(scheme: String, host: String) -> Bool {
        scheme.lowercased() == "https" || (scheme.lowercased() == "http" &&
            ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()))
    }

    func decision(owned: Bool, persistent: Bool, storeID: UUID?, profileID: UUID,
                  secureOrigin: Bool, knownCaptureType: Bool) -> WKPermissionDecision {
        guard self == .ask, owned, persistent, storeID == profileID,
              secureOrigin, knownCaptureType else { return .deny }
        return .prompt
    }
}
