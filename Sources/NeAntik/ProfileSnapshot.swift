import AppKit
import Foundation
import Darwin

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
        createdAt: Date = Date(),
        afterWrite: () throws -> Void = {}
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

        return try paths.withSnapshotsGuard {
            try Task.checkCancellation()
            try paths.prepareBaseDirectories()
            // Refuse an unsafe existing entry before publishing a new file.
            // Otherwise a failed retention scan leaves an unreported snapshot.
            _ = try snapshots(paths: paths)
            let stamp = Int(createdAt.timeIntervalSince1970)
            let file = paths.profileSnapshotsDirectory.appendingPathComponent(
                "snapshot-" + String(stamp) + "-" + UUID().uuidString + ".json"
            )
            // Cancellation is honored before the durable write. Once the
            // file exists, finish retention and report the committed save.
            try Task.checkCancellation()
            try paths.writePrivateFile(data, to: file)
            do {
                try afterWrite()
                try prune(paths: paths, preserving: file)
            } catch {
                let rolledBack: Bool
                do {
                    if FileManager.default.fileExists(atPath: file.path) {
                        try FileManager.default.removeItem(at: file)
                    }
                    rolledBack = true
                } catch {
                    rolledBack = false
                }
                throw ProfileSnapshotCommitError(rolledBack: rolledBack)
            }
            return file
        }
    }

    static func document(
        from url: URL,
        paths: AppPaths,
        afterFileOpened: () throws -> Void = {}
    ) throws -> ProfileSnapshotDocument {
        guard isInsideSnapshots(url, paths: paths) else {
            throw ProfileSnapshotError.unsafeLocation
        }
        let data = try readSnapshot(
            from: url, paths: paths, afterFileOpened: afterFileOpened
        )
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

    /// Anchor each directory with no-follow descriptors. A final-file lstat
    /// alone cannot protect against a replaced parent or a growing input.
    private static func readSnapshot(
        from url: URL,
        paths: AppPaths,
        afterFileOpened: () throws -> Void
    ) throws -> Data {
        try Task.checkCancellation()
        // Darwin's fixed system aliases are allowed; application-controlled
        // components below them are opened one by one without symlink traversal.
        var directoryPath = paths.profileSnapshotsDirectory.standardizedFileURL.path
        if directoryPath.hasPrefix("/var/") {
            directoryPath = "/private" + directoryPath
        } else if directoryPath.hasPrefix("/tmp/") {
            directoryPath = "/private" + directoryPath
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ProfileSnapshotError.invalidFile }
        defer { _ = Darwin.close(directory) }
        for component in directoryPath.split(separator: "/") {
            let next = String(component).withCString {
                Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw ProfileSnapshotError.invalidFile }
            _ = Darwin.close(directory)
            directory = next
        }
        var directoryInfo = stat()
        guard Darwin.fstat(directory, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & mode_t(0o077) == 0 else {
            throw ProfileSnapshotError.invalidFile
        }
        let file = url.lastPathComponent.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard file >= 0 else { throw ProfileSnapshotError.invalidFile }
        defer { _ = Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size >= 0 else { throw ProfileSnapshotError.invalidFile }
        guard before.st_size <= maximumFileBytes else { throw ProfileSnapshotError.fileTooLarge }
        try afterFileOpened()
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= maximumFileBytes {
            try Task.checkCancellation()
            let capacity = min(buffer.count, maximumFileBytes + 1 - data.count)
            let count = Darwin.read(file, &buffer, capacity)
            if count < 0 {
                if errno == EINTR { continue }
                throw ProfileSnapshotError.invalidFile
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumFileBytes else { throw ProfileSnapshotError.fileTooLarge }
        var after = stat()
        guard Darwin.fstat(file, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_nlink == after.st_nlink,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == before.st_size else { throw ProfileSnapshotError.invalidFile }
        return data
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

    private static func prune(paths: AppPaths, preserving saved: URL) throws {
        let files = try snapshots(paths: paths)
        guard files.count > maximumSnapshots else { return }
        // A wall-clock correction must not make a successful save return a URL
        // that retention immediately removed.
        let retained = Set(
            Array(files.filter { $0.lastPathComponent != saved.lastPathComponent }
                .prefix(maximumSnapshots - 1)).map(\.lastPathComponent) +
                [saved.lastPathComponent]
        )
        for file in files where !retained.contains(file.lastPathComponent) {
            try paths.validatePrivateFile(file)
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func isInsideSnapshots(_ url: URL, paths: AppPaths) -> Bool {
        guard url.isFileURL, paths.rootDirectory.isFileURL else { return false }
        let root = paths.profileSnapshotsDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL
        return candidate.deletingLastPathComponent().path == root &&
            candidate.pathExtension == "json" &&
            candidate.lastPathComponent.hasPrefix("snapshot-")
    }
}

struct ProfileSnapshotCommitError: LocalizedError {
    let rolledBack: Bool

    var errorDescription: String? {
        rolledBack
            ? "Snapshot не сохранён; новый файл удалён. Предыдущие версии проверь в списке snapshots."
            : "Snapshot не завершён, и новый файл не удалось удалить. Проверь локальную папку snapshots перед повтором."
    }
}

@MainActor
enum ProfileSnapshotFileCoordinator {
    static func chooseSnapshot(paths: AppPaths) throws -> URL? {
        try paths.prepareBaseDirectories()
        let panel = NSOpenPanel()
        panel.title = "Создать профили из снимка настроек"
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
