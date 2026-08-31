import Darwin
import Foundation

struct ManagerSessionRecord: Codable, Equatable, Sendable {
    let token: UUID
    let pid: pid_t
    let startedAt: Date
}

struct ManagerSessionStartEvidence: Equatable, Sendable {
    let token: UUID
    let interruptedSessionCount: Int
}

/// Records only manager PID, start time and a random ownership token. It never
/// includes profile identifiers, paths, proxy data or browser output.
struct ManagerSessionEvidenceStore: Sendable {
    private static let maximumRecords = 32
    private static let maximumFileBytes = 64 * 1_024

    let paths: AppPaths
    let processIsAlive: @Sendable (pid_t) -> Bool

    init(
        paths: AppPaths,
        processIsAlive: @escaping @Sendable (pid_t) -> Bool
    ) {
        self.paths = paths
        self.processIsAlive = processIsAlive
    }

    func begin(
        pid: pid_t = getpid(),
        now: Date = Date(),
        token: UUID = UUID()
    ) throws -> ManagerSessionStartEvidence {
        try paths.prepareBaseDirectories()
        return try paths.withManagerSessionsGuard {
            let existing = try loadRecords()
            let interrupted = existing.filter {
                $0.pid > 0 && !processIsAlive($0.pid)
            }
            var active = existing.filter {
                $0.pid > 0 && processIsAlive($0.pid)
            }
            active.append(
                ManagerSessionRecord(
                    token: token,
                    pid: pid,
                    startedAt: now
                )
            )
            try saveRecords(Array(active.suffix(Self.maximumRecords)))
            return ManagerSessionStartEvidence(
                token: token,
                interruptedSessionCount: interrupted.count
            )
        }
    }

    func finish(token: UUID) throws {
        try paths.withManagerSessionsGuard {
            let remaining = try loadRecords().filter { $0.token != token }
            try saveRecords(remaining)
        }
    }

    private func loadRecords() throws -> [ManagerSessionRecord] {
        switch try paths.privateFileEntryKind(paths.managerSessionsFile) {
        case .missing:
            return []
        case .unsafe:
            throw POSIXError(.EFTYPE)
        case .regular:
            let data = try paths.readPrivateFile(
                paths.managerSessionsFile,
                maximumBytes: Self.maximumFileBytes
            )
            let decoded = try JSONDecoder().decode(
                [ManagerSessionRecord].self,
                from: data
            )
            return Array(decoded.prefix(Self.maximumRecords))
        }
    }

    private func saveRecords(_ records: [ManagerSessionRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try paths.writePrivateFile(data, to: paths.managerSessionsFile)
    }
}
