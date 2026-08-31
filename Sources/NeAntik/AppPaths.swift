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

/// A process-wide advisory lock that may intentionally span an async task.
///
/// The descriptor stays locked until `release()` (or deinit), which lets the
/// bulk-import credential journal remain mutually exclusive with startup
/// cleanup without blocking the main actor on Keychain work.
final class PrivateFileGuardLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { return }
        _ = neantikFlock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        self.descriptor = nil
    }

    deinit {
        release()
    }
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

    var profileOrganizationFile: URL {
        rootDirectory.appendingPathComponent("profile-organization.json")
    }

    var profileOrganizationBackupFile: URL {
        rootDirectory.appendingPathComponent(
            "profile-organization.previous.json"
        )
    }

    var profilesRecoveryDirectory: URL {
        rootDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    var runtimePreferenceFile: URL {
        rootDirectory.appendingPathComponent("runtime.json")
    }

    var proxyHealthFile: URL {
        rootDirectory.appendingPathComponent("proxy-health.json")
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

    var bulkCredentialImportGuardFile: URL {
        processLocksDirectory.appendingPathComponent(
            "BulkCredentialImport.guard"
        )
    }

    var managerSessionsFile: URL {
        processLocksDirectory.appendingPathComponent("ManagerSessions.json")
    }

    var managerSessionsGuardFile: URL {
        processLocksDirectory.appendingPathComponent("ManagerSessions.guard")
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

    func profileCredentialStagingMarker(for id: UUID) -> URL {
        processLocksDirectory.appendingPathComponent(
            "\(id.uuidString).credentials-staged"
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

    func pendingCredentialStagingProfileIDs() throws -> [UUID] {
        try pendingProfileIDs(markerExtension: "credentials-staged")
    }

    private func pendingProfileIDs(
        markerExtension: String
    ) throws -> [UUID] {
        try validatePrivateDirectory(processLocksDirectory)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: processLocksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return candidates.compactMap { candidate in
            guard candidate.pathExtension == markerExtension else {
                return nil
            }
            let basename = candidate.deletingPathExtension()
                .lastPathComponent
            guard let profileID = UUID(uuidString: basename),
                  candidate.lastPathComponent ==
                    "\(profileID.uuidString).\(markerExtension)"
            else {
                return nil
            }
            return profileID
        }
        .sorted { $0.uuidString < $1.uuidString }
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

    func removeCredentialStagingMarker(for id: UUID) throws {
        try removePrivateMarker(profileCredentialStagingMarker(for: id))
    }

    private func removePrivateMarker(_ marker: URL) throws {
        switch try privateFileEntryKind(marker) {
        case .missing:
            return
        case .regular:
            let result = marker.path.withCString { Darwin.unlink($0) }
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
        // This hot path runs for every profile launch. Legacy log hardening is
        // intentionally kept in prepareBaseDirectories(), which runs during
        // manager startup, instead of re-enumerating every log here. The two
        // coordination parents are still created explicitly: launches must be
        // safe even when a caller constructs AppPaths before app startup.
        try createPrivateDirectory(rootDirectory)
        try createPrivateDirectory(profilesDirectory)
        try createPrivateDirectory(processLocksDirectory)
        try createPrivateDirectory(logsDirectory)
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

    /// Reads one private regular file through the descriptor that was actually
    /// opened. Path validation alone leaves a validate/open race where an
    /// unrelated local process can replace the entry between `lstat` and
    /// `Data(contentsOf:)`. `O_NOFOLLOW`, descriptor/path identity checks and
    /// a stable before/after stat make that replacement fail closed.
    func readPrivateFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes >= 0 else {
            throw POSIXError(.EINVAL)
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        defer { _ = Darwin.close(descriptor) }

        var openedBefore = stat()
        var pathBefore = stat()
        guard Darwin.fstat(descriptor, &openedBefore) == 0,
              url.path.withCString({ Darwin.lstat($0, &pathBefore) }) == 0,
              Self.isSamePrivateRegularFile(openedBefore, pathBefore),
              openedBefore.st_size >= 0,
              openedBefore.st_size <= off_t(maximumBytes)
        else {
            throw POSIXError(
                openedBefore.st_size > off_t(maximumBytes)
                    ? .EFBIG
                    : .ELOOP
            )
        }

        var data = Data()
        data.reserveCapacity(Int(openedBefore.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if count < 0 {
                guard errno == EINTR else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                continue
            }
            guard count > 0 else { break }
            guard data.count <= maximumBytes - count else {
                throw POSIXError(.EFBIG)
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var openedAfter = stat()
        var pathAfter = stat()
        guard Darwin.fstat(descriptor, &openedAfter) == 0,
              url.path.withCString({ Darwin.lstat($0, &pathAfter) }) == 0,
              Self.isSamePrivateRegularFile(openedAfter, pathAfter),
              openedBefore.st_dev == openedAfter.st_dev,
              openedBefore.st_ino == openedAfter.st_ino,
              openedBefore.st_size == openedAfter.st_size,
              openedBefore.st_mtimespec.tv_sec ==
                openedAfter.st_mtimespec.tv_sec,
              openedBefore.st_mtimespec.tv_nsec ==
                openedAfter.st_mtimespec.tv_nsec,
              openedBefore.st_ctimespec.tv_sec ==
                openedAfter.st_ctimespec.tv_sec,
              openedBefore.st_ctimespec.tv_nsec ==
                openedAfter.st_ctimespec.tv_nsec,
              data.count == Int(openedAfter.st_size)
        else {
            throw POSIXError(.EBUSY)
        }
        return data
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

    func withManagerSessionsGuard<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try withPrivateFileGuard(
            at: managerSessionsGuardFile,
            operation
        )
    }

    func acquireBulkCredentialImportGuard() throws -> PrivateFileGuardLease {
        try createPrivateDirectory(
            bulkCredentialImportGuardFile.deletingLastPathComponent()
        )
        let descriptor = bulkCredentialImportGuardFile.path.withCString {
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
        guard neantikFlock(descriptor, LOCK_EX) == 0 else {
            let lockError = errno
            _ = Darwin.close(descriptor)
            throw POSIXError(
                POSIXErrorCode(rawValue: lockError) ?? .EIO
            )
        }
        return PrivateFileGuardLease(descriptor: descriptor)
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

    func createPrivateDirectoryExclusively(_ url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        let result = url.path.withCString {
            Darwin.mkdir($0, mode_t(S_IRWXU))
        }
        guard result == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        do {
            try validatePrivateDirectory(url)
            guard chmod(url.path, mode_t(S_IRWXU)) == 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EACCES
                )
            }
        } catch {
            _ = url.path.withCString { Darwin.rmdir($0) }
            throw error
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

    private static func isSamePrivateRegularFile(
        _ opened: stat,
        _ path: stat
    ) -> Bool {
        (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
            (path.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
            opened.st_dev == path.st_dev &&
            opened.st_ino == path.st_ino &&
            opened.st_nlink == 1 &&
            path.st_nlink == 1
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
