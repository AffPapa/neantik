import WebKit
import CoreFoundation

/// Shipping policy is an explicit signed capability. Debug's absent-key
/// default serves isolated tests only; a committed false flag stays false.
/// This switch does not itself prove working hardware capture.
enum WebKitMediaFeature {
    static let key = "NeAntikWebKitMediaPolicyEnabled"
    static func enabled(in info: [String: Any], development: Bool = false) -> Bool {
        guard let value = info[key] else { return development }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
    static var isEnabled: Bool {
        #if DEBUG
        let development = true
        #else
        let development = false
        #endif
        return enabled(in: Bundle.main.infoDictionary ?? [:], development: development)
    }
    static func visibleFields(_ input: [String: Any], enabled: Bool = isEnabled) -> [String: Any] {
        var fields = input
        if !enabled { fields.removeValue(forKey: "webKitMediaPolicy") }
        return fields
    }
}


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
                  secureOrigin: Bool, knownCaptureType: Bool, enabled: Bool = WebKitMediaFeature.isEnabled) -> WKPermissionDecision {
        guard enabled, self == .ask, owned, persistent, storeID == profileID,
              secureOrigin, knownCaptureType else { return .deny }
        return .prompt
    }
}

/// Apply the engine preference before creating any view. An unsupported or
/// unverifiable private selector must not silently start a protected profile.
enum WebKitPeerConnectionPolicy {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "WebKit не смог отключить WebRTC. Профиль не запущен; настройки и данные сохранены."
        }
    }

    /// Schema 6 guarantees every persisted profile explicitly carries its
    /// protection state. Missing/null/numeric values must not become false.
    static func hasExplicitProfilePolicies(in data: Data) -> Bool {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = document["profiles"] as? [[String: Any]] else { return false }
        return profiles.allSatisfy { profile in
            guard let value = profile["webKitBlockPeerConnections"] as? NSNumber else { return false }
            return CFGetTypeID(value) == CFBooleanGetTypeID()
        }
    }

    static func apply(blocked: Bool, preferences: NSObject) throws {
        guard blocked else { return }
        let setter = NSSelectorFromString("_setPeerConnectionEnabled:")
        let getter = NSSelectorFromString("_peerConnectionEnabled")
        guard preferences.responds(to: setter), preferences.responds(to: getter) else {
            throw Failure.unavailable
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let set = unsafeBitCast(preferences.method(for: setter), to: Setter.self)
        let get = unsafeBitCast(preferences.method(for: getter), to: Getter.self)
        set(preferences, setter, false)
        guard !get(preferences, getter) else { throw Failure.unavailable }
    }
}
