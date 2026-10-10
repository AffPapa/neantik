import Darwin
import Foundation

/// Disposable Dev GUI fixtures must not read or write the system Keychain.
/// This backend is compiled out of release builds. Credentials are deliberately
/// transient; it is not a replacement for persistence or production testing.
#if DEBUG
final class DevelopmentFixtureKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(service: String, profileID: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[service + ":" + profileID.uuidString]
    }
    func upsert(_ data: Data, service: String, profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        values[service + ":" + profileID.uuidString] = data
    }
    func delete(service: String, profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: service + ":" + profileID.uuidString)
    }
}
#endif

extension KeychainStore {
    /// macOS Chromium otherwise uses Safe Storage even when manager proxy
    /// credentials are in memory. Only an explicitly marked disposable DEBUG
    /// bundle receives the native mock hook; release builds always return [].
    static func disposableBrowserArguments(
        environment: NeAntikApplicationEnvironment, paths: AppPaths,
        fixtureRoot: String? = Bundle.main.object(forInfoDictionaryKey: "NeAntikDevelopmentFixtureRoot") as? String
    ) -> [String] {
        #if DEBUG
        if usesDisposableDevelopmentBackend(environment: environment, paths: paths, fixtureRoot: fixtureRoot) {
            return ["--use-mock-keychain"]
        }
        #endif
        return []
    }

    static func applicationStore(
        environment: NeAntikApplicationEnvironment, paths: AppPaths,
        fixtureRoot: String? = Bundle.main.object(forInfoDictionaryKey: "NeAntikDevelopmentFixtureRoot") as? String
    ) -> KeychainStore {
        #if DEBUG
        if usesDisposableDevelopmentBackend(environment: environment, paths: paths, fixtureRoot: fixtureRoot) {
            return KeychainStore(backend: DevelopmentFixtureKeychain(), service: environment.keychainService, legacyService: nil)
        }
        #endif
        return KeychainStore(service: environment.keychainService, legacyService: environment.legacyKeychainService)
    }

    static func usesDisposableDevelopmentBackend(
        environment: NeAntikApplicationEnvironment, paths: AppPaths, fixtureRoot: String?
    ) -> Bool {
        #if DEBUG
        guard environment.isDevelopment, let fixtureRoot, fixtureRoot.hasPrefix("/") else { return false }
        let root = URL(fileURLWithPath: fixtureRoot, isDirectory: true).standardizedFileURL
        return paths.rootDirectory.standardizedFileURL.path == root.path &&
            ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) &&
            root.lastPathComponent.hasPrefix("neantik-dev-fixture.")
        #else
        return false
        #endif
    }
}

#if DEBUG
/// Persistent scope only for explicit disposable GUI fixtures. It is not
/// device-bound and is never a production substitute for Data Protection
/// Keychain. Separate instances permit own-fixture manager restart tests.
struct DevelopmentFixtureBackupScope: BackupCompatibilityScopeBackend {
    let paths: AppPaths
    private let name = ".browser-data-backup-fixture-scope"
    func read() throws -> Data? {
        let directory = try BackupFS.directory(paths.rootDirectory); defer { Darwin.close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw BackupFS.posix() }
        defer { Darwin.close(fd) }
        let identity = try BackupFS.identity(fd)
        try identity.validateFile(device: nil)
        guard identity.size == 32 else { throw BackupCompatibilityScopeError.unavailable }
        let bytes = try BackupFS.read(fd, at: 0, count: 32)
        guard try BackupFS.identity(fd) == identity, try BackupFS.entry(directory, name) == identity else { throw BrowserDataBackupStorageError.changed }
        return bytes
    }
    func insertIfAbsent(_ bytes: Data) throws -> Bool {
        guard bytes.count == 32 else { throw BackupCompatibilityScopeError.unavailable }
        let directory = try BackupFS.directory(paths.rootDirectory); defer { Darwin.close(directory) }
        let fd = openat(directory, name, O_WRONLY | O_NOFOLLOW | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { if errno == EEXIST { return false }; throw BackupFS.posix() }
        defer { Darwin.close(fd) }
        try BackupFS.write(fd, bytes, at: 0)
        guard fsync(fd) == 0, fsync(directory) == 0 else { throw BackupFS.posix() }
        return true
    }
}
#endif

extension BackupCompatibilityScopeStore {
    static func applicationStore(environment: NeAntikApplicationEnvironment, paths: AppPaths,
                                 fixtureRoot: String? = Bundle.main.object(forInfoDictionaryKey: "NeAntikDevelopmentFixtureRoot") as? String) -> BackupCompatibilityScopeStore {
        #if DEBUG
        if KeychainStore.usesDisposableDevelopmentBackend(environment: environment, paths: paths, fixtureRoot: fixtureRoot) {
            return BackupCompatibilityScopeStore(backend: DevelopmentFixtureBackupScope(paths: paths))
        }
        #endif
        return BackupCompatibilityScopeStore(backend: SecurityBackupCompatibilityScopeBackend(service: environment.bundleIdentifier + ".browser-data-backup-scope"))
    }
}
