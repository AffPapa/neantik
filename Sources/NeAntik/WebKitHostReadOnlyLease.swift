import Darwin
import Foundation

/// Shared wire decoder for the manager's schema-3 running lease. Compile it
/// into both targets so a manager test can exercise the exact host decoder.
struct WebKitHostReservationRecord: Decodable, Equatable, Sendable {
        let schemaVersion: Int
        let ownerToken: UUID
        let managerPID: pid_t
        let phase: String
        let pid: pid_t
        let executablePath: String
        let browserDataPath: String

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, ownerToken, managerPID, phase, pid
            case executablePath, browserDataPath, relay, pendingRelayOwner
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard try (!values.contains(.relay) || values.decodeNil(forKey: .relay)),
                  try (!values.contains(.pendingRelayOwner) || values.decodeNil(forKey: .pendingRelayOwner)) else {
                throw WebKitHostReservationRecord.Failure.reservationMismatch
            }
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            ownerToken = try values.decode(UUID.self, forKey: .ownerToken)
            managerPID = try values.decode(pid_t.self, forKey: .managerPID)
            phase = try values.decode(String.self, forKey: .phase)
            pid = try values.decode(pid_t.self, forKey: .pid)
            executablePath = try values.decode(String.self, forKey: .executablePath)
            browserDataPath = try values.decode(String.self, forKey: .browserDataPath)
        }
    enum Failure: Error { case reservationMismatch }

    /// macOS exposes the same temporary directory through /tmp and
    /// /private/tmp. The signed host identity is checked independently before
    /// this lease is read; no other path alias is accepted here.
    static func matchesExecutablePath(_ reserved: String, _ live: String) -> Bool {
        func valid(_ path: String) -> Bool {
            path.hasPrefix("/") && !path.utf8.contains(0) &&
            path.split(separator: "/", omittingEmptySubsequences: false)
                .dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }
        guard valid(reserved), valid(live) else { return false }
        if reserved == live { return true }
        func normalized(_ path: String) -> String {
            path.hasPrefix("/tmp/") ? "/private" + path : path
        }
        return normalized(reserved) == normalized(live)
    }
}

#if NEANTIK_WEBKIT_STANDALONE_HOST
struct WebKitHostLeaseReservation: Equatable, Sendable {
    enum Failure: Error {
        case invalidSession, unsafeFile, unopenableFile, unreadableFile
        case changedFile, decodeFailed, schemaMismatch, pidMismatch
        case managerMismatch, generationMismatch, executableMismatch
        case dataPathMismatch

        var diagnosticCode: String {
            switch self {
            case .invalidSession: "invalidSession"
            case .unsafeFile: "unsafeFile"
            case .unopenableFile: "unopenableFile"
            case .unreadableFile: "unreadableFile"
            case .changedFile: "changedFile"
            case .decodeFailed: "decodeFailed"
            case .schemaMismatch: "schemaMismatch"
            case .pidMismatch: "pidMismatch"
            case .managerMismatch: "managerMismatch"
            case .generationMismatch: "generationMismatch"
            case .executableMismatch: "executableMismatch"
            case .dataPathMismatch: "dataPathMismatch"
            }
        }
    }

    let session: WebKitHostIPC.Session
    private let record: WebKitHostReservationRecord

    static func validateChild(session: WebKitHostIPC.Session, paths: AppPaths,
                              childPID: pid_t = getpid(), managerPID: pid_t = getppid(),
                              executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) throws -> Self {
        guard session.isValid(),
              session.dataRoot == paths.rootDirectory.standardizedFileURL.path,
              childPID > 0, managerPID > 0, childPID != managerPID,
              executablePath.hasPrefix("/"), !executablePath.contains("/../"),
              !executablePath.contains("/./") else { throw Failure.invalidSession }
        let url = paths.lockFile(for: session.profileID)
        do { try paths.validatePrivateFile(url) }
        catch { throw Failure.unsafeFile }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unopenableFile }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 16_384 else {
            throw Failure.unsafeFile
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                Darwin.pread(fd, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.unreadableFile }
            offset += count
        }
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino,
              named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              after.st_nlink == 1 else { throw Failure.changedFile }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: WebKitHostReservationRecord
        do { record = try decoder.decode(WebKitHostReservationRecord.self, from: Data(bytes)) }
        catch { throw Failure.decodeFailed }
        guard record.schemaVersion == 3, record.phase == "running" else { throw Failure.schemaMismatch }
        guard record.pid == childPID else { throw Failure.pidMismatch }
        guard record.managerPID == managerPID else { throw Failure.managerMismatch }
        guard record.ownerToken == session.generation else { throw Failure.generationMismatch }
        guard WebKitHostReservationRecord.matchesExecutablePath(record.executablePath, executablePath)
        else { throw Failure.executableMismatch }
        guard record.browserDataPath == paths.browserDataDirectory(for: session.profileID).standardizedFileURL.path
        else { throw Failure.dataPathMismatch }
        return Self(session: session, record: record)
    }
}
#endif
