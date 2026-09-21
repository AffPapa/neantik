import Darwin
import Foundation

enum ProfileArtifactInventoryStatus: Equatable, Sendable {
    case empty
    case available(count: Int, bytes: Int64)
    case unavailable

    var title: String {
        switch self {
        case .empty:
            "Нет объектов"
        case let .available(count, bytes):
            String(count) + " · " + ByteCountFormatter.string(
                fromByteCount: bytes,
                countStyle: .file
            )
        case .unavailable:
            "Проверка недоступна"
        }
    }
}

enum ProfileArtifactQuarantinePolicy: String, Equatable, Sendable {
    case explicitManagerActionOnly

    var title: String {
        switch self {
        case .explicitManagerActionOnly:
            "Только по явному действию"
        }
    }
}

struct ProfileArtifactProvenanceSnapshot: Equatable, Sendable {
    static let empty = Self(
        downloads: .empty,
        extensions: .empty,
        quarantine: .empty,
        quarantinePolicy: .explicitManagerActionOnly
    )

    let downloads: ProfileArtifactInventoryStatus
    let extensions: ProfileArtifactInventoryStatus
    let quarantine: ProfileArtifactInventoryStatus
    let quarantinePolicy: ProfileArtifactQuarantinePolicy

    static func inspect(
        profileID: UUID,
        paths: AppPaths,
        fileManager: FileManager = .default
    ) -> Self {
        let browserData = paths.browserDataDirectory(for: profileID)
        return Self(
            downloads: inventory(
                at: browserData.appendingPathComponent(
                    "Downloads",
                    isDirectory: true
                ),
                fileManager: fileManager
            ),
            extensions: inventory(
                at: browserData
                    .appendingPathComponent("Default", isDirectory: true)
                    .appendingPathComponent("Extensions", isDirectory: true),
                fileManager: fileManager
            ),
            quarantine: inventory(
                at: browserData.appendingPathComponent(
                    "Quarantine",
                    isDirectory: true
                ),
                fileManager: fileManager
            ),
            quarantinePolicy: .explicitManagerActionOnly
        )
    }

    private static func inventory(
        at directory: URL,
        fileManager: FileManager
    ) -> ProfileArtifactInventoryStatus {
        guard fileManager.fileExists(atPath: directory.path) else {
            return .empty
        }
        do {
            guard try ProfileArtifactPathSafety.isDirectoryWithoutSymlink(
                directory
            ) else {
                return .unavailable
            }
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else {
                return .unavailable
            }
            var budget = ProfileManagerScanBudget(
                maximumEntries:
                    ProfileManagerPerformanceBudgets.maximumArtifactScanEntries,
                maximumBytes:
                    ProfileManagerPerformanceBudgets
                        .maximumSynchronousScanBytes
            )
            var count = 0
            for case let entry as URL in enumerator {
                let values = try entry.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true,
                      values.isDirectory == true || values.isRegularFile == true
                else {
                    return .unavailable
                }
                let fileBytes = Int64(values.fileSize ?? 0)
                guard budget.consume(entryBytes: values.isRegularFile == true
                    ? fileBytes
                    : 0)
                else { return .unavailable }
                if values.isRegularFile == true {
                    count += 1
                }
            }
            return count == 0
                ? .empty
                : .available(count: count, bytes: budget.bytes)
        } catch {
            return .unavailable
        }
    }

}

enum ProfileArtifactQuarantine {
    static let quarantineDirectoryName = "Quarantine"

    @discardableResult
    static func moveToQuarantine(
        source: URL,
        profileID: UUID,
        paths: AppPaths,
        reason: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let browserData = paths.browserDataDirectory(for: profileID)
            .standardizedFileURL
        let source = source.standardizedFileURL
        let prefix = browserData.path.hasSuffix("/")
            ? browserData.path
            : browserData.path + "/"
        guard source.path.hasPrefix(prefix),
              source.path != browserData.path,
              try safeArtifactTree(source, fileManager: fileManager)
        else {
            throw ProfileArtifactQuarantineError.unsafeSource
        }

        let quarantine = browserData.appendingPathComponent(
            quarantineDirectoryName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: quarantine.path) {
            guard try ProfileArtifactPathSafety.isDirectoryWithoutSymlink(
                quarantine
            ) else {
                throw ProfileArtifactQuarantineError.unsafeSource
            }
        } else {
            try fileManager.createDirectory(
                at: quarantine,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let token = UUID().uuidString
        let destination = quarantine.appendingPathComponent(token)
        let relativePath = String(source.path.dropFirst(prefix.count))
        let metadataURL = quarantine.appendingPathComponent(token + ".json")
        let metadata = ProfileArtifactQuarantineMetadata(
            schemaVersion: 1,
            profileID: profileID,
            originalRelativePath: relativePath,
            reason: boundedReason(reason),
            movedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        try fileManager.moveItem(at: source, to: destination)
        do {
            try paths.writePrivateFile(
                encoder.encode(metadata),
                to: metadataURL
            )
        } catch {
            try? fileManager.moveItem(at: destination, to: source)
            throw error
        }
        return destination
    }

    private static func safeArtifactTree(
        _ source: URL,
        fileManager: FileManager
    ) throws -> Bool {
        var status = stat()
        let result = source.path.withCString { lstat($0, &status) }
        guard result == 0 else { return false }
        let type = status.st_mode & mode_t(S_IFMT)
        guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else {
            return false
        }
        guard type == mode_t(S_IFDIR) else { return true }
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return false
        }
        for case let entry as URL in enumerator {
            if try entry.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ).isSymbolicLink == true {
                return false
            }
        }
        return true
    }

    private static func boundedReason(_ reason: String) -> String {
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Требует проверки" }
        return String(clean.prefix(256))
    }
}

private enum ProfileArtifactPathSafety {
    static func isDirectoryWithoutSymlink(_ url: URL) throws -> Bool {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        guard result == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }
}

private struct ProfileArtifactQuarantineMetadata: Codable, Equatable {
    let schemaVersion: Int
    let profileID: UUID
    let originalRelativePath: String
    let reason: String
    let movedAt: Date
}

enum ProfileArtifactQuarantineError: LocalizedError, Equatable {
    case unsafeSource

    var errorDescription: String? {
        switch self {
        case .unsafeSource:
            "Файл нельзя безопасно переместить в карантин. Данные не изменены."
        }
    }
}
