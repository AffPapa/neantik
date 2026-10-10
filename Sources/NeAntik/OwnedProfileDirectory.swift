import Darwin
import Foundation

struct ProfileCreationOwnershipError: LocalizedError {
    var errorDescription: String? {
        "Каталог нового профиля изменился или содержит неожиданные данные. Он сохранён; автоматический откат остановлен."
    }
}
struct ProfileCreationDescriptorBudgetError: LocalizedError {
    var errorDescription: String? { "Недостаточно свободных файловых дескрипторов для создания профилей. Закрой лишние приложения или импортируй меньший пакет." }
}
struct ProfileCreationIncompleteError: LocalizedError {
    var errorDescription: String? { "Создание каталога профиля не завершено. Каталог мог сохраниться; NeAntik не удаляет его без подтверждения владения. Сохрани данные приложения и обратись в поддержку." }
}

/// Holds only the directories this creation actually made. Cleanup removes
/// known empty directories through retained descriptors; it never recursively
/// adopts a replacement or unexpected browser data. No automatic deletion in
/// deinit: ambiguous ownership must leave recoverable bytes behind.
final class OwnedProfileDirectory {
    /// Preflight the complete batch before the first mkdir. This does not
    /// reserve kernel resources against concurrent opens; unexpected failures
    /// after mkdir remain explicit incomplete-creation errors.
    static func requireDescriptorBudget(profileCount: Int, bookmarkProfileCount: Int = 0) throws {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { throw ProfileCreationDescriptorBudgetError() }
        let names = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        guard !names.isEmpty, names.count <= 65_536,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { throw ProfileCreationDescriptorBudgetError() }
        try validateDescriptorBudget(profileCount: profileCount, limit: UInt64(limit.rlim_cur), openDescriptors: names.count, bookmarkProfileCount: bookmarkProfileCount)
    }
    static func validateDescriptorBudget(profileCount: Int, limit: UInt64, openDescriptors: Int, bookmarkProfileCount: Int = 0) throws {
        guard profileCount > 0, openDescriptors >= 0, bookmarkProfileCount >= 0, bookmarkProfileCount <= profileCount else { throw ProfileCreationDescriptorBudgetError() }
        let (needed, multiplyOverflow) = UInt64(profileCount).multipliedReportingOverflow(by: 3)
        let (bookmarkNeeded, bookmarkOverflow) = UInt64(bookmarkProfileCount).multipliedReportingOverflow(by: 2)
        let (allNeeded, totalOverflow) = needed.addingReportingOverflow(bookmarkNeeded)
        let (withOpen, openOverflow) = allNeeded.addingReportingOverflow(UInt64(openDescriptors))
        let (withReserve, reserveOverflow) = withOpen.addingReportingOverflow(32)
        guard !multiplyOverflow, !bookmarkOverflow, !totalOverflow, !openOverflow, !reserveOverflow, withReserve <= limit else { throw ProfileCreationDescriptorBudgetError() }
    }
    private let parentURL: URL
    private let name: String
    private let parent: Int32
    private let directory: Int32
    private let parentIdentity: BackupIdentity
    private let directoryIdentity: BackupIdentity
    private var browser: Int32?
    private var browserIdentity: BackupIdentity?
    private var initialDefault: Int32?
    private var initialDefaultIdentity: BackupIdentity?
    private var initialBookmarkFile: Int32?
    private var initialBookmarkIdentity: BackupIdentity?
    private var initialBookmarkBytes: Data?

    init(paths: AppPaths, profileID: UUID) throws {
        parentURL = try Self.platformPath(paths.profilesDirectory); name = profileID.uuidString
        parent = try BackupFS.directory(parentURL)
        do {
            parentIdentity = try BackupFS.identity(parent)
            guard mkdirat(parent, name, 0o700) == 0 else { throw BackupFS.posix() }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ProfileCreationIncompleteError() }
            do {
                let identity = try BackupFS.identity(fd)
                guard identity.directory, identity.uid == geteuid(), identity.mode & 0o077 == 0,
                      try BackupFS.entry(parent, name)?.sameObject(identity) == true else { throw ProfileCreationOwnershipError() }
                directory = fd; directoryIdentity = identity
            } catch { Darwin.close(fd); throw error }
        } catch { Darwin.close(parent); throw error }
    }

    func prepareBrowserData() throws {
        try validate()
        guard browser == nil, mkdirat(directory, "BrowserData", 0o700) == 0 else { throw BackupFS.posix() }
        let fd = openat(directory, "BrowserData", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BackupFS.posix() }
        do {
            let identity = try BackupFS.identity(fd)
            guard identity.directory, identity.uid == geteuid(), identity.mode & 0o077 == 0,
                  try BackupFS.entry(directory, "BrowserData")?.sameObject(identity) == true else { throw ProfileCreationOwnershipError() }
            browser = fd; browserIdentity = identity
            try validate()
        } catch { if browser == nil { Darwin.close(fd) }; throw error }
    }

    private func validate() throws {
        try BackupFS.validateDirectoryPath(parentURL, parentIdentity)
        guard try Self.privateDirectoryIdentity(parent).sameObject(parentIdentity),
              try Self.privateDirectoryIdentity(directory).sameObject(directoryIdentity),
              try BackupFS.entry(parent, name)?.sameObject(directoryIdentity) == true else { throw ProfileCreationOwnershipError() }
    }

    private static func privateDirectoryIdentity(_ fd: Int32) throws -> BackupIdentity {
        let value = try BackupFS.identity(fd)
        guard value.directory, value.uid == geteuid(), value.mode & 0o077 == 0 else { throw ProfileCreationOwnershipError() }
        return value
    }

    /// Called only for a fresh profile before metadata publication. A typed,
    /// validated import document prevents arbitrary path/content injection.
    func prepareInitialBookmarks(_ document: BookmarkImportDocument) throws {
        let bytes = try document.chromiumBytes()
        try validatePreparedInitialState()
        guard let browser, initialDefault == nil, mkdirat(browser, "Default", 0o700) == 0 else { throw BackupFS.posix() }
        let fd = openat(browser, "Default", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProfileCreationIncompleteError() }
        initialDefault = fd; initialDefaultIdentity = try BackupFS.identity(fd)
        let file = openat(fd, "Bookmarks", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw BackupFS.posix() }
        initialBookmarkFile = file; initialBookmarkIdentity = try BackupFS.identity(file); initialBookmarkBytes = Data()
        // Partial failed writes are retained if their exact content cannot be
        // proved; cleanup never adopts arbitrary bytes merely by inode.
        var offset = 0
        while offset < bytes.count {
            let chunk = Data(bytes[offset..<min(offset + 65_536, bytes.count)])
            try BackupFS.write(file, chunk, at: Int64(offset))
            initialBookmarkBytes!.append(chunk); offset += chunk.count
        }
        guard fsync(file) == 0, fsync(fd) == 0, fsync(browser) == 0, fsync(directory) == 0 else { throw BackupFS.posix() }
        try validatePreparedInitialState()
    }

    func validatePreparedInitialState() throws {
        try validate()
        guard let browser, let browserIdentity, try Self.privateDirectoryIdentity(browser).sameObject(browserIdentity),
              try BackupFS.entry(directory, "BrowserData")?.sameObject(browserIdentity) == true else { throw ProfileCreationOwnershipError() }
        guard let initialDefault else {
            guard try BackupFS.names(browser).isEmpty else { throw ProfileCreationOwnershipError() }
            return
        }
        guard let initialDefaultIdentity, let file = initialBookmarkFile, let identity = initialBookmarkIdentity, let bytes = initialBookmarkBytes,
              try Self.privateDirectoryIdentity(initialDefault).sameObject(initialDefaultIdentity),
              try BackupFS.entry(browser, "Default")?.sameObject(initialDefaultIdentity) == true,
              try BackupFS.names(browser) == ["Default"], try BackupFS.names(initialDefault) == ["Bookmarks"],
              try BackupFS.identity(file).sameObject(identity),
              try BackupFS.entry(initialDefault, "Bookmarks")?.sameObject(identity) == true else { throw ProfileCreationOwnershipError() }
        var value = stat()
        guard fstat(file, &value) == 0, value.st_uid == geteuid(), value.st_nlink == 1, value.st_mode & 0o170000 == 0o100000,
              value.st_mode & 0o077 == 0, value.st_size == bytes.count else { throw ProfileCreationOwnershipError() }
        var offset = 0
        while offset < bytes.count {
            let count = min(65_536, bytes.count - offset)
            guard try BackupFS.read(file, at: Int64(offset), count: count, checksCancellation: false) == bytes[offset..<offset + count] else { throw ProfileCreationOwnershipError() }
            offset += count
        }
    }

    /// Normalize only Darwin's fixed system aliases. Resolving arbitrary
    /// profile symlinks would defeat the no-follow ancestry contract.
    private static func platformPath(_ url: URL) throws -> URL {
        for alias in ["var", "tmp"] where url.path.hasPrefix("/" + alias + "/") {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: "/" + alias)
            guard target == "private/" + alias || target == "/private/" + alias else { throw ProfileCreationOwnershipError() }
            return URL(fileURLWithPath: "/private" + url.path, isDirectory: true)
        }
        return url
    }

    func removeEmptyOwnedDirectories() throws {
        try validate()
        if browser != nil { try validatePreparedInitialState() }
        if let initialDefault {
            try validatePreparedInitialState()
            guard let browser, let file = initialBookmarkFile, unlinkat(initialDefault, "Bookmarks", 0) == 0 else { throw ProfileCreationOwnershipError() }
            Darwin.close(file); initialBookmarkFile = nil; initialBookmarkIdentity = nil; initialBookmarkBytes = nil
            guard unlinkat(browser, "Default", AT_REMOVEDIR) == 0 else { throw BackupFS.posix() }
            Darwin.close(initialDefault); self.initialDefault = nil; initialDefaultIdentity = nil
        }
        if let browser, let browserIdentity {
            guard try BackupFS.identity(browser).sameObject(browserIdentity),
                  try BackupFS.entry(directory, "BrowserData")?.sameObject(browserIdentity) == true else { throw ProfileCreationOwnershipError() }
            guard unlinkat(directory, "BrowserData", AT_REMOVEDIR) == 0 else { throw BackupFS.posix() }
            self.browser = nil; self.browserIdentity = nil; Darwin.close(browser)
        } else {
            guard try BackupFS.entry(directory, "BrowserData") == nil else { throw ProfileCreationOwnershipError() }
        }
        try validate()
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0, fsync(parent) == 0 else { throw BackupFS.posix() }
    }

    deinit { if let initialBookmarkFile { Darwin.close(initialBookmarkFile) }; if let initialDefault { Darwin.close(initialDefault) }; if let browser { Darwin.close(browser) }; Darwin.close(directory); Darwin.close(parent) }
}
