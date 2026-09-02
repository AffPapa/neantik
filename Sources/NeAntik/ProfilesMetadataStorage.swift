import Darwin
import Foundation

/// Owns the versioned profiles document and its recovery transaction so the
/// observable store remains focused on in-memory profile mutations.
enum ProfilesMetadataStorage {
    static let maximumBytes = 128 * 1_024 * 1_024

    struct LoadResult {
        let profiles: [BrowserProfile]
        let warning: String?
        let requiresMigration: Bool
    }

    private struct Document: Codable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let profiles: [BrowserProfile]

        init(profiles: [BrowserProfile]) {
            schemaVersion = Self.currentSchemaVersion
            self.profiles = profiles
        }
    }

    private struct DocumentHeader: Decodable {
        let schemaVersion: Int
    }

    private enum DocumentError: LocalizedError {
        case unsupportedSchema
        case documentTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema:
                "Версия файла профилей не поддерживается этой версией NeAntik. Данные не изменены."
            case .documentTooLarge:
                "Метаданные профилей превысили безопасный лимит 128 МБ. Уменьши объём заметок, адресов или тегов; существующий файл не изменён."
            }
        }
    }

    static func persist(
        _ profiles: [BrowserProfile],
        paths: AppPaths,
        synchronizeRecoverySnapshot: Bool
    ) throws {
        let data = try encode(profiles)
        if synchronizeRecoverySnapshot {
            try paths.writePrivateFile(data, to: paths.profilesBackupFile)
            try paths.writePrivateFile(data, to: paths.profilesFile)
            return
        }
        if FileManager.default.fileExists(atPath: paths.profilesFile.path) {
            try paths.validatePrivateFile(paths.profilesFile)
            let previousData = try paths.readPrivateFile(
                paths.profilesFile,
                maximumBytes: maximumBytes
            )
            _ = try decode(previousData)
            try paths.writePrivateFile(
                previousData,
                to: paths.profilesBackupFile
            )
        } else {
            try paths.writePrivateFile(data, to: paths.profilesBackupFile)
        }
        try paths.writePrivateFile(data, to: paths.profilesFile)
    }

    static func ensureRecoverySnapshotIfNeeded(paths: AppPaths) throws {
        guard FileManager.default.fileExists(
            atPath: paths.profilesFile.path
        ) else {
            return
        }
        if FileManager.default.fileExists(
            atPath: paths.profilesBackupFile.path
        ) {
            try paths.validatePrivateFile(paths.profilesBackupFile)
            return
        }
        try paths.validatePrivateFile(paths.profilesFile)
        let data = try paths.readPrivateFile(
            paths.profilesFile,
            maximumBytes: maximumBytes
        )
        try paths.writePrivateFile(data, to: paths.profilesBackupFile)
    }

    static func readWithRecovery(paths: AppPaths) throws -> LoadResult {
        // Every caller, including mutation reloads, must fail before reading if
        // another process replaced metadata with a symlink or non-regular
        // entry. The metadata guard coordinates NeAntik instances; this check
        // also protects against unrelated local path replacement.
        try paths.validatePrivateFile(paths.profilesFile)
        do {
            let load = try read(paths: paths)
            return LoadResult(
                profiles: load.profiles,
                warning: nil,
                requiresMigration: load.requiresMigration
            )
        } catch is DecodingError {
            try paths.validatePrivateFile(paths.profilesFile)
            try paths.validatePrivateFile(paths.profilesBackupFile)
            let backupData = try paths.readPrivateFile(
                paths.profilesBackupFile,
                maximumBytes: maximumBytes
            )
            let recovered = try decode(backupData)
            let rejectedData = try paths.readPrivateFile(
                paths.profilesFile,
                maximumBytes: maximumBytes
            )
            let rejectedURL: URL?
            if ProfileRecoveryRetention.shouldPreserveRejectedFile(
                byteCount: rejectedData.count
            ) {
                let candidate = paths.profilesRecoveryDirectory
                    .appendingPathComponent(
                        "profiles-rejected-\(UUID().uuidString).json"
                    )
                try paths.writePrivateFile(rejectedData, to: candidate)
                rejectedURL = candidate
            } else {
                rejectedURL = nil
            }
            try paths.writePrivateFile(backupData, to: paths.profilesFile)
            try? ProfileRecoveryRetention.prune(
                directory: paths.profilesRecoveryDirectory,
                preserving: rejectedURL
            )
            return LoadResult(
                profiles: recovered.profiles,
                warning: rejectedURL == nil
                    ? "NeAntik восстановил предыдущую локальную версию профилей. Повреждённый файл превышал безопасный лимит Recovery и не сохранялся; данные браузеров не изменялись."
                    : "Повреждённый файл профилей сохранён в папке Recovery. NeAntik восстановил предыдущую локальную версию; данные браузеров не изменялись.",
                requiresMigration: recovered.requiresMigration
            )
        }
    }

    private static func encode(_ profiles: [BrowserProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Document(profiles: profiles))
        guard encodedByteCountIsAllowed(data.count) else {
            throw DocumentError.documentTooLarge
        }
        return data
    }

    static func encodedByteCountIsAllowed(_ byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maximumBytes
    }

    private static func read(
        paths: AppPaths
    ) throws -> (profiles: [BrowserProfile], requiresMigration: Bool) {
        guard FileManager.default.fileExists(
            atPath: paths.profilesFile.path
        ) else { return ([], false) }
        return try decode(
            paths.readPrivateFile(
                paths.profilesFile,
                maximumBytes: maximumBytes
            )
        )
    }

    private static func decode(
        _ data: Data
    ) throws -> (profiles: [BrowserProfile], requiresMigration: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let header = try decoder.decode(DocumentHeader.self, from: data)
            guard header.schemaVersion == Document.currentSchemaVersion else {
                throw DocumentError.unsupportedSchema
            }
            let document = try decoder.decode(Document.self, from: data)
            return (document.profiles, false)
        } catch let error as DocumentError {
            throw error
        } catch {
            return (
                try decoder.decode([BrowserProfile].self, from: data),
                true
            )
        }
    }
}

/// Bounds automatically-created Recovery diagnostics without inspecting or
/// deleting unrelated user files.
enum ProfileRecoveryRetention {
    static let maximumFileCount = 8
    static let maximumTotalBytes: Int64 = 32 * 1_024 * 1_024
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    static func shouldPreserveRejectedFile(byteCount: Int) -> Bool {
        byteCount >= 0 && Int64(byteCount) <= maximumTotalBytes
    }

    private struct Candidate {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let modifiedAt: Date
    }

    static func prune(
        directory: URL,
        preserving preservedURL: URL? = nil,
        now: Date = Date()
    ) throws {
        let preservedPath = preservedURL?.standardizedFileURL.path
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let candidates = entries.compactMap { url -> Candidate? in
            guard isManagedRecoveryFilename(url.lastPathComponent) else {
                return nil
            }
            var status = stat()
            guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  status.st_nlink == 1,
                  status.st_size >= 0
            else {
                return nil
            }
            return Candidate(
                url: url,
                device: status.st_dev,
                inode: status.st_ino,
                size: Int64(status.st_size),
                modifiedAt: Date(
                    timeIntervalSince1970:
                        TimeInterval(status.st_mtimespec.tv_sec) +
                        TimeInterval(status.st_mtimespec.tv_nsec) /
                            1_000_000_000
                )
            )
        }.sorted {
            let lhsPreserved = $0.url.standardizedFileURL.path == preservedPath
            let rhsPreserved = $1.url.standardizedFileURL.path == preservedPath
            if lhsPreserved != rhsPreserved {
                return lhsPreserved
            }
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }

        var retainedCount = 0
        var retainedBytes: Int64 = 0
        for candidate in candidates {
            let isPreserved = candidate.url.standardizedFileURL.path ==
                preservedPath
            let age = now.timeIntervalSince(candidate.modifiedAt)
            let isFresh = age >= -5 * 60 && age <= maximumAge
            let fitsCount = retainedCount < maximumFileCount
            let fitsBytes = candidate.size <=
                maximumTotalBytes - min(retainedBytes, maximumTotalBytes)
            let canPreserve = isPreserved &&
                candidate.size <= maximumTotalBytes
            if canPreserve || (isFresh && fitsCount && fitsBytes) {
                retainedCount += 1
                retainedBytes = min(
                    maximumTotalBytes,
                    retainedBytes + candidate.size
                )
                continue
            }
            try removeIfUnchanged(candidate)
        }
    }

    private static func isManagedRecoveryFilename(_ name: String) -> Bool {
        for prefix in [
            "profiles-rejected-",
            "profile-organization-rejected-",
        ] where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -".json".count)
            let token = String(name[start..<end])
            if let id = UUID(uuidString: token), id.uuidString == token {
                return true
            }
        }
        return false
    }

    private static func removeIfUnchanged(_ candidate: Candidate) throws {
        var current = stat()
        guard candidate.url.path.withCString({
            Darwin.lstat($0, &current)
        }) == 0,
            current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            current.st_nlink == 1,
            current.st_dev == candidate.device,
            current.st_ino == candidate.inode,
            current.st_size == off_t(candidate.size)
        else {
            return
        }
        guard candidate.url.path.withCString({ Darwin.unlink($0) }) == 0 ||
                errno == ENOENT
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
