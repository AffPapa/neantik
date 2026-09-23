import AppKit
import Foundation

/// A local, metadata-only restore point. It is deliberately not a browser
/// backup: BrowserData, cookies, notes, identity seeds and Keychain values
/// never enter this document. Restoring creates fresh profile identities.
struct ProfileSnapshotDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumProfileCount = ProfileConfigurationTransferDocument
        .maximumProfileCount

    let schemaVersion: Int
    let createdAt: Date
    let configuration: ProfileConfigurationTransferDocument

    init(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String],
        createdAt: Date = Date()
    ) throws {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProfileSnapshotError.invalidDate
        }
        guard !profiles.isEmpty else {
            throw ProfileSnapshotError.emptySnapshot
        }
        guard profiles.count <= Self.maximumProfileCount else {
            throw ProfileSnapshotError.tooManyProfiles
        }
        schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        configuration = try ProfileConfigurationTransferDocument(
            profiles: profiles,
            folderNameByProfileID: folderNameByProfileID,
            exportedAt: createdAt
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProfileSnapshotError.unsupportedSchema
        }
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProfileSnapshotError.invalidDate
        }
        let configuration = try container.decode(
            ProfileConfigurationTransferDocument.self,
            forKey: .configuration
        )
        guard !configuration.profiles.isEmpty else {
            throw ProfileSnapshotError.emptySnapshot
        }
        guard configuration.profiles.count <= Self.maximumProfileCount else {
            throw ProfileSnapshotError.tooManyProfiles
        }
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.configuration = configuration
    }

    func makeProfiles(now: Date = Date()) throws -> [BrowserProfile] {
        try configuration.makeProfiles(now: now)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case createdAt
        case configuration
    }
}

enum ProfileSnapshotError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema
    case invalidDate
    case emptySnapshot
    case tooManyProfiles
    case fileTooLarge
    case invalidFile
    case unsafeLocation

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            "Snapshot создан другой версией NeAntik."
        case .invalidDate:
            "Snapshot содержит некорректную дату."
        case .emptySnapshot:
            "Snapshot не содержит профилей."
        case .tooManyProfiles:
            "Snapshot содержит слишком много профилей."
        case .fileTooLarge:
            "Snapshot слишком большой."
        case .invalidFile:
            "Snapshot повреждён или имеет неподдерживаемый формат."
        case .unsafeLocation:
            "Snapshot находится вне защищённой папки NeAntik."
        }
    }
}

enum ProfileSnapshotStore {
    static let maximumSnapshots = 3
    static let maximumFileBytes = 16 * 1_024 * 1_024

    @discardableResult
    static func save(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String],
        paths: AppPaths,
        createdAt: Date = Date()
    ) throws -> URL {
        let document = try ProfileSnapshotDocument(
            profiles: profiles,
            folderNameByProfileID: folderNameByProfileID,
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumFileBytes else {
            throw ProfileSnapshotError.fileTooLarge
        }

        try paths.prepareBaseDirectories()
        let stamp = Int(createdAt.timeIntervalSince1970)
        let file = paths.profileSnapshotsDirectory.appendingPathComponent(
            "snapshot-" + String(stamp) + "-" + UUID().uuidString + ".json"
        )
        try paths.writePrivateFile(data, to: file)
        try prune(paths: paths)
        return file
    }

    static func document(
        from url: URL,
        paths: AppPaths
    ) throws -> ProfileSnapshotDocument {
        guard isInsideSnapshots(url, paths: paths) else {
            throw ProfileSnapshotError.unsafeLocation
        }
        try paths.validatePrivateFile(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumFileBytes {
            throw ProfileSnapshotError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumFileBytes else {
            throw ProfileSnapshotError.fileTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(
                ProfileSnapshotDocument.self,
                from: data
            )
        } catch let error as ProfileSnapshotError {
            throw error
        } catch let error as ProfileConfigurationTransferError {
            throw error
        } catch {
            throw ProfileSnapshotError.invalidFile
        }
    }

    static func restore(
        from url: URL,
        paths: AppPaths,
        now: Date = Date()
    ) throws -> [BrowserProfile] {
        try document(from: url, paths: paths).makeProfiles(now: now)
    }

    static func snapshots(paths: AppPaths) throws -> [URL] {
        try paths.prepareBaseDirectories()
        let urls = try FileManager.default.contentsOfDirectory(
            at: paths.profileSnapshotsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter {
                $0.pathExtension == "json" &&
                    $0.lastPathComponent.hasPrefix("snapshot-")
            }
            .map {
                try paths.validatePrivateFile($0)
                return $0
            }
            .sorted {
                // The filename contains the creation epoch and a UUID. This
                // remains deterministic on filesystems with coarse mtimes.
                return $0.lastPathComponent > $1.lastPathComponent
            }
    }

    private static func prune(paths: AppPaths) throws {
        let files = try snapshots(paths: paths)
        guard files.count > maximumSnapshots else { return }
        for file in files.dropFirst(maximumSnapshots) {
            try paths.validatePrivateFile(file)
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func isInsideSnapshots(_ url: URL, paths: AppPaths) -> Bool {
        let root = paths.profileSnapshotsDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(root + "/")
    }
}

@MainActor
enum ProfileSnapshotFileCoordinator {
    static func chooseSnapshot(paths: AppPaths) throws -> URL? {
        try paths.prepareBaseDirectories()
        let panel = NSOpenPanel()
        panel.title = "Восстановить локальный snapshot"
        panel.message =
            "Будут добавлены новые профили без BrowserData, cookies, identity и Keychain-секретов."
        panel.directoryURL = paths.profileSnapshotsDirectory
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        return url
    }
}
