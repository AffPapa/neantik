import WebKit
import CoreFoundation
import Network
#if NEANTIK_WEBKIT_PROXY_QUALIFICATION
import Security
#endif

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
    static let productionRelayCapabilityKey = "NeAntikWebKitRelayOnlyEnabled"

    enum Failure: LocalizedError {
        case unavailable
        case relayUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "WebKit не смог отключить WebRTC. Профиль не запущен; настройки и данные сохранены."
            case .relayUnavailable:
                return "WebKit не принял обязательный прокси для WebRTC. Запуск профиля остановлен."
            }
        }
    }

    enum Mode: Equatable {
        case native, blocked, relayOnly
    }

    static func mode(blockRequested: Bool, usesOwnedProxy: Bool,
                     signedRelayQualification: Bool, relayRequested: Bool = false,
                     productionRelayAvailable: Bool = false) throws -> Mode {
        if relayRequested {
            guard !blockRequested, usesOwnedProxy, productionRelayAvailable else { throw Failure.relayUnavailable }
            return .relayOnly
        }
        if blockRequested { return .blocked }
        if signedRelayQualification {
            guard usesOwnedProxy else { throw Failure.relayUnavailable }
            return .relayOnly
        }
        return usesOwnedProxy ? .blocked : .native
    }

    static func validRelayPolicy(_ profile: BrowserProfile) -> Bool {
        !profile.webKitRelayOnly || (profile.engine == .webkit &&
            profile.webKitRuntimeGeneration == .isolatedV1 && profile.proxy != nil && !profile.webKitBlockPeerConnections)
    }

    static func productionRelayEnabled(
        in bundle: Bundle = .main, buildMode: WebKitProxyFeature.BuildMode = WebKitProxyFeature.buildMode
    ) -> Bool {
        guard buildMode == .production,
              bundle.bundleIdentifier == "app.neantik.desktop" ||
                bundle.bundleIdentifier == "app.neantik.desktop.webkit-host",
              let capability = bundle.object(forInfoDictionaryKey: productionRelayCapabilityKey) as? NSNumber,
              CFGetTypeID(capability) == CFBooleanGetTypeID() else { return false }
        return capability.boolValue
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

    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
    static func ownedRelayQualificationRequested(in bundle: Bundle) throws -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: "NeAntikOwnedWebKitRTCRelayQualification") else {
            return false
        }
        guard bundle.bundleIdentifier == "app.neantik.desktop.dev.webkit-host",
              let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID(),
              number.boolValue else {
            throw Failure.relayUnavailable
        }
        return true
    }
    #endif

    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_PRODUCTION
    static func installOwnedRelayProxy(proxy: nw_proxy_config_t, dataStore: NSObject, profileID: UUID) throws {
        guard !nw_proxy_config_get_failover_allowed(proxy) else { throw Failure.relayUnavailable }
        #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
        if let value = Bundle.main.object(forInfoDictionaryKey: "NeAntikQATURNSTrustScope") {
            guard Bundle.main.bundleIdentifier == "app.neantik.desktop.dev.webkit-host",
                  let scope = value as? [String: Any], Set(scope.keys) == ["profileID", "port", "anchorDER"],
                  let profile = scope["profileID"] as? String, let boundProfile = UUID(uuidString: profile),
                  let number = scope["port"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let port = UInt16(exactly: number.doubleValue), port >= 1024,
                  let der = scope["anchorDER"] as? Data, (1...4096).contains(der.count),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData),
                  SecCertificateCopyData(certificate) as Data == der else {
                throw Failure.relayUnavailable
            }
            if boundProfile == profileID {
                let selector = NSSelectorFromString("_neAntikRequireRTCProxy:turnsFixturePort:anchorDER:")
                guard dataStore.responds(to: selector) else { throw Failure.relayUnavailable }
                typealias ScopedInstaller = @convention(c) (AnyObject, Selector, AnyObject, UInt16, AnyObject) -> Bool
                let install = unsafeBitCast(dataStore.method(for: selector), to: ScopedInstaller.self)
                guard install(dataStore, selector, proxy as AnyObject, port, der as NSData) else {
                    throw Failure.relayUnavailable
                }
                return
            }
        }
        #endif
        let installProxy = NSSelectorFromString("_neAntikRequireRTCProxy:")
        guard dataStore.responds(to: installProxy) else {
            throw Failure.relayUnavailable
        }

        typealias ProxyInstaller = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let install = unsafeBitCast(dataStore.method(for: installProxy), to: ProxyInstaller.self)
        guard install(dataStore, installProxy, proxy as AnyObject) else {
            throw Failure.relayUnavailable
        }
    }
    #endif

    static func apply(_ mode: Mode, preferences: NSObject) throws {
        guard mode != .native else { return }
        let relayOnly = mode == .relayOnly
        #if !NEANTIK_WEBKIT_PROXY_QUALIFICATION && !NEANTIK_WEBKIT_PROXY_PRODUCTION
        if relayOnly { throw Failure.relayUnavailable }
        #endif
        let setter = NSSelectorFromString(relayOnly ? "_neAntikSetPeerConnectionRelayOnly:" : "_setPeerConnectionEnabled:")
        let getter = NSSelectorFromString(relayOnly ? "_neAntikPeerConnectionRelayOnly" : "_peerConnectionEnabled")
        let failure: Failure = relayOnly ? .relayUnavailable : .unavailable
        guard preferences.responds(to: setter), preferences.responds(to: getter) else {
            throw failure
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let set = unsafeBitCast(preferences.method(for: setter), to: Setter.self)
        let get = unsafeBitCast(preferences.method(for: getter), to: Getter.self)
        set(preferences, setter, relayOnly)
        guard get(preferences, getter) == relayOnly else { throw failure }
    }
}
