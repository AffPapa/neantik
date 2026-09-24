import Foundation

enum ProfileLifecycleLockStatus: Equatable, Sendable {
    case clear
    case managed
    case active
    case unavailable

    var title: String {
        switch self {
        case .clear:
            "Свободен"
        case .managed:
            "Запущен здесь"
        case .active:
            "Занят"
        case .unavailable:
            "Проверка недоступна"
        }
    }
}

enum ProfileLifecycleBrowserDataStatus: Equatable, Sendable {
    case missing
    case available(bytes: Int64, entries: Int)
    case unavailable

    var title: String {
        switch self {
        case .missing:
            "Не создан"
        case let .available(bytes, entries):
            ByteCountFormatter.string(
                fromByteCount: bytes,
                countStyle: .file
            ) + " · " + String(entries) + " объектов"
        case .unavailable:
            "Проверка недоступна"
        }
    }
}

enum ProfileLifecycleRecoveryStatus: Equatable, Sendable {
    case clear
    case required
    case unavailable

    var title: String {
        switch self {
        case .clear:
            "Не требуется"
        case .required:
            "Требуется внимание"
        case .unavailable:
            "Проверка недоступна"
        }
    }
}

struct ProfileLifecycleHealthSnapshot: Equatable, Sendable {
    static let empty = Self(
        lock: .unavailable,
        browserData: .unavailable,
        recovery: .unavailable,
        lastLaunchedAt: nil
    )

    let lock: ProfileLifecycleLockStatus
    let browserData: ProfileLifecycleBrowserDataStatus
    let recovery: ProfileLifecycleRecoveryStatus
    let lastLaunchedAt: Date?

    static func inspect(
        profileID: UUID,
        lastLaunchedAt: Date?,
        processState: BrowserProfileProcessState,
        paths: AppPaths,
        fileManager: FileManager = .default
    ) -> Self {
        Self(
            lock: inspectLock(
                profileID: profileID,
                processState: processState,
                paths: paths
            ),
            browserData: inspectBrowserData(
                profileID: profileID,
                paths: paths,
                fileManager: fileManager
            ),
            recovery: inspectRecovery(
                profileID: profileID,
                processState: processState,
                paths: paths,
                fileManager: fileManager
            ),
            lastLaunchedAt: lastLaunchedAt
        )
    }

    private static func inspectLock(
        profileID: UUID,
        processState: BrowserProfileProcessState,
        paths: AppPaths
    ) -> ProfileLifecycleLockStatus {
        do {
            switch try paths.privateFileEntryKind(paths.lockFile(for: profileID)) {
            case .missing:
                return processState.isRunning ? .unavailable : .clear
            case .regular:
                return processState == .managed ? .managed : .active
            case .unsafe:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    private static func inspectBrowserData(
        profileID: UUID,
        paths: AppPaths,
        fileManager: FileManager
    ) -> ProfileLifecycleBrowserDataStatus {
        let directory = paths.browserDataDirectory(for: profileID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return .missing
        }

        do {
            try paths.validatePrivateDirectory(directory)
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
                    ProfileManagerPerformanceBudgets
                        .maximumLifecycleScanEntries,
                maximumBytes:
                    ProfileManagerPerformanceBudgets
                        .maximumSynchronousScanBytes
            )
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
            }
            return .available(bytes: budget.bytes, entries: budget.entries)
        } catch {
            return .unavailable
        }
    }

    private static func inspectRecovery(
        profileID: UUID,
        processState: BrowserProfileProcessState,
        paths: AppPaths,
        fileManager: FileManager
    ) -> ProfileLifecycleRecoveryStatus {
        if processState == .recoveryRequired {
            return .required
        }
        do {
            switch try paths.privateFileEntryKind(
                paths.profileCredentialCleanupMarker(for: profileID)
            ) {
            case .regular:
                return .required
            case .unsafe:
                return .unavailable
            case .missing:
                break
            }
            try paths.validatePrivateDirectory(paths.profilesRecoveryDirectory)
            let entries = try fileManager.contentsOfDirectory(
                at: paths.profilesRecoveryDirectory,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
            for entry in entries {
                if try entry.resourceValues(
                    forKeys: [.isSymbolicLinkKey]
                ).isSymbolicLink == true {
                    return .unavailable
                }
            }
            // Preserved rejected metadata is workspace recovery history.
            // Active profile recovery is represented by process state or the
            // profile-specific credential cleanup marker above.
            return .clear
        } catch {
            return .unavailable
        }
    }
}
