import Darwin
import Foundation

/// Recovery fence only. This does not authorize sockets, prove a route, or
/// permit signalling a process. No endpoint, login or password is persisted.
struct ProxyRelayLeaseReceipt: Codable, Equatable, Sendable {
    let profileID: UUID
    let sessionGeneration: UUID
    let ownerPID: pid_t
    let ownerStartSeconds: Int64
    let ownerStartMicroseconds: Int32
    let ownerUID: uid_t
    let loopbackPort: UInt16
    let runtimeExecutableSHA256: String
    let runtimeFrameworkSHA256: String
    let configurationSHA256: String

    func validate(ownerToken: UUID?) throws {
        func hash(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard ownerToken == sessionGeneration, ownerPID > 1,
              ownerStartSeconds > 0, (0..<1_000_000).contains(ownerStartMicroseconds),
              loopbackPort != 0, hash(runtimeExecutableSHA256), hash(runtimeFrameworkSHA256), hash(configurationSHA256)
        else { throw ProfileProcessBusyError() }
    }

    /// PID reuse is absence of this generation. A live PID whose generation
    /// cannot be inspected remains fenced; reparenting is not a mismatch.
    func ownerIsAbsent(inspect: (pid_t) -> ProxyRelayOwnerProcessIdentity?, isAlive: (pid_t) -> Bool) -> Bool {
        guard isAlive(ownerPID) else { return true }
        guard let current = inspect(ownerPID) else { return false }
        return current.generation.startSeconds != ownerStartSeconds ||
            current.generation.startMicroseconds != ownerStartMicroseconds || current.userID != ownerUID
    }
}

/// Persisted immediately after spawn, before credentials or Ready. An unknown
/// generation fences a live PID conservatively; it never authorizes signalling.
struct ProxyRelayPendingOwnerFence: Codable, Equatable, Sendable {
    let profileID: UUID
    let sessionGeneration: UUID
    let ownerPID: pid_t
    let ownerStartSeconds: Int64?
    let ownerStartMicroseconds: Int32?
    let ownerUID: uid_t?

    init(profileID: UUID, sessionGeneration: UUID, ownerPID: pid_t,
         identity: ProxyRelayOwnerProcessIdentity?) {
        self.profileID = profileID; self.sessionGeneration = sessionGeneration; self.ownerPID = ownerPID
        ownerStartSeconds = identity?.generation.startSeconds
        ownerStartMicroseconds = identity?.generation.startMicroseconds
        ownerUID = identity?.userID
    }

    func validate(ownerToken: UUID?) throws {
        guard ownerPID > 1, ownerToken == sessionGeneration else { throw ProfileProcessBusyError() }
        if ownerStartSeconds == nil && ownerStartMicroseconds == nil && ownerUID == nil { return }
        guard let seconds = ownerStartSeconds, let micros = ownerStartMicroseconds, ownerUID != nil,
              seconds > 0, (0..<1_000_000).contains(micros) else { throw ProfileProcessBusyError() }
    }

    func ownerIsAbsent(inspect: (pid_t) -> ProxyRelayOwnerProcessIdentity?, isAlive: (pid_t) -> Bool) -> Bool {
        guard isAlive(ownerPID) else { return true }
        guard let seconds = ownerStartSeconds, let micros = ownerStartMicroseconds, let uid = ownerUID,
              let current = inspect(ownerPID) else { return false }
        return current.generation.startSeconds != seconds || current.generation.startMicroseconds != micros || current.userID != uid
    }

    /// Exact compare under the process guard. Dates are normalized to the
    /// persisted ISO8601 representation before comparing the reserved lease.
    func persist(paths: AppPaths, expected: BrowserProcessLock) throws {
        try validate(ownerToken: expected.ownerToken)
        guard expected.phase == .starting, expected.pid == 0, expected.relay == nil,
              expected.pendingRelayOwner == nil, expected.ownerToken == sessionGeneration else { throw ProfileProcessBusyError() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let normalized = try decoder.decode(BrowserProcessLock.self, from: encoder.encode(expected))
        try paths.withProcessLockGuard(for: profileID) {
            guard try ManagedSessionLeaseReader.read(paths: paths, profileID: profileID) == normalized else { throw ProfileProcessBusyError() }
            let fenced = BrowserProcessLock(pid: expected.pid, executablePath: expected.executablePath,
                browserDataPath: expected.browserDataPath, createdAt: expected.createdAt, schemaVersion: 3,
                ownerToken: expected.ownerToken, managerPID: expected.managerPID, phase: .starting, pendingRelayOwner: self)
            try paths.writePrivateFile(encoder.encode(fenced), to: paths.lockFile(for: profileID))
        }
    }
}
