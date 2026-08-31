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

enum ProfileStorageLimits {
    static let maximumProfileCount = 10_000
}

enum PersistedInlineText {
    static func isSafe(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x200D ||
                (!CharacterSet.controlCharacters.contains(scalar) &&
                    !CharacterSet.illegalCharacters.contains(scalar))
        }
    }
}

struct ProxyConfiguration: Codable, Equatable, Sendable {
    // Keeps the legacy 512-character envelope usable for ordinary ZWJ emoji.
    static let maximumUsernameLength = 512
    static let maximumUsernameUTF8Bytes = 16 * 1_024

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
        "\(kind.title) · \(displayEndpoint)"
    }

    var displayEndpoint: String {
        "\(urlHost):\(port)"
    }

    var isValid: Bool {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanHost == host &&
            Self.isValidHost(cleanHost) &&
            PersistedInlineText.isSafe(username) &&
            !username.contains(":") &&
            username.count <= Self.maximumUsernameLength &&
            username.utf8.count <= Self.maximumUsernameUTF8Bytes &&
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

enum BrowserIdentityIssuancePolicy {
    static let legacyVersion = 1
    static let currentVersion = 2
    static let commonTupleIDs = [
        "macbook-air-m1",
        "macbook-air-m2",
        "macbook-air-m3",
        "macbook-air-m4"
    ]
    static let commonTupleResidues: [UInt32] = [0, 2, 5, 8]
    static let membersPerCohort: UInt32 = 195_225_786
    static let candidateCount: UInt64 = 780_903_144

    static func supports(_ version: Int) -> Bool {
        version == legacyVersion || version == currentVersion
    }

    static func isCurrentSeed(_ seed: UInt32) -> Bool {
        guard (1...BrowserIdentity.maximumRuntimeSeed).contains(seed)
        else {
            return false
        }
        return commonTupleResidues.contains(
            seed % UInt32(BrowserIdentityCatalog.tupleIDs.count)
        )
    }

    static func seed(
        cohortIndex: Int,
        ordinal: UInt32
    ) -> UInt32? {
        guard commonTupleResidues.indices.contains(cohortIndex),
              ordinal < membersPerCohort
        else {
            return nil
        }
        let tupleCount = UInt32(BrowserIdentityCatalog.tupleIDs.count)
        let residue = commonTupleResidues[cohortIndex]
        let value = residue == 0
            ? (ordinal + 1) * tupleCount
            : ordinal * tupleCount + residue
        guard (1...BrowserIdentity.maximumRuntimeSeed).contains(value)
        else {
            return nil
        }
        return value
    }

    static func newSeed() -> UInt32 {
        var generator = SystemRandomNumberGenerator()
        return newSeed(using: &generator)
    }

    static func newSeed<Generator: RandomNumberGenerator>(
        using generator: inout Generator
    ) -> UInt32 {
        let cohortIndex = Int.random(
            in: commonTupleResidues.indices,
            using: &generator
        )
        let ordinal = UInt32.random(
            in: 0..<membersPerCohort,
            using: &generator
        )
        // Both random domains and the immutable catalog contract are bounded,
        // so this construction cannot fail without source drift.
        return seed(cohortIndex: cohortIndex, ordinal: ordinal)!
    }

    static func isContractValid() -> Bool {
        guard commonTupleIDs.count == commonTupleResidues.count,
              UInt64(commonTupleIDs.count) *
                UInt64(membersPerCohort) == candidateCount
        else {
            return false
        }
        return zip(commonTupleIDs, commonTupleResidues).allSatisfy {
            tupleID, residue in
            BrowserIdentityCatalog.tupleIDs.indices.contains(Int(residue)) &&
                BrowserIdentityCatalog.tupleIDs[Int(residue)] == tupleID
        }
    }
}

struct BrowserIdentity: Codable, Equatable, Sendable {
    static let maximumRuntimeSeed = UInt32(Int32.max)

    let seed: UInt32
    let timezoneIdentifier: String?
    let localeIdentifier: String?
    let catalogVersion: Int
    let issuanceVersion: Int
    let deviceTupleID: String
    let proxyContextEvidence: ProxyContextEvidence?

    init(
        seed: UInt32? = nil,
        timezoneIdentifier: String? = nil,
        localeIdentifier: String? = nil,
        proxyContextEvidence: ProxyContextEvidence? = nil
    ) {
        let value: UInt32
        if let seed {
            value = Self.runtimeCompatibleSeed(seed)
            issuanceVersion =
                BrowserIdentityIssuancePolicy.legacyVersion
        } else {
            value = BrowserIdentityIssuancePolicy.newSeed()
            issuanceVersion =
                BrowserIdentityIssuancePolicy.currentVersion
        }
        self.seed = value
        catalogVersion = BrowserIdentityCatalog.currentVersion
        deviceTupleID = BrowserIdentityCatalog.tupleID(
            forRuntimeSeed: value
        )
        self.timezoneIdentifier =
            Self.validatedTimezone(timezoneIdentifier)
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
        case issuanceVersion
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
        let decodedIssuanceVersion =
            if container.contains(.issuanceVersion) {
                try container.decode(
                    Int.self,
                    forKey: .issuanceVersion
                )
            } else {
                BrowserIdentityIssuancePolicy.legacyVersion
            }
        guard BrowserIdentityIssuancePolicy.supports(
            decodedIssuanceVersion
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .issuanceVersion,
                in: container,
                debugDescription:
                    "Unsupported browser identity issuance version \(decodedIssuanceVersion)."
            )
        }
        if decodedIssuanceVersion ==
            BrowserIdentityIssuancePolicy.currentVersion &&
            (
                seed != Self.runtimeCompatibleSeed(seed) ||
                    !BrowserIdentityIssuancePolicy.isCurrentSeed(seed)
            ) {
            throw DecodingError.dataCorruptedError(
                forKey: .seed,
                in: container,
                debugDescription:
                    "Browser identity seed is outside its issuance policy."
            )
        }
        issuanceVersion = decodedIssuanceVersion
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
        timezoneIdentifier = Self.validatedTimezone(
            try container.decodeIfPresent(
                String.self,
                forKey: .timezoneIdentifier
            )
        )
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

    func replacingSeed(_ value: UInt32) -> BrowserIdentity? {
        let replacement = Self.runtimeCompatibleSeed(value)
        if issuanceVersion ==
            BrowserIdentityIssuancePolicy.currentVersion &&
            !BrowserIdentityIssuancePolicy.isCurrentSeed(replacement) {
            return nil
        }
        return BrowserIdentity(
            validatedSeed: replacement,
            issuanceVersion: issuanceVersion,
            timezoneIdentifier: timezoneIdentifier,
            localeIdentifier: localeIdentifier,
            proxyContextEvidence: proxyContextEvidence
        )
    }

    func replacingProxyContext(
        timezoneIdentifier: String?,
        localeIdentifier: String?,
        evidence: ProxyContextEvidence?
    ) -> BrowserIdentity {
        BrowserIdentity(
            validatedSeed: runtimeSeed,
            issuanceVersion: issuanceVersion,
            timezoneIdentifier: timezoneIdentifier,
            localeIdentifier: localeIdentifier,
            proxyContextEvidence: evidence
        )
    }

    private init(
        validatedSeed: UInt32,
        issuanceVersion: Int,
        timezoneIdentifier: String?,
        localeIdentifier: String?,
        proxyContextEvidence: ProxyContextEvidence?
    ) {
        seed = validatedSeed
        self.issuanceVersion = issuanceVersion
        catalogVersion = BrowserIdentityCatalog.currentVersion
        deviceTupleID = BrowserIdentityCatalog.tupleID(
            forRuntimeSeed: validatedSeed
        )
        self.timezoneIdentifier =
            Self.validatedTimezone(timezoneIdentifier)
        self.localeIdentifier =
            localeIdentifier.flatMap(Self.normalizedLocale)
        self.proxyContextEvidence = proxyContextEvidence.flatMap {
            $0.isValid ? $0 : nil
        }
    }

    private static func validatedTimezone(_ value: String?) -> String? {
        value.flatMap {
            TimeZone(identifier: $0) == nil ? nil : $0
        }
    }

    private static func normalizedLocale(_ value: String) -> String? {
        let components = value.replacingOccurrences(
            of: "_",
            with: "-"
        ).split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              (2...3).contains(components[0].count),
              Self.isASCIILetters(components[0])
        else {
            return nil
        }
        if components.count == 2 {
            guard components[1].count == 2,
                  Self.isASCIILetters(components[1])
            else {
                return nil
            }
            return "\(components[0].lowercased())-\(components[1].uppercased())"
        }
        return components[0].lowercased()
    }

    private static func isASCIILetters(_ value: Substring) -> Bool {
        value.utf8.count == value.count &&
            value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
            }
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

    var issuanceSummary: String {
        issuanceVersion == BrowserIdentityIssuancePolicy.currentVersion
            ? "Параметры устройства подобраны автоматически"
            : "Совместимость старого профиля"
    }
}

enum ProfileAppearance {
    static let colors = [
        "#FF3B4D",
        "#DC1635",
        "#F97316",
        "#EC4899",
        "#6C7CFF",
        "#8B5CF6",
        "#EAB308",
        "#10B981",
        "#06B6D4"
    ]

    static let symbols = [
        "globe",
        "briefcase.fill",
        "cart.fill",
        "megaphone.fill",
        "chart.bar.fill",
        "person.fill",
        "star.fill",
        "bolt.fill",
        "shield.fill",
        "bookmark.fill",
        "folder.fill",
        "shippingbox.fill"
    ]

    static func defaultColor(for id: UUID) -> String {
        colors[Int(stableHash(id) % UInt32(colors.count))]
    }

    static func defaultSymbol(for id: UUID) -> String {
        let hash = stableHash(id)
        return symbols[
            Int((hash / UInt32(colors.count)) % UInt32(symbols.count))
        ]
    }

    static func displaySymbol(_ storedName: String, profileID: UUID) -> String {
        symbols.contains(storedName) ? storedName : defaultSymbol(for: profileID)
    }

    static func title(for symbol: String) -> String {
        switch symbol {
        case "globe": "Интернет"
        case "briefcase.fill": "Работа"
        case "cart.fill": "Покупки"
        case "megaphone.fill": "Реклама"
        case "chart.bar.fill": "Аналитика"
        case "person.fill": "Личный"
        case "star.fill": "Избранное"
        case "bolt.fill": "Быстрый"
        case "shield.fill": "Защита"
        case "bookmark.fill": "Закладки"
        case "folder.fill": "Проект"
        case "shippingbox.fill": "Магазин"
        default: "Профиль"
        }
    }

    static func title(forColor hex: String) -> String {
        switch hex {
        case "#FF3B4D": "Красный"
        case "#DC1635": "Малиновый"
        case "#F97316": "Оранжевый"
        case "#EC4899": "Розовый"
        case "#6C7CFF": "Синий"
        case "#8B5CF6": "Фиолетовый"
        case "#EAB308": "Жёлтый"
        case "#10B981": "Зелёный"
        case "#06B6D4": "Бирюзовый"
        default: "Цвет профиля"
        }
    }

    static func usesDarkForeground(for hex: String) -> Bool {
        guard let luminance = relativeLuminance(for: hex) else {
            return false
        }
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast
    }

    static func symbolContrastRatio(for hex: String) -> Double? {
        guard let luminance = relativeLuminance(for: hex) else {
            return nil
        }
        return usesDarkForeground(for: hex)
            ? (luminance + 0.05) / 0.05
            : 1.05 / (luminance + 0.05)
    }

    private static func relativeLuminance(for hex: String) -> Double? {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#" else { return nil }
        let components = stride(from: 1, through: 5, by: 2).compactMap {
            UInt8(value.dropFirst($0).prefix(2), radix: 16)
        }
        guard components.count == 3 else { return nil }
        let linear = components.map { component -> Double in
            let channel = Double(component) / 255
            return channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] +
            0.7152 * linear[1] +
            0.0722 * linear[2]
    }

    static func isSafeStoredSymbol(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= 64 &&
            value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyz0123456789.-"
                ).contains($0)
            }
    }

    static func isSafeStoredColor(_ value: String) -> Bool {
        guard value.utf8.count == 7, value.utf8.first == 35 else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { byte in
            (48...57).contains(byte) ||
                (65...70).contains(byte) ||
                (97...102).contains(byte)
        }
    }

    private static func stableHash(_ id: UUID) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }
}

struct BrowserProfile: Codable, Identifiable, Equatable, Sendable {
    static let maximumNameLength = 120
    static let maximumNameUTF8Bytes = 4 * 1_024
    static let maximumTagCount = 8
    static let maximumTagLength = 24
    static let maximumTagUTF8Bytes = 1_024
    static let maximumNoteLength = 1_000
    static let maximumNoteUTF8Bytes = 4_096
    static let maximumStartURLUTF8Bytes = 16 * 1_024
    static let defaultStartURL = "https://aff.top/tools/fingerprint"

    var id: UUID
    var name: String
    var colorHex: String
    var symbolName: String
    var tags: [String]
    var note: String
    var isPinned: Bool
    var isArchived: Bool
    var startURL: String
    var proxy: ProxyConfiguration?
    var identity: BrowserIdentity
    var createdAt: Date
    var updatedAt: Date
    var revision: UInt64
    var lastLaunchedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String? = nil,
        symbolName: String? = nil,
        tags: [String] = [],
        note: String = "",
        isPinned: Bool = false,
        isArchived: Bool = false,
        startURL: String = BrowserProfile.defaultStartURL,
        proxy: ProxyConfiguration? = nil,
        identity: BrowserIdentity = BrowserIdentity(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: UInt64 = 0,
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex ?? ProfileAppearance.defaultColor(for: id)
        self.symbolName =
            symbolName ?? ProfileAppearance.defaultSymbol(for: id)
        self.tags = Self.normalizedTags(tags) ?? []
        self.note = Self.normalizedNote(note) ?? ""
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.startURL = startURL
        self.proxy = proxy
        self.identity = identity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.lastLaunchedAt = lastLaunchedAt
    }

    static func isValidName(_ value: String) -> Bool {
        !value.isEmpty &&
            value.count <= maximumNameLength &&
            value.utf8.count <= maximumNameUTF8Bytes &&
            PersistedInlineText.isSafe(value)
    }

    static func normalizedTags(_ values: [String]) -> [String]? {
        guard values.count <= maximumTagCount else { return nil }
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            let clean = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !clean.isEmpty,
                  clean.count <= maximumTagLength,
                  clean.utf8.count <= maximumTagUTF8Bytes,
                  PersistedInlineText.isSafe(clean)
            else {
                return nil
            }
            let key = clean.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if seen.insert(key).inserted {
                result.append(clean)
            }
        }
        return result
    }

    static func normalizedNote(_ value: String) -> String? {
        let normalizedLineEndings = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let clean = normalizedLineEndings.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard clean.count <= maximumNoteLength,
              clean.utf8.count <= maximumNoteUTF8Bytes
        else {
            return nil
        }
        for scalar in clean.unicodeScalars {
            if scalar.value == 0x09 || scalar.value == 0x0A {
                continue
            }
            guard !CharacterSet.controlCharacters.contains(scalar),
                  !CharacterSet.illegalCharacters.contains(scalar)
            else {
                return nil
            }
        }
        return clean
    }

    func normalizedForPersistence() -> BrowserProfile? {
        let cleanStartURL = startURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard Self.isValidName(name),
              ProfileAppearance.isSafeStoredColor(colorHex),
              ProfileAppearance.isSafeStoredSymbol(symbolName),
              let cleanTags = Self.normalizedTags(tags),
              let cleanNote = Self.normalizedNote(note),
              cleanStartURL == startURL,
              startURL.utf8.count <= Self.maximumStartURLUTF8Bytes,
              PersistedInlineText.isSafe(startURL),
              BrowserLaunchBuilder.validatedStartURL(startURL) != nil,
              proxy?.isValid != false
        else {
            return nil
        }
        var value = self
        value.tags = cleanTags
        value.note = cleanNote
        return value
    }

    static func nameByAppendingSuffix(
        _ suffix: String,
        to base: String
    ) -> String? {
        guard !suffix.isEmpty,
              suffix.count < maximumNameLength,
              suffix.utf8.count < maximumNameUTF8Bytes
        else {
            return nil
        }
        var prefix = String(
            base.prefix(maximumNameLength - suffix.count)
        )
        while !prefix.isEmpty {
            let candidate = prefix + suffix
            if isValidName(candidate) {
                return candidate
            }
            prefix.removeLast()
        }
        return nil
    }

    func duplicated(at date: Date = Date()) -> BrowserProfile {
        let suffix = " — копия"
        return BrowserProfile(
            name: Self.nameByAppendingSuffix(suffix, to: name) ?? "Копия",
            colorHex: colorHex,
            symbolName: symbolName,
            tags: tags,
            note: "",
            startURL: startURL,
            proxy: proxy,
            identity: BrowserIdentity(),
            createdAt: date,
            updatedAt: date
        )
    }

    var displaySymbolName: String {
        ProfileAppearance.displaySymbol(symbolName, profileID: id)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorHex
        case symbolName
        case tags
        case note
        case isPinned
        case isArchived
        case startURL
        case proxy
        case identity
        case createdAt
        case updatedAt
        case revision
        case lastLaunchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        let decodedSymbol = try container.decodeIfPresent(
            String.self,
            forKey: .symbolName
        ) ?? ProfileAppearance.defaultSymbol(for: id)
        symbolName = decodedSymbol
        let decodedTags = try container.decodeIfPresent(
            [String].self,
            forKey: .tags
        ) ?? []
        tags = decodedTags
        let decodedNote = try container.decodeIfPresent(
            String.self,
            forKey: .note
        ) ?? ""
        note = decodedNote
        isPinned = try container.decodeIfPresent(
            Bool.self,
            forKey: .isPinned
        ) ?? false
        isArchived = try container.decodeIfPresent(
            Bool.self,
            forKey: .isArchived
        ) ?? false
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
        revision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .revision
        ) ?? 0
        lastLaunchedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastLaunchedAt
        )
        guard let normalized = normalizedForPersistence() else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid persisted browser profile."
                )
            )
        }
        self = normalized
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
            ? "Доступна проверка отпечатка"
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
    case profileLimitReached
    case invalidProxy
    case profileArchived
    case concurrentLaunchLimitReached(Int)
    case runtimeValidationFailed(String)
    case processLaunchFailed(String)
    case proxyTestFailed(String)
    case proxyPreparationRequired
    case profileLaunchStateNotPersisted
    case fingerprintAuditFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            "Встроенный браузер NeAntik отсутствует или повреждён. Переустанови приложение из официального DMG или ZIP."
        case .profileAlreadyRunning:
            "Этот профиль уже запущен."
        case .invalidProfile:
            "Укажи название до 120 символов без переносов строк и корректную стартовую страницу."
        case .profileLimitReached:
            "Можно хранить не больше \(ProfileStorageLimits.maximumProfileCount) профилей."
        case .invalidProxy:
            "Укажи корректный хост и порт прокси."
        case .profileArchived:
            "Сначала верни профиль из архива."
        case let .concurrentLaunchLimitReached(limit):
            "Одновременно можно запускать не больше \(limit) профилей. Останови ненужный браузер и повтори запуск."
        case let .runtimeValidationFailed(message):
            "Браузерный движок не готов: \(message)"
        case let .processLaunchFailed(message):
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "Не удалось запустить браузер. " +
                    "Выбери профиль → Среда профиля → Показать подробности; если проверка " +
                    "не пройдена, переустанови NeAntik из официального DMG. " +
                    "Данные профиля удалять не нужно."
            } else {
                "Не удалось запустить браузер: \(message)"
            }
        case let .proxyTestFailed(message):
            "Прокси не прошёл проверку: \(message)"
        case .proxyPreparationRequired:
            "Прокси нужно безопасно проверить перед запуском. Запусти профиль из главного окна NeAntik."
        case .profileLaunchStateNotPersisted:
            "Браузер остановлен: NeAntik не смог безопасно сохранить состояние запуска профиля. Проверь доступ к данным приложения и повтори."
        case let .fingerprintAuditFailed(message):
            "Проверка отпечатка не прошла: \(message)"
        }
    }
}
