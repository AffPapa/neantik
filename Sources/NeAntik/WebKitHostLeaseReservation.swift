import Darwin
import Foundation

#if !NEANTIK_WEBKIT_STANDALONE_HOST

/// Durable manager-to-child ownership record for the WebKit host handoff.
/// The manager creates it while holding both profile guards; the child checks
/// it after acquiring those same guards. It is removed only after the child
/// has saved, exited, and released its guard descriptors.
struct WebKitHostLeaseReservation: Equatable, Sendable {
    /// Validate the path's lexical form without resolving filesystem aliases.
    /// macOS intentionally exposes equivalent `/private/tmp` and `/tmp` paths;
    /// resolving that alias here would reject a correctly pinned temporary QA
    /// bundle before its live signature checks can run.
    static func isCanonicalExecutablePath(_ path: String) -> Bool {
        guard path.utf8.count <= 4_096, path.hasPrefix("/"), path != "/",
              !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    enum Failure: LocalizedError, Equatable {
        case invalidSession
        case dataRootMismatch
        case invalidProcessIdentity
        case invalidExecutablePath
        case guardNotHeld
        case reservationExists
        case reservationMismatch
        case cleanupUnconfirmed

        var errorDescription: String? {
            switch self {
            case .invalidSession:
                return "Параметры сеанса WebKit имеют неверный формат."
            case .dataRootMismatch:
                return "Путь данных сеанса WebKit не совпадает с хранилищем профиля."
            case .invalidProcessIdentity:
                return "Не удалось подтвердить отдельный процесс WebKit."
            case .invalidExecutablePath:
                return "Путь исполняемого файла WebKit не прошёл проверку."
            case .guardNotHeld:
                return "Не удалось подтвердить блокировки профиля перед запуском WebKit."
            case .reservationExists:
                return "Профиль уже зарезервирован другим процессом."
            case .reservationMismatch:
                return "Запись запуска WebKit не совпадает с текущей сессией."
            case .cleanupUnconfirmed:
                return "Не удалось подтвердить безопасное завершение процесса WebKit."
            }
        }
    }

    let session: WebKitHostIPC.Session
    let lock: BrowserProcessLock

    /// Persist a live child reservation before the manager releases its
    /// profile guards. The caller must invoke this from the host client's
    /// post-spawn registration callback, before it sends bootstrap bytes.
    static func persist(
        session: WebKitHostIPC.Session,
        childPID: pid_t,
        childExecutablePath: String,
        paths: AppPaths,
        sessionGuard: PrivateFileGuardLease,
        metadataGuard: PrivateFileGuardLease,
        managerPID: pid_t = getpid(),
        now: Date = Date()
    ) throws -> WebKitHostLeaseReservation {
        guard session.isValid() else { throw Failure.invalidSession }
        guard session.dataRoot == paths.rootDirectory.standardizedFileURL.path else {
            throw Failure.dataRootMismatch
        }
        guard childPID > 0, managerPID > 0, childPID != managerPID else {
            throw Failure.invalidProcessIdentity
        }
        guard Self.isCanonicalExecutablePath(childExecutablePath) else {
            throw Failure.invalidExecutablePath
        }

        let sessionGuardURL = paths.lockGuardFile(for: session.profileID)
        let metadataGuardURL = sessionGuardURL.appendingPathExtension("webkit")
        do {
            try sessionGuard.validateHeldFile(at: sessionGuardURL)
            try metadataGuard.validateHeldFile(at: metadataGuardURL)
        } catch { throw Failure.guardNotHeld }

        guard try paths.privateFileEntryKind(
            paths.profileDeletionTombstone(for: session.profileID)) == .missing else {
            throw BrowserProfileDeletedError()
        }
        guard try paths.privateFileEntryKind(paths.lockFile(for: session.profileID)) == .missing else {
            throw Failure.reservationExists
        }

        try paths.prepareProfileDirectories(for: session.profileID)
        let lock = BrowserProcessLock(
            pid: childPID,
            executablePath: childExecutablePath,
            browserDataPath: paths.browserDataDirectory(for: session.profileID)
                .standardizedFileURL.path,
            createdAt: now,
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: session.generation,
            managerPID: managerPID,
            phase: .running
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encodedLock = try encoder.encode(lock)
        // Compare against the decoded representation that is actually durable.
        // ISO-8601 encoding may normalize sub-second Date precision.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persistedLock = try decoder.decode(BrowserProcessLock.self, from: encodedLock)
        try paths.createPrivateFileExclusively(encodedLock,
            at: paths.lockFile(for: session.profileID))
        return Self(session: session, lock: persistedLock)
    }

    /// Called in the child only after it owns both guards. The lock reader
    /// verifies the named inode and bounded file before decoding the record.
    static func validateChild(
        session: WebKitHostIPC.Session,
        paths: AppPaths,
        childPID: pid_t = getpid(),
        managerPID: pid_t = getppid(),
        executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]
    ) throws -> WebKitHostLeaseReservation {
        guard session.isValid(), session.dataRoot == paths.rootDirectory.standardizedFileURL.path,
              childPID > 0, managerPID > 0, childPID != managerPID
        else { throw Failure.invalidSession }
        guard Self.isCanonicalExecutablePath(executablePath) else {
            throw Failure.invalidExecutablePath
        }
        let lock: BrowserProcessLock
        do { lock = try ManagedSessionLeaseReader.read(paths: paths, profileID: session.profileID) }
        catch { throw Failure.reservationMismatch }
        guard lock.schemaVersion == BrowserProcessLock.currentSchemaVersion,
              lock.phase == .running, lock.pid == childPID,
              lock.managerPID == managerPID, lock.ownerToken == session.generation,
              lock.relay == nil, lock.pendingRelayOwner == nil,
              lock.executablePath == executablePath,
              lock.browserDataPath == paths.browserDataDirectory(for: session.profileID)
                .standardizedFileURL.path
        else { throw Failure.reservationMismatch }
        return Self(session: session, lock: lock)
    }

    /// Remove only the exact lease this reservation created. The child must
    /// already be gone so the profile process guard is no longer contended.
    func remove(paths: AppPaths, childIsGone: () -> Bool) throws {
        guard childIsGone() else { throw Failure.cleanupUnconfirmed }
        try paths.withProcessLockGuard(for: session.profileID) {
            let current = try ManagedSessionLeaseReader.read(paths: paths,
                profileID: session.profileID)
            guard current == lock else { throw Failure.reservationMismatch }
            try FileManager.default.removeItem(at: paths.lockFile(for: session.profileID))
        }
    }
}

/// Owns the two parent-side profile guards until the child PID has a durable
/// lease. The callbacks run on the host client's worker task, so this small
/// box serializes registration and cleanup without reaching into AppKit state.
final class WebKitHostLeaseHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private let paths: AppPaths
    private let session: WebKitHostIPC.Session
    private var sessionGuard: PrivateFileGuardLease?
    private var metadataGuard: PrivateFileGuardLease?
    private var reservation: WebKitHostLeaseReservation?

    init(paths: AppPaths, session: WebKitHostIPC.Session,
         sessionGuard: PrivateFileGuardLease,
         metadataGuard: PrivateFileGuardLease) {
        self.paths = paths
        self.session = session
        self.sessionGuard = sessionGuard
        self.metadataGuard = metadataGuard
    }

    func register(childPID: pid_t, childExecutablePath: String,
                  managerPID: pid_t = getpid()) throws {
        lock.lock(); defer { lock.unlock() }
        guard reservation == nil, let sessionGuard, let metadataGuard else {
            throw WebKitHostLeaseReservation.Failure.reservationExists
        }
        do {
            reservation = try WebKitHostLeaseReservation.persist(
                session: session, childPID: childPID,
                childExecutablePath: childExecutablePath, paths: paths,
                sessionGuard: sessionGuard, metadataGuard: metadataGuard,
                managerPID: managerPID)
            // The durable child record now prevents another manager from
            // entering while the child obtains both guards itself.
            self.sessionGuard = nil
            self.metadataGuard = nil
            sessionGuard.release()
            metadataGuard.release()
        } catch {
            self.sessionGuard = nil
            self.metadataGuard = nil
            sessionGuard.release()
            metadataGuard.release()
            throw error
        }
    }

    func remove(childPID: pid_t, childIsGone: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard let reservation else { return }
        guard reservation.lock.pid == childPID else {
            throw WebKitHostLeaseReservation.Failure.reservationMismatch
        }
        try reservation.remove(paths: paths, childIsGone: { childIsGone })
        self.reservation = nil
    }

    /// Release startup guards only when spawning failed before registration.
    /// A persisted child lease is never silently discarded here.
    func releaseIfUnregistered() {
        lock.lock(); defer { lock.unlock() }
        guard reservation == nil else { return }
        sessionGuard?.release(); sessionGuard = nil
        metadataGuard?.release(); metadataGuard = nil
    }
}
#endif
