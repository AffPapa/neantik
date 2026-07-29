import Combine
import Foundation

enum TelemetryEvent: String, Codable, Sendable {
    case snapshot
    case consentEnabled = "consent_enabled"
    case profileCreated = "profile_created"
    case profileDeleted = "profile_deleted"
    case proxyEnabled = "proxy_enabled"
    case proxyDisabled = "proxy_disabled"
    case browserLaunched = "browser_launched"
}

enum TelemetryEdition: String, Codable, Sendable {
    case direct
    case store
}

struct TelemetrySnapshot: Equatable, Sendable {
    let profileCount: Int
    let proxyProfileCount: Int

    init(profileCount: Int, proxyProfileCount: Int) {
        let profiles = min(max(profileCount, 0), 10_000)
        self.profileCount = profiles
        self.proxyProfileCount = min(
            max(proxyProfileCount, 0),
            profiles
        )
    }
}

struct TelemetryPayload: Encodable, Equatable, Sendable {
    let schemaVersion = 2
    let eventID: String
    let edition: TelemetryEdition
    let version: String
    let build: String
    let osMajor: Int
    let architecture = "arm64"
    let profileCount: Int
    let proxyProfileCount: Int
    let event: TelemetryEvent
}

struct TelemetryConfiguration: Equatable, Sendable {
    let endpoint: URL?
    let publicStatsURL: URL?

    static func fromBundle(_ bundle: Bundle = .main) -> Self {
        Self(
            endpoint: validatedURL(
                bundle.object(
                    forInfoDictionaryKey: "NeAntikTelemetryEndpoint"
                ) as? String
            ),
            publicStatsURL: validatedURL(
                bundle.object(
                    forInfoDictionaryKey: "NeAntikPublicStatsURL"
                ) as? String
            )
        )
    }

    private static func validatedURL(_ rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return nil
        }
        return url
    }
}

actor TelemetryNetworkClient {
    private let endpoint: URL
    private let edition: TelemetryEdition
    private let version: String
    private let build: String
    private let session: URLSession
    private var isAuthorized: Bool

    init(
        endpoint: URL,
        edition: TelemetryEdition,
        isAuthorized: Bool,
        bundle: Bundle = .main,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.edition = edition
        version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"
        self.session = session
        self.isAuthorized = isAuthorized
    }

    func setAuthorized(_ authorized: Bool) {
        isAuthorized = authorized
    }

    func send(
        event: TelemetryEvent,
        snapshot: TelemetrySnapshot
    ) async {
        guard isAuthorized else {
            return
        }
        do {
            let payload = TelemetryPayload(
                eventID: UUID().uuidString.lowercased(),
                edition: edition,
                version: version,
                build: build,
                osMajor: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion,
                profileCount: snapshot.profileCount,
                proxyProfileCount: snapshot.proxyProfileCount,
                event: event
            )
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try JSONEncoder().encode(payload)
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                return
            }
        } catch {
            // Telemetry is best-effort and must never affect browser use.
        }
    }

    func revoke() async {
        isAuthorized = false
    }
}

@MainActor
final class TelemetryController: ObservableObject {
    @Published private(set) var isEnabled: Bool

    let publicStatsURL: URL?
    let isConfigured: Bool

    private let defaults: UserDefaults
    private let consentKey: String
    private let network: TelemetryNetworkClient?

    init(
        edition: TelemetryEdition,
        configuration: TelemetryConfiguration = .fromBundle(),
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        consentKey = "NeAntikTelemetryConsent.\(edition.rawValue).v1"
        publicStatsURL = configuration.publicStatsURL
        isConfigured = configuration.endpoint != nil
        let enabled =
            configuration.endpoint != nil &&
            defaults.bool(forKey: consentKey)
        isEnabled = enabled
        if let endpoint = configuration.endpoint {
            network = TelemetryNetworkClient(
                endpoint: endpoint,
                edition: edition,
                isAuthorized: enabled
            )
        } else {
            network = nil
        }
        if !enabled, let network {
            Task {
                await network.revoke()
            }
        }
    }

    func setEnabled(
        _ enabled: Bool,
        snapshot: TelemetrySnapshot
    ) {
        guard isConfigured else {
            isEnabled = false
            defaults.set(false, forKey: consentKey)
            return
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: consentKey)
        guard let network else {
            return
        }
        if enabled {
            Task {
                await network.setAuthorized(true)
                await network.send(
                    event: .consentEnabled,
                    snapshot: snapshot
                )
            }
        } else {
            Task {
                await network.revoke()
            }
        }
    }

    func record(
        _ event: TelemetryEvent,
        snapshot: TelemetrySnapshot
    ) {
        guard isEnabled, let network else {
            return
        }
        Task {
            await network.send(event: event, snapshot: snapshot)
        }
    }
}
