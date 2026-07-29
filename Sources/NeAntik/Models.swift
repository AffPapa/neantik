import Darwin
import Foundation

enum ProxyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case http
    case https
    case socks5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .http: "HTTP"
        case .https: "HTTPS"
        case .socks5: "SOCKS5"
        }
    }

    var chromiumScheme: String {
        switch self {
        case .http: "http"
        case .https: "https"
        case .socks5: "socks5"
        }
    }

    var curlScheme: String {
        switch self {
        case .http: "http"
        case .https: "https"
        case .socks5: "socks5h"
        }
    }
}

struct ProxyConfiguration: Codable, Equatable, Sendable {
    var kind: ProxyKind
    var host: String
    var port: Int
    var username: String

    var chromiumServer: String {
        "\(kind.chromiumScheme)://\(urlHost):\(port)"
    }

    var curlServer: String {
        "\(kind.curlScheme)://\(urlHost):\(port)"
    }

    var displayName: String {
        "\(kind.title) · \(host):\(port)"
    }

    var isValid: Bool {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanHost == host &&
            Self.isValidHost(cleanHost) &&
            username.rangeOfCharacter(from: .controlCharacters) == nil &&
            !username.contains(":") &&
            username.count <= 512 &&
            (kind != .socks5 || username.isEmpty) &&
            (1...65_535).contains(port)
    }

    private var urlHost: String {
        let value = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        return value.contains(":") ? "[\(value)]" : value
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else {
            return false
        }

        let unwrapped = value.hasPrefix("[") && value.hasSuffix("]")
            ? String(value.dropFirst().dropLast())
            : value
        var storage = sockaddr_storage()
        if unwrapped.withCString({
            inet_pton(AF_INET, $0, &storage)
        }) == 1 || unwrapped.withCString({
            inet_pton(AF_INET6, $0, &storage)
        }) == 1 {
            return true
        }

        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-."
        )
        guard unwrapped.unicodeScalars.allSatisfy(allowed.contains) else {
            return false
        }
        let labels = unwrapped.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return !labels.isEmpty && labels.allSatisfy {
            !$0.isEmpty &&
                $0.utf8.count <= 63 &&
                $0.first != "-" &&
                $0.last != "-"
        }
    }
}

struct ProxyContextEvidence: Codable, Equatable, Sendable {
    static let supportedSource = "ipapi.co"
    static let freshnessLifetime: TimeInterval = 30 * 24 * 60 * 60

    let source: String
    let observedAt: Date

    static func ipAPI(observedAt: Date = Date()) -> ProxyContextEvidence {
        ProxyContextEvidence(
            source: supportedSource,
            observedAt: observedAt
        )
    }

    var isValid: Bool {
        source == Self.supportedSource &&
            observedAt.timeIntervalSinceReferenceDate.isFinite
    }

    func isFresh(relativeTo now: Date = Date()) -> Bool {
        guard isValid else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= -5 * 60 && age <= Self.freshnessLifetime
    }
}

enum BrowserIdentityCatalog {
    static let currentVersion = 1

    // Version 1 is immutable. Reordering, removing, or appending entries would
    // change seed modulo selection for existing profiles. A future catalog
    // must use a new version and an explicit user-visible identity migration.
    static let tupleIDs = [
        "macbook-air-m1",
        "macbook-pro-m1-pro",
        "macbook-air-m2",
        "macbook-pro-m2-max",
        "macbook-pro-m2-pro",
        "macbook-air-m3",
        "macbook-pro-m3-max",
        "macbook-pro-m3-pro",
        "macbook-air-m4",
        "macbook-pro-m4-max",
        "macbook-pro-m4-pro"
    ]

    static func tupleID(forRuntimeSeed seed: UInt32) -> String {
        tupleIDs[Int(seed % UInt32(tupleIDs.count))]
    }
}

struct BrowserIdentity: Codable, Equatable, Sendable {
    static let maximumRuntimeSeed = UInt32(Int32.max)

    let seed: UInt32
    let timezoneIdentifier: String?
    let localeIdentifier: String?
    let catalogVersion: Int
    let deviceTupleID: String
    let proxyContextEvidence: ProxyContextEvidence?

    init(
        seed: UInt32? = nil,
        timezoneIdentifier: String? = nil,
        localeIdentifier: String? = nil,
        proxyContextEvidence: ProxyContextEvidence? = nil
    ) {
        let value = seed ??
            UInt32.random(in: 1...Self.maximumRuntimeSeed)
        self.seed = Self.runtimeCompatibleSeed(value)
        catalogVersion = BrowserIdentityCatalog.currentVersion
        deviceTupleID = BrowserIdentityCatalog.tupleID(
            forRuntimeSeed: Self.runtimeCompatibleSeed(value)
        )
        self.timezoneIdentifier = timezoneIdentifier.flatMap {
            TimeZone(identifier: $0) == nil ? nil : $0
        }
        self.localeIdentifier = localeIdentifier.flatMap(Self.normalizedLocale)
        self.proxyContextEvidence = proxyContextEvidence.flatMap {
            $0.isValid ? $0 : nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case seed
        case timezoneIdentifier
        case localeIdentifier
        case catalogVersion
        case deviceTupleID
        case proxyContextEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSeed = try container.decode(UInt32.self, forKey: .seed)
        seed = decodedSeed == 0 ? 1 : decodedSeed
        let decodedCatalogVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .catalogVersion
        ) ?? BrowserIdentityCatalog.currentVersion
        guard decodedCatalogVersion == BrowserIdentityCatalog.currentVersion
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .catalogVersion,
                in: container,
                debugDescription:
                    "Unsupported browser identity catalog version \(decodedCatalogVersion)."
            )
        }
        catalogVersion = decodedCatalogVersion
        let expectedTupleID = BrowserIdentityCatalog.tupleID(
            forRuntimeSeed: Self.runtimeCompatibleSeed(seed)
        )
        if let decodedTupleID = try container.decodeIfPresent(
            String.self,
            forKey: .deviceTupleID
        ), decodedTupleID != expectedTupleID {
            throw DecodingError.dataCorruptedError(
                forKey: .deviceTupleID,
                in: container,
                debugDescription:
                    "Browser identity tuple does not match its immutable seed."
            )
        }
        deviceTupleID = expectedTupleID
        timezoneIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .timezoneIdentifier
        ).flatMap {
            TimeZone(identifier: $0) == nil ? nil : $0
        }
        localeIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .localeIdentifier
        ).flatMap(Self.normalizedLocale)
        proxyContextEvidence = try container.decodeIfPresent(
            ProxyContextEvidence.self,
            forKey: .proxyContextEvidence
        ).flatMap {
            $0.isValid ? $0 : nil
        }
    }

    static func runtimeCompatibleSeed(_ value: UInt32) -> UInt32 {
        let folded = value & maximumRuntimeSeed
        return folded == 0 ? 1 : folded
    }

    var runtimeSeed: UInt32 {
        Self.runtimeCompatibleSeed(seed)
    }

    private static func normalizedLocale(_ value: String) -> String? {
        let components = value.replacingOccurrences(
            of: "_",
            with: "-"
        ).split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              (2...3).contains(components[0].count),
              components[0].allSatisfy(\.isLetter)
        else {
            return nil
        }
        if components.count == 2 {
            guard components[1].count == 2,
                  components[1].allSatisfy(\.isLetter)
            else {
                return nil
            }
            return "\(components[0].lowercased())-\(components[1].uppercased())"
        }
        return components[0].lowercased()
    }

    static func migrated(profileID: UUID) -> BrowserIdentity {
        var hash: UInt32 = 2_166_136_261
        for byte in profileID.uuidString.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return BrowserIdentity(seed: hash)
    }

    var displayCode: String {
        String(format: "NA-%08X", runtimeSeed)
    }
}

struct BrowserProfile: Codable, Identifiable, Equatable, Sendable {
    static let maximumNameLength = 120

    var id: UUID
    var name: String
    var colorHex: String
    var startURL: String
    var proxy: ProxyConfiguration?
    var identity: BrowserIdentity
    var createdAt: Date
    var updatedAt: Date
    var lastLaunchedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#FF3B4D",
        startURL: String = "https://www.google.com",
        proxy: ProxyConfiguration? = nil,
        identity: BrowserIdentity = BrowserIdentity(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.startURL = startURL
        self.proxy = proxy
        self.identity = identity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastLaunchedAt = lastLaunchedAt
    }

    static func isValidName(_ value: String) -> Bool {
        !value.isEmpty &&
            value.count <= maximumNameLength &&
            value.rangeOfCharacter(
                from: .controlCharacters
            ) == nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorHex
        case startURL
        case proxy
        case identity
        case createdAt
        case updatedAt
        case lastLaunchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        startURL = try container.decode(String.self, forKey: .startURL)
        proxy = try container.decodeIfPresent(
            ProxyConfiguration.self,
            forKey: .proxy
        )
        identity = try container.decodeIfPresent(
            BrowserIdentity.self,
            forKey: .identity
        ) ?? BrowserIdentity.migrated(profileID: id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastLaunchedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastLaunchedAt
        )
    }
}

struct BrowserRuntimeCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let fingerprintSeed = BrowserRuntimeCapabilities(rawValue: 1 << 0)
    static let platformOverride = BrowserRuntimeCapabilities(rawValue: 1 << 1)

    static let fingerprintIdentity: BrowserRuntimeCapabilities = [
        .fingerprintSeed,
        .platformOverride
    ]
}

enum BrowserRuntimeFlavor: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case fingerprintChromium
    case cloak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            "Обычный Chromium"
        case .fingerprintChromium:
            "Chromium с разделением отпечатков"
        case .cloak:
            "Cloak Chromium"
        }
    }

    var capabilities: BrowserRuntimeCapabilities {
        switch self {
        case .standard:
            []
        case .fingerprintChromium, .cloak:
            .fingerprintIdentity
        }
    }
}

struct BrowserRuntimePreference: Codable, Equatable, Sendable {
    var path: String
    var flavor: BrowserRuntimeFlavor
    var updatedAt: Date
}

struct BrowserRuntime: Identifiable, Hashable, Sendable {
    var id: String { executableURL.path }
    let name: String
    let executableURL: URL
    let source: String
    let flavor: BrowserRuntimeFlavor
    let capabilities: BrowserRuntimeCapabilities
    let inspection: BrowserRuntimeInspection

    init(
        name: String,
        executableURL: URL,
        source: String,
        flavor: BrowserRuntimeFlavor = .standard,
        capabilities: BrowserRuntimeCapabilities? = nil,
        inspection: BrowserRuntimeInspection? = nil
    ) {
        self.name = name
        self.executableURL = executableURL
        self.source = source
        self.flavor = flavor
        self.capabilities = capabilities ?? flavor.capabilities
        self.inspection = inspection ??
            BrowserRuntimeInspector.inspect(executableURL: executableURL)
    }

    var supportsFingerprintIdentity: Bool {
        capabilities.contains(.fingerprintIdentity)
    }

    var privacySummary: String {
        supportsFingerprintIdentity
            ? "Разделение отпечатков готово"
            : "Только изоляция данных"
    }

    var runtimeSummary: String {
        var parts = [source]
        if let version = inspection.version, !version.isEmpty {
            parts.append("v\(version)")
        }
        if !inspection.architectures.isEmpty {
            parts.append(inspection.architectures.joined(separator: "+"))
        }
        return parts.joined(separator: " · ")
    }
}

enum NeAntikError: LocalizedError {
    case browserNotFound
    case profileAlreadyRunning
    case invalidProfile
    case invalidProxy
    case runtimeValidationFailed(String)
    case processLaunchFailed(String)
    case proxyTestFailed(String)
    case fingerprintAuditFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            "Chromium или Google Chrome не найден."
        case .profileAlreadyRunning:
            "Этот профиль уже запущен."
        case .invalidProfile:
            "Укажи название до 120 символов без переносов строк и корректную стартовую страницу."
        case .invalidProxy:
            "Укажи корректный хост и порт прокси."
        case let .runtimeValidationFailed(message):
            "Браузерный движок не готов: \(message)"
        case .processLaunchFailed:
            "Не удалось запустить браузер. Проверь целостность приложения и доступ к папке профиля."
        case let .proxyTestFailed(message):
            "Прокси не прошёл проверку: \(message)"
        case let .fingerprintAuditFailed(message):
            "Проверка отпечатка не прошла: \(message)"
        }
    }
}
