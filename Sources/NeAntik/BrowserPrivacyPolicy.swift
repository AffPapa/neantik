import Foundation

/// Versioned intent. Missing policy is a legacy document, never a partially
/// decoded strict policy. Native enforcement is a separate runtime capability.
struct BrowserPrivacyPolicy: Codable, Equatable, Hashable, Sendable {
    enum RTC: String, Codable, CaseIterable, Sendable { case automatic, off, proxyOnly }
    enum LocalNetwork: String, Codable, CaseIterable, Sendable { case ask, deny }
    enum Media: String, Codable, CaseIterable, Sendable { case ask, deny }
    enum Retention: String, Codable, CaseIterable, Sendable { case persistent, ephemeral }
    enum Viewport: String, Codable, CaseIterable, Sendable { case native, standard }

    let schemaVersion: Int
    var rtc: RTC
    var localNetwork: LocalNetwork
    var media: Media
    var retention: Retention
    var viewport: Viewport
    var siteProtection: Bool
    var trackingParameterCleanup: Bool
    var disableSyncAndAutofill: Bool

    static let legacy = Self(rtc: .automatic, localNetwork: .ask, media: .ask,
                             retention: .persistent, viewport: .native,
                             siteProtection: false, trackingParameterCleanup: false,
                             disableSyncAndAutofill: false)
    static let balanced = Self(rtc: .proxyOnly, localNetwork: .deny, media: .ask,
                               retention: .persistent, viewport: .native,
                               siteProtection: true, trackingParameterCleanup: true,
                               disableSyncAndAutofill: true)
    static let strict = Self(rtc: .off, localNetwork: .deny, media: .deny,
                             retention: .persistent, viewport: .standard,
                             siteProtection: true, trackingParameterCleanup: true,
                             disableSyncAndAutofill: true)

    init(rtc: RTC, localNetwork: LocalNetwork, media: Media, retention: Retention,
         viewport: Viewport, siteProtection: Bool, trackingParameterCleanup: Bool,
         disableSyncAndAutofill: Bool) {
        schemaVersion = 1
        self.rtc = rtc; self.localNetwork = localNetwork; self.media = media
        self.retention = retention; self.viewport = viewport
        self.siteProtection = siteProtection
        self.trackingParameterCleanup = trackingParameterCleanup
        self.disableSyncAndAutofill = disableSyncAndAutofill
    }

    var presetName: String {
        var controls = self; controls.retention = .persistent
        if controls == .legacy { return "legacy" }
        if controls == .balanced { return "balanced" }
        if controls == .strict { return "strict" }
        return "custom"
    }

    /// Customized policies must not silently lose the strict preset's
    /// extension isolation when an unrelated control is changed.
    var restrictsUserExtensions: Bool {
        presetName == "strict" || presetName == "custom"
    }

    static func preset(named name: String) -> Self? {
        switch name {
        case "legacy": .legacy
        case "balanced": .balanced
        case "strict": .strict
        default: nil
        }
    }

    /// Changing a preset must never turn an existing disposable session into
    /// persistent storage (or delete a persistent profile implicitly).
    func applyingPreset(_ name: String) -> BrowserPrivacyPolicy? {
        guard var value = Self.preset(named: name) else { return nil }
        value.retention = retention
        return value
    }

    var draftToken: String {
        [String(schemaVersion), rtc.rawValue, localNetwork.rawValue, media.rawValue,
         retention.rawValue, viewport.rawValue, String(siteProtection),
         String(trackingParameterCleanup), String(disableSyncAndAutofill)].joined(separator: "|")
    }

    var safeIntent: [String: Any] {
        ["schemaVersion": schemaVersion, "preset": presetName, "rtc": rtc.rawValue,
         "localNetwork": localNetwork.rawValue, "media": media.rawValue,
         "retention": retention.rawValue, "viewport": viewport.rawValue,
         "siteProtection": siteProtection, "trackingParameterCleanup": trackingParameterCleanup,
         "disableSyncAndAutofill": disableSyncAndAutofill,
         "siteProtectionScope": "NeAntik known-domain and tracker filters only; not Google Safe Browsing or unsafe-download scanning",
         "evidence": "saved-intent; not native qualification"]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, rtc, localNetwork, media, retention, viewport
        case siteProtection, trackingParameterCleanup, disableSyncAndAutofill
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw UnsupportedBrowserPrivacyPolicyError() }
        rtc = try c.decode(RTC.self, forKey: .rtc)
        localNetwork = try c.decode(LocalNetwork.self, forKey: .localNetwork)
        media = try c.decode(Media.self, forKey: .media)
        retention = try c.decode(Retention.self, forKey: .retention)
        viewport = try c.decode(Viewport.self, forKey: .viewport)
        siteProtection = try c.decode(Bool.self, forKey: .siteProtection)
        trackingParameterCleanup = try c.decode(Bool.self, forKey: .trackingParameterCleanup)
        disableSyncAndAutofill = try c.decode(Bool.self, forKey: .disableSyncAndAutofill)
    }

    static func hasExplicitProfilePolicies(in data: Data) -> Bool {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = document["profiles"] as? [[String: Any]] else { return false }
        return profiles.allSatisfy { $0["privacyPolicy"] is [String: Any] }
    }
}

struct UnsupportedBrowserPrivacyPolicyError: LocalizedError {
    var errorDescription: String? {
        "Эта политика защиты требует совместимой версии NeAntik и квалифицированного движка. Настройки и данные не изменены."
    }
}
