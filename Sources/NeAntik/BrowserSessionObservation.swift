import Darwin
import Foundation

/// An allowlisted observation of a manager-owned browser session. Launch
/// configuration is separate from browser-observed network or page evidence.
struct BrowserSessionObservation: Sendable, CustomReflectable, CustomStringConvertible {
    enum State: String, Sendable { case observed, unavailable }
    enum Ownership: String, Sendable { case thisSession, notOwned, unverified }
    enum Route: String, Sendable { case direct, httpProxy, httpsProxy, socks5Proxy, unknown }

    let state: State
    let ownership: Ownership
    let readyForGracefulQuit: Bool?
    let runtimeVersion: String?
    let configuredRoute: Route
    var sessionGeneration: UUID? = nil
    var relayTransport: BrowserRelayActivity.Snapshot? = nil
    var sampledRouteProbe: BrowserRouteProbe.Snapshot? = nil
    var routeProbe: BrowserRouteProbe.Snapshot? { sampledRouteProbe?.current() }
    var launchContext: ManagedBrowserSessionReceipt? = nil
    var description: String { "BrowserSessionObservation(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    static func unavailable(_ ownership: Ownership) -> Self {
        Self(state: .unavailable, ownership: ownership,
             readyForGracefulQuit: nil, runtimeVersion: nil,
             configuredRoute: .unknown)
    }

    var mcpValue: [String: Any] {
        ["state": state.rawValue, "ownership": ownership.rawValue,
         "readyForGracefulQuit": readyForGracefulQuit as Any? ?? NSNull(),
         "runtimeVersion": runtimeVersion as Any? ?? NSNull(),
         "configuredRoute": configuredRoute.rawValue,
         "chromiumRoute": "notObserved", "pageObservation": "notSupported",
         "extensionsObservation": "notObserved",
         "relayTransport": relayTransport?.mcpValue ?? ["state": "notObserved"]]
    }
}

/// Compare the configuration portion of a launch bookkeeping transition.
/// This delta is not authority: health also requires a durable markLaunched
/// receipt. Persisted metadata dates use second precision.
enum ProfileLaunchMetadataTransition {
    static func matches(from original: BrowserProfile, to recorded: BrowserProfile) throws -> Bool {
        guard original.id == recorded.id, original.revision < UInt64.max,
              recorded.revision == original.revision + 1, recorded.lastLaunchedAt != nil else { return false }
        var comparable = recorded
        comparable.revision = original.revision; comparable.updatedAt = original.updatedAt
        comparable.lastLaunchedAt = original.lastLaunchedAt
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        return try encoder.encode(comparable) == encoder.encode(original)
    }
}

struct ManagedBrowserSessionReceipt: Equatable, Sendable {
    let generation: UUID
    let lock: BrowserProcessLock
    let runtimeVersion: String?
    let configuredRoute: BrowserSessionObservation.Route
    var profileRevision: UInt64? = nil
    var browserIdentity: ProxyRelayOwnerProcessIdentity? = nil
    var observedMetadataRevision: UInt64? = nil
    var routePolicySHA256: String? = nil

    /// markLaunched advances metadata after the immutable relay bootstrap.
    /// Accept only that exact single bookkeeping transition, never a newer
    /// proxy/identity/editor configuration or a guessed revision offset.
    mutating func recordLaunchMetadata(from original: BrowserProfile, to recorded: BrowserProfile) throws -> Bool {
        guard profileRevision == original.revision,
              try ProfileLaunchMetadataTransition.matches(from: original, to: recorded) else { return false }
        observedMetadataRevision = recorded.revision
        return true
    }

    func relayBinding(profileID: UUID, expectedRevision: UInt64?) throws -> ProxyRelayObservationProtocol.Binding? {
        guard let revision = profileRevision, (observedMetadataRevision ?? revision) == expectedRevision,
              let browserIdentity, let relay = lock.relay,
              relay.profileID == profileID, relay.sessionGeneration == generation,
              lock.ownerToken == generation, lock.phase == .running else { return nil }
        let ownerIdentity = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: relay.ownerStartSeconds,
            startMicroseconds: relay.ownerStartMicroseconds), userID: relay.ownerUID, parentProcessID: 0)
        let binding = ProxyRelayObservationProtocol.Binding(profileID: profileID, sessionGeneration: generation, profileRevision: revision,
            runtimeExecutableSHA256: relay.runtimeExecutableSHA256, runtimeFrameworkSHA256: relay.runtimeFrameworkSHA256,
            configurationSHA256: relay.configurationSHA256, owner: .init(pid: relay.ownerPID, identity: ownerIdentity),
            browser: .init(pid: lock.pid, identity: browserIdentity))
        try binding.validate(); return binding
    }

    /// Bound a receipt to the exact, still-owned launch lease. Never adopt an
    /// external process or expose its PID, paths, owner token, or credentials.
    func matches(_ current: BrowserProcessLock) -> Bool {
        current == lock && (2...BrowserProcessLock.currentSchemaVersion).contains(current.schemaVersion) &&
            current.phase == .running && current.ownerToken != nil &&
            current.managerPID == getpid()
    }

    static func safeRuntimeVersion(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 64 else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return nil }
        return value
    }
}

enum ManagedSessionLeaseReader {
    /// Final publication fence after asynchronous observation/code checks.
    /// The in-memory metadata snapshot alone cannot detect another manager's
    /// write during those waits. Keep the existing process -> metadata order.
    static func matchesPersistedContext(paths: AppPaths, profile: BrowserProfile, receipt: ManagedBrowserSessionReceipt) throws -> Bool {
        try paths.withProcessLockGuard(for: profile.id) {
            try ProfileStore.withPersistedLaunchSnapshot(profile, paths: paths) {
                try read(paths: paths, profileID: profile.id) == receipt.lock
            }
        }
    }
    /// The caller holds the process guard. A bounded descriptor read avoids
    /// symlink/FIFO blocking and checks replacement before trusting the data.
    static func read(paths: AppPaths, profileID: UUID) throws -> BrowserProcessLock {
        let url = paths.lockFile(for: profileID)
        try paths.validatePrivateFile(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ProfileProcessBusyError() }
        defer { _ = close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 16_384
        else { throw ProfileProcessBusyError() }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                Darwin.pread(fd, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ProfileProcessBusyError() }
            offset += count
        }
        var after = stat(), entry = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &entry) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              entry.st_dev == after.st_dev, entry.st_ino == after.st_ino,
              entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              after.st_nlink == 1
        else { throw ProfileProcessBusyError() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrowserProcessLock.self, from: Data(bytes))
    }
}
