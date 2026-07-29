import Darwin
import Foundation

@_silgen_name("flock")
private func neantikFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum PrivateFileEntryKind: Equatable, Sendable {
    case missing
    case regular
    case unsafe
}

struct PrivateFileEntryIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
}

struct AppPaths: Sendable {
    let rootDirectory: URL
    let migrationWarning: String?

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
            self.migrationWarning = nil
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
            let resolution = Self.resolveRoot(
                applicationSupportDirectory: applicationSupport,
                fileManager: .default
            )
            self.rootDirectory = resolution.root
            self.migrationWarning = resolution.warning
        }
    }

    init(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default,
        moveLegacy: ((URL, URL) throws -> Void)? = nil
    ) {
        let resolution = Self.resolveRoot(
            applicationSupportDirectory: applicationSupportDirectory,
            fileManager: fileManager,
            moveLegacy: moveLegacy
        )
        rootDirectory = resolution.root
        migrationWarning = resolution.warning
    }

    var profilesFile: URL {
        rootDirectory.appendingPathComponent("profiles.json")
    }

    var profilesBackupFile: URL {
        rootDirectory.appendingPathComponent("profiles.previous.json")
    }

    var profilesRecoveryDirectory: URL {
        rootDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    var runtimePreferenceFile: URL {
        rootDirectory.appendingPathComponent("runtime.json")
    }

    var profilesDirectory: URL {
        rootDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    var logsDirectory: URL {
        rootDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    var processLocksDirectory: URL {
        rootDirectory.appendingPathComponent("ProcessLocks", isDirectory: true)
    }

    var fingerprintAuditsDirectory: URL {
        rootDirectory.appendingPathComponent(
            "FingerprintAudits",
            isDirectory: true
        )
    }

    func profileDirectory(for id: UUID) -> URL {
        profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func browserDataDirectory(for id: UUID) -> URL {
        profileDirectory(for: id).appendingPathComponent("BrowserData", isDirectory: true)
    }

    func lockFile(for id: UUID) -> URL {
        profileDirectory(for: id).appendingPathComponent(".neantik.lock")
    }

    func lockGuardFile(for id: UUID) -> URL {
        processLocksDirectory.appendingPathComponent(
            "\(id.uuidString).guard"
        )
    }

    var profilesMetadataGuardFile: URL {
        processLocksDirectory.appendingPathComponent(
            "ProfilesMetadata.guard"
        )
    }

    func profileDeletionTombstone(for id: UUID) -> URL {
        processLocksDirectory.appendingPathComponent(
            "\(id.uuidString).deleted"
        )
    }

    func profileCredentialCleanupMarker(for id: UUID) -> URL {
        processLocksDirectory.appendingPathComponent(
            "\(id.uuidString).credentials-pending"
        )
    }

    func pendingCredentialCleanupProfileIDs() throws -> [UUID] {
        try validatePrivateDirectory(processLocksDirectory)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: processLocksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var profileIDs: [UUID] = []
        for candidate in candidates {
            guard candidate.pathExtension == "credentials-pending" else {
                continue
            }
            let basename = candidate.deletingPathExtension()
                .lastPathComponent
            guard let profileID = UUID(uuidString: basename),
                  candidate.lastPathComponent ==
                    "\(profileID.uuidString).credentials-pending"
            else {
                continue
            }
            profileIDs.append(profileID)
        }
        return profileIDs.sorted {
            $0.uuidString < $1.uuidString
        }
    }

    func removeCredentialCleanupMarker(for id: UUID) throws {
        let marker = profileCredentialCleanupMarker(for: id)
        switch try privateFileEntryKind(marker) {
        case .missing:
            return
        case .regular:
            let result = marker.path.withCString {
                Darwin.unlink($0)
            }
            guard result == 0 || errno == ENOENT else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
        case .unsafe:
            throw POSIXError(.EFTYPE)
        }
    }

    func logFile(for id: UUID) -> URL {
        logsDirectory.appendingPathComponent(
            "\(id.uuidString).manager.log"
        )
    }

    func prepareBaseDirectories() throws {
        try createPrivateDirectory(rootDirectory)
        try createPrivateDirectory(profilesDirectory)
        try createPrivateDirectory(processLocksDirectory)
        try createPrivateDirectory(logsDirectory)
        try createPrivateDirectory(fingerprintAuditsDirectory)
        try createPrivateDirectory(profilesRecoveryDirectory)
        try hardenExistingLogs()
    }

    func prepareProfileDirectories(for id: UUID) throws {
        try prepareBaseDirectories()
        try createPrivateDirectory(profileDirectory(for: id))
        try createPrivateDirectory(browserDataDirectory(for: id))
    }

    func writePrivateFile(_ data: Data, to url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        try validatePrivateFile(url)
        try data.write(to: url, options: .atomic)
        try validatePrivateFile(url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    func createPrivateFileExclusively(_ data: Data, at url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        var completed = false
        defer {
            _ = Darwin.close(descriptor)
            if !completed {
                _ = url.path.withCString { Darwin.unlink($0) }
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else {
                return
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                guard written > 0 else {
                    throw POSIXError(.EIO)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        completed = true
    }

    func withProcessLockGuard<T>(
        for id: UUID,
        _ operation: () throws -> T
    ) throws -> T {
        try withPrivateFileGuard(
            at: lockGuardFile(for: id),
            operation
        )
    }

    func withProfilesMetadataGuard<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try withPrivateFileGuard(
            at: profilesMetadataGuardFile,
            operation
        )
    }

    private func withPrivateFileGuard<T>(
        at guardURL: URL,
        _ operation: () throws -> T
    ) throws -> T {
        try createPrivateDirectory(guardURL.deletingLastPathComponent())
        let descriptor = guardURL.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        defer { _ = Darwin.close(descriptor) }

        while neantikFlock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
        }
        defer { _ = neantikFlock(descriptor, LOCK_UN) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        var pathStatus = stat()
        let pathResult = guardURL.path.withCString {
            Darwin.lstat($0, &pathStatus)
        }
        guard pathResult == 0,
              (openedStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (pathStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              openedStatus.st_nlink == 1
        else {
            throw POSIXError(.ELOOP)
        }
        guard Darwin.fchmod(
            descriptor,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EACCES
            )
        }
        return try operation()
    }

    func privateFileEntryKind(_ url: URL) throws -> PrivateFileEntryKind {
        guard let status = try fileStatus(at: url) else {
            return .missing
        }
        let type = status.st_mode & mode_t(S_IFMT)
        return type == mode_t(S_IFREG) ? .regular : .unsafe
    }

    func privateFileEntryIdentity(
        _ url: URL
    ) throws -> PrivateFileEntryIdentity? {
        guard let status = try fileStatus(at: url) else {
            return nil
        }
        return PrivateFileEntryIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            mode: status.st_mode,
            size: status.st_size,
            modificationSeconds: status.st_mtimespec.tv_sec,
            modificationNanoseconds: status.st_mtimespec.tv_nsec
        )
    }

    func validatePrivateDirectory(_ url: URL) throws {
        guard let status = try fileStatus(at: url) else {
            throw POSIXError(.ENOENT)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw POSIXError(
                (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
                    ? .ELOOP
                    : .ENOTDIR
            )
        }
    }

    func validatePrivateFile(_ url: URL) throws {
        guard let status = try fileStatus(at: url) else {
            return
        }
        let type = status.st_mode & mode_t(S_IFMT)
        guard type != mode_t(S_IFLNK) else {
            throw POSIXError(.ELOOP)
        }
        guard type == mode_t(S_IFREG) else {
            throw POSIXError(.EFTYPE)
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        if let status = try fileStatus(at: url) {
            let type = status.st_mode & mode_t(S_IFMT)
            guard type != mode_t(S_IFLNK) else {
                throw POSIXError(.ELOOP)
            }
            guard type == mode_t(S_IFDIR) else {
                throw POSIXError(.ENOTDIR)
            }
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validatePrivateDirectory(url)
        guard chmod(url.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
    }

    private func hardenExistingLogs() throws {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let files = try FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        for file in files {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                continue
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
        }
    }

    private func fileStatus(at url: URL) throws -> stat? {
        var value = stat()
        let result = url.path.withCString {
            lstat($0, &value)
        }
        if result == 0 {
            return value
        }
        guard errno == ENOENT else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return nil
    }

    private struct RootResolution {
        let root: URL
        let warning: String?
    }

    private static func resolveRoot(
        applicationSupportDirectory: URL,
        fileManager: FileManager,
        moveLegacy: ((URL, URL) throws -> Void)? = nil
    ) -> RootResolution {
        let currentRoot = applicationSupportDirectory.appendingPathComponent(
            "NeAntik",
            isDirectory: true
        )
        let legacyRoot = applicationSupportDirectory.appendingPathComponent(
            ["Ne", "Vision"].joined(),
            isDirectory: true
        )
        let currentProfiles = currentRoot.appendingPathComponent("profiles.json")
        let legacyProfiles = legacyRoot.appendingPathComponent("profiles.json")
        let currentIsDirectory = isDirectory(currentRoot, fileManager: fileManager)
        let legacyIsDirectory = isDirectory(legacyRoot, fileManager: fileManager)
        let currentHasProfiles = fileManager.fileExists(
            atPath: currentProfiles.path
        )
        let legacyHasProfiles = fileManager.fileExists(
            atPath: legacyProfiles.path
        )

        if !currentIsDirectory, legacyIsDirectory {
            do {
                if let moveLegacy {
                    try moveLegacy(legacyRoot, currentRoot)
                } else {
                    try fileManager.moveItem(
                        at: legacyRoot,
                        to: currentRoot
                    )
                }
                return RootResolution(root: currentRoot, warning: nil)
            } catch {
                return RootResolution(
                    root: legacyRoot,
                    warning:
                        "Не удалось перенести старые профили в папку NeAntik. Они безопасно открыты из прежней папки; данные не потеряны."
                )
            }
        }

        if currentIsDirectory, legacyIsDirectory {
            if !currentHasProfiles, legacyHasProfiles {
                return RootResolution(
                    root: legacyRoot,
                    warning:
                        "Найдены две папки данных. NeAntik открыл прежнюю папку с профилями и ничего не перезаписал."
                )
            }
            if currentHasProfiles, legacyHasProfiles {
                return RootResolution(
                    root: currentRoot,
                    warning:
                        "Найдена отдельная прежняя папка с профилями. NeAntik не объединяет такие данные автоматически, чтобы не повредить сессии."
                )
            }
        }

        return RootResolution(root: currentRoot, warning: nil)
    }

    private static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var value = ObjCBool(false)
        return fileManager.fileExists(
            atPath: url.path,
            isDirectory: &value
        ) && value.boolValue
    }
}
