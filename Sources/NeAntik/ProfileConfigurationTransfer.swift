import Foundation

/// A portable, metadata-only profile configuration.
///
/// This format is deliberately not a backup of a browser profile. It excludes
/// BrowserData, cookies, local storage, notes, last-launch state, identity
/// seeds, fingerprint evidence and Keychain values. Import always creates new
/// profile IDs and a new browser identity so a configuration file cannot clone
/// a live session or silently reuse an identity.
struct ProfileConfigurationTransferDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 8
    static let maximumProfileCount = ProfileStorageLimits.maximumProfileCount

    let schemaVersion: Int
    let exportedAt: Date
    let profiles: [ProfileConfigurationTransferEntry]

    init(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String] = [:],
        folderPathByProfileID: [UUID: [String]] = [:],
        exportedAt: Date = Date()
    ) throws {
        guard profiles.count <= Self.maximumProfileCount else {
            throw ProfileConfigurationTransferError.tooManyProfiles
        }
        guard exportedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProfileConfigurationTransferError.invalidDate
        }

        if profiles.contains(where: { folderPathByProfileID[$0.id, default: []].count > 1 }) {
            self.schemaVersion = Self.currentSchemaVersion
        } else if profiles.contains(where: \.webKitRelayOnly) {
            self.schemaVersion = 7
        } else if profiles.contains(where: { $0.privacyPolicy != .legacy }) {
            self.schemaVersion = 6
        } else if profiles.contains(where: \.webKitBlockPeerConnections) {
            self.schemaVersion = 5
        } else if profiles.contains(where: { $0.webKitRuntimeGeneration != .system }) {
            self.schemaVersion = 4
        } else if profiles.contains(where: { $0.webKitMediaPolicy == .deny }) {
            self.schemaVersion = 3
        } else {
            self.schemaVersion = profiles.contains(where: { $0.engine == .webkit }) ? 2 : 1
        }
        self.exportedAt = exportedAt
        self.profiles = try profiles.map { profile in
            let folderPath = folderPathByProfileID[profile.id]
            let folderName = folderPath?.last ?? folderNameByProfileID[profile.id]
            return try ProfileConfigurationTransferEntry(
                profile: profile,
                folderName: folderName,
                folderPath: folderPath
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw ProfileConfigurationTransferError.unsupportedSchema
        }
        let exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        guard exportedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProfileConfigurationTransferError.invalidDate
        }
        let profiles = try container.decode(
            [ProfileConfigurationTransferEntry].self,
            forKey: .profiles
        )
        guard (schemaVersion >= 2 || !profiles.contains(where: { $0.engine == .webkit })),
              (schemaVersion >= 3 || !profiles.contains(where: { $0.webKitMediaPolicy == .deny })),
              (schemaVersion >= 4 || !profiles.contains(where: { $0.webKitRuntimeGeneration.map { $0 != .system } == true })),
              (schemaVersion >= 5 || !profiles.contains(where: { $0.webKitBlockPeerConnections == true })),
              (schemaVersion < 5 || !profiles.contains(where: { $0.webKitBlockPeerConnections == nil })),
              (schemaVersion >= 6 || !profiles.contains(where: { ($0.privacyPolicy ?? .legacy) != .legacy })),
              (schemaVersion < 6 || !profiles.contains(where: { $0.privacyPolicy == nil })),
              (schemaVersion >= 7 || !profiles.contains(where: { $0.webKitRelayOnly == true })),
              (schemaVersion < 7 || !profiles.contains(where: { $0.webKitRelayOnly == nil })) else {
            throw ProfileConfigurationTransferError.unsupportedSchema
        }
        guard schemaVersion >= 8 || !profiles.contains(where: { ($0.folderPath?.count ?? 0) > 1 }) else {
            throw ProfileConfigurationTransferError.unsupportedSchema
        }
        guard !profiles.isEmpty else {
            throw ProfileConfigurationTransferError.emptyDocument
        }
        guard profiles.count <= Self.maximumProfileCount else {
            throw ProfileConfigurationTransferError.tooManyProfiles
        }
        try Self.validateFolderNames(in: profiles)
        try profiles.forEach { try $0.validate() }

        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.profiles = profiles
    }

    /// Creates new local profiles from the portable entries.
    ///
    /// The returned profiles have revision zero so they can pass through the
    /// normal ProfileStore insertion transaction. Their IDs, identities and
    /// timestamps are intentionally fresh.
    func makeProfiles(now: Date = Date()) throws -> [BrowserProfile] {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ProfileConfigurationTransferError.invalidDate
        }
        return profiles.map { entry in
            BrowserProfile(
                name: entry.name,
                colorHex: entry.colorHex,
                symbolName: entry.symbolName,
                tags: entry.tags,
                note: "",
                isPinned: entry.isPinned,
                isArchived: entry.isArchived,
                startURL: entry.startURL,
                startupMode: entry.startupMode ?? .startPage,
                engine: entry.engine ?? .chromium,
                webKitRuntimeGeneration: entry.webKitRuntimeGeneration ?? .system,
                webKitMediaPolicy: entry.webKitMediaPolicy ?? .ask,
                webKitBlockPeerConnections: entry.webKitBlockPeerConnections ?? false,
                webKitRelayOnly: entry.webKitRelayOnly ?? false,
                fontPolicy: (entry.engine ?? .chromium) == .chromium && (entry.privacyPolicy ?? .legacy) != .legacy ? .systemV1 : .native,
                privacyPolicy: entry.privacyPolicy ?? .legacy,
                proxy: entry.proxy,
                identity: BrowserIdentity(),
                createdAt: now,
                updatedAt: now,
                revision: 0,
                lastLaunchedAt: nil
            )
        }
    }

    func folderName(at index: Int) -> String? {
        guard profiles.indices.contains(index) else { return nil }
        return profiles[index].folderName
    }

    func folderPath(at index: Int) -> [String]? {
        guard profiles.indices.contains(index) else { return nil }
        if let path = profiles[index].folderPath { return path }
        return profiles[index].folderName.map { [$0] }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exportedAt
        case profiles
    }

    private static func validateFolderNames(
        in profiles: [ProfileConfigurationTransferEntry]
    ) throws {
        for profile in profiles {
            if let folderName = profile.folderName {
                guard let normalized = ProfileFolder.normalizedName(folderName),
                      normalized == folderName else {
                    throw ProfileConfigurationTransferError.invalidFolderName
                }
            }
            if let folderPath = profile.folderPath {
                guard !folderPath.isEmpty,
                      folderPath.allSatisfy({ ProfileFolder.normalizedName($0) == $0 }),
                      folderPath.last == profile.folderName else {
                    throw ProfileConfigurationTransferError.invalidFolderName
                }
            }
            if profile.folderPath?.count ?? 0 > 1 {
                guard profile.folderName == profile.folderPath?.last else {
                    throw ProfileConfigurationTransferError.invalidFolderName
                }
            }
            if profile.folderName == nil && profile.folderPath != nil {
                throw ProfileConfigurationTransferError.invalidFolderName
            }
        }
    }
}

struct ProfileConfigurationTransferEntry: Codable, Equatable, Sendable {
    let name: String
    let colorHex: String
    let symbolName: String
    let tags: [String]
    let isPinned: Bool
    let isArchived: Bool
    let startURL: String
    let startupMode: BrowserStartupMode?
    let engine: BrowserEngine?
    let webKitRuntimeGeneration: WebKitRuntimeGeneration?
    let webKitMediaPolicy: WebKitMediaPolicy?
    let webKitBlockPeerConnections: Bool?
    let webKitRelayOnly: Bool?
    let privacyPolicy: BrowserPrivacyPolicy?
    let proxy: ProxyConfiguration?
    let folderName: String?
    let folderPath: [String]?

    init(
        name: String,
        colorHex: String,
        symbolName: String,
        tags: [String],
        isPinned: Bool,
        isArchived: Bool,
        startURL: String,
        startupMode: BrowserStartupMode? = nil,
        engine: BrowserEngine? = nil,
        webKitRuntimeGeneration: WebKitRuntimeGeneration? = nil,
        webKitMediaPolicy: WebKitMediaPolicy? = nil,
        webKitBlockPeerConnections: Bool? = nil,
        webKitRelayOnly: Bool? = nil,
        privacyPolicy: BrowserPrivacyPolicy? = nil,
        proxy: ProxyConfiguration?,
        folderName: String?,
        folderPath: [String]? = nil
    ) {
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.tags = tags
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.startURL = startURL
        self.startupMode = startupMode
        self.engine = engine
        self.webKitRuntimeGeneration = webKitRuntimeGeneration
        self.webKitMediaPolicy = webKitMediaPolicy
        self.webKitBlockPeerConnections = webKitBlockPeerConnections
        self.webKitRelayOnly = webKitRelayOnly
        self.privacyPolicy = privacyPolicy
        self.proxy = proxy
        self.folderName = folderName
        self.folderPath = folderPath
    }

    init(
        profile: BrowserProfile,
        folderName: String?,
        folderPath: [String]? = nil
    ) throws {
        guard let normalized = profile.normalizedForPersistence() else {
            throw ProfileConfigurationTransferError.invalidProfile
        }
        if let folderName,
           ProfileFolder.normalizedName(folderName) != folderName {
            throw ProfileConfigurationTransferError.invalidFolderName
        }
        if let folderPath,
           folderPath.isEmpty ||
            !folderPath.allSatisfy({ ProfileFolder.normalizedName($0) == $0 }) ||
            folderPath.last != folderName {
            throw ProfileConfigurationTransferError.invalidFolderName
        }
        name = normalized.name
        colorHex = normalized.colorHex
        symbolName = normalized.symbolName
        tags = normalized.tags
        isPinned = normalized.isPinned
        isArchived = normalized.isArchived
        startURL = normalized.startURL
        startupMode = normalized.startupMode
        engine = normalized.engine
        webKitRuntimeGeneration = normalized.webKitRuntimeGeneration
        webKitMediaPolicy = normalized.webKitMediaPolicy
        webKitBlockPeerConnections = normalized.webKitBlockPeerConnections
        webKitRelayOnly = normalized.webKitRelayOnly
        privacyPolicy = normalized.privacyPolicy
        proxy = normalized.proxy
        self.folderName = folderName
        self.folderPath = folderPath
    }

    func validate() throws {
        let profile = BrowserProfile(
            name: name,
            colorHex: colorHex,
            symbolName: symbolName,
            tags: tags,
            note: "",
            isPinned: isPinned,
            isArchived: isArchived,
            startURL: startURL,
            startupMode: startupMode ?? .startPage,
            engine: engine ?? .chromium,
            webKitRuntimeGeneration: webKitRuntimeGeneration ?? .system,
            webKitMediaPolicy: webKitMediaPolicy ?? .ask,
            webKitBlockPeerConnections: webKitBlockPeerConnections ?? false,
            webKitRelayOnly: webKitRelayOnly ?? false,
            privacyPolicy: privacyPolicy ?? .legacy,
            proxy: proxy,
            identity: BrowserIdentity()
        )
        guard profile.normalizedForPersistence() != nil else {
            throw ProfileConfigurationTransferError.invalidProfile
        }
        if let folderName,
           ProfileFolder.normalizedName(folderName) != folderName {
            throw ProfileConfigurationTransferError.invalidFolderName
        }
        if let folderPath,
           folderPath.isEmpty ||
            !folderPath.allSatisfy({ ProfileFolder.normalizedName($0) == $0 }) ||
            folderPath.last != folderName {
            throw ProfileConfigurationTransferError.invalidFolderName
        }
    }
}

enum ProfileConfigurationTransferError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema
    case invalidDate
    case emptyDocument
    case tooManyProfiles
    case invalidProfile
    case invalidFolderName

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            NSLocalizedString("userError.055", tableName: "Errors", bundle: .main, value: "Файл конфигурации создан другой версией NeAntik.", comment: "")
        case .invalidDate:
            NSLocalizedString("userError.056", tableName: "Errors", bundle: .main, value: "Файл конфигурации содержит некорректную дату.", comment: "")
        case .emptyDocument:
            NSLocalizedString("userError.057", tableName: "Errors", bundle: .main, value: "Файл конфигурации не содержит профилей.", comment: "")
        case .tooManyProfiles:
            NSLocalizedString("userError.058", tableName: "Errors", bundle: .main, value: "Файл конфигурации содержит слишком много профилей.", comment: "")
        case .invalidProfile:
            NSLocalizedString("userError.059", tableName: "Errors", bundle: .main, value: "Файл конфигурации содержит некорректные параметры профиля.", comment: "")
        case .invalidFolderName:
            NSLocalizedString("userError.060", tableName: "Errors", bundle: .main, value: "Файл конфигурации содержит некорректное имя папки.", comment: "")
        }
    }
}
