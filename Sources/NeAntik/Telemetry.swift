import CryptoKit
import Combine
import Foundation

enum NeAntikTelemetryEvent: String, Sendable {
    case snapshot
    case profileCreated = "profile_created"
    case browserLaunched = "browser_launched"
    case proxyEnabled = "proxy_enabled"
}

/// Opt-out, privacy-bounded product metrics. No URL, profile name/ID, proxy
/// value, cookie, page content or fingerprint material is ever serialized.
@MainActor
final class NeAntikTelemetry: ObservableObject {
    static let fallbackVersion = "0.6.1"
    static let fallbackBuild = "43"
    private static let installationKey = "telemetry.installationID"
    private static let endpoint = URL(string: "https://nevision-stats.iryadom.chatgpt.site/api/ingest")!

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: WorkspacePreferenceStore.telemetryEnabledKey) }
    }

    private let installationHash: String

    init(enabled: Bool = UserDefaults.standard.object(forKey: "telemetry.enabled") as? Bool ?? true) {
        self.enabled = enabled
        let rawID: String
        if let stored = UserDefaults.standard.string(forKey: Self.installationKey), !stored.isEmpty {
            rawID = stored
        } else {
            rawID = UUID().uuidString
            UserDefaults.standard.set(rawID, forKey: Self.installationKey)
        }
        installationHash = SHA256.hash(data: Data(rawID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func record(_ event: NeAntikTelemetryEvent, profileCount: Int, proxyProfileCount: Int) {
        guard enabled else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = Self.validVersion(info["CFBundleShortVersionString"] as? String)
        let build = Self.validBuild(info["CFBundleVersion"] as? String)
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "eventID": UUID().uuidString.lowercased(),
            "installationHash": installationHash,
            "edition": "direct",
            "version": version,
            "build": build,
            "osMajor": osMajor,
            "architecture": "arm64",
            "profileCount": max(0, min(profileCount, 10_000)),
            "proxyProfileCount": max(0, min(proxyProfileCount, profileCount)),
            "event": event.rawValue
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Task.detached(priority: .utility) {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    static func validVersion(_ raw: String?) -> String {
        guard let raw,
              raw.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              raw != "0.0.0"
        else { return fallbackVersion }
        return raw
    }

    static func validBuild(_ raw: String?) -> String {
        guard let raw,
              raw.range(of: #"^[1-9]\d*$"#, options: .regularExpression) != nil
        else { return fallbackBuild }
        return raw
    }
}
