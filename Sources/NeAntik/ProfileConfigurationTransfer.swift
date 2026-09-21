import Foundation

/// A portable, metadata-only profile configuration.
///
/// This format is deliberately not a backup of a browser profile. It excludes
/// BrowserData, cookies, local storage, notes, last-launch state, identity
/// seeds, fingerprint evidence and Keychain values. Import always creates new
/// profile IDs and a new browser identity so a configuration file cannot clone
/// a live session or silently reuse an identity.
struct ProfileConfigurationTransferDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumProfileCount = ProfileStorageLimits.maximumProfileCount

    let schemaVersion: Int
    let exportedAt: Date
    let profiles: [ProfileConfigurationTransferEntry]

    init(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String] = [:],
        exportedAt: Date = Date()
    ) throws {
        guard profiles.count <= Self.maximumProfileCount else {
            throw ProfileConfigurationTransferError.tooManyProfiles
        }
        guard exportedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProfileConfigurationTransferError.invalidDate
        }

        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.profiles = try profiles.map { profile in
            let folderName = folderNameByProfileID[profile.id]
            return try ProfileConfigurationTransferEntry(
                profile: profile,
                folderName: folderName
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exportedAt
        case profiles
    }

    private static func validateFolderNames(
        in profiles: [ProfileConfigurationTransferEntry]
    ) throws {
        for profile in profiles {
            guard let folderName = profile.folderName else { continue }
            guard let normalized = ProfileFolder.normalizedName(folderName),
                  normalized == folderName else {
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
    let proxy: ProxyConfiguration?
    let folderName: String?

    init(
        name: String,
        colorHex: String,
        symbolName: String,
        tags: [String],
        isPinned: Bool,
        isArchived: Bool,
        startURL: String,
        proxy: ProxyConfiguration?,
        folderName: String?
    ) {
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.tags = tags
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.startURL = startURL
        self.proxy = proxy
        self.folderName = folderName
    }

    init(
        profile: BrowserProfile,
        folderName: String?
    ) throws {
        guard let normalized = profile.normalizedForPersistence() else {
            throw ProfileConfigurationTransferError.invalidProfile
        }
        if let folderName,
           ProfileFolder.normalizedName(folderName) != folderName {
            throw ProfileConfigurationTransferError.invalidFolderName
        }
        name = normalized.name
        colorHex = normalized.colorHex
        symbolName = normalized.symbolName
        tags = normalized.tags
        isPinned = normalized.isPinned
        isArchived = normalized.isArchived
        startURL = normalized.startURL
        proxy = normalized.proxy
        self.folderName = folderName
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
            "Файл конфигурации создан другой версией NeAntik."
        case .invalidDate:
            "Файл конфигурации содержит некорректную дату."
        case .emptyDocument:
            "Файл конфигурации не содержит профилей."
        case .tooManyProfiles:
            "Файл конфигурации содержит слишком много профилей."
        case .invalidProfile:
            "Файл конфигурации содержит некорректные параметры профиля."
        case .invalidFolderName:
            "Файл конфигурации содержит некорректное имя папки."
        }
    }
}
