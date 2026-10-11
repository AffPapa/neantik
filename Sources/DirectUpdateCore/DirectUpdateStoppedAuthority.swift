import Darwin
import DirectInstallFilesystem
import Foundation

package enum DirectUpdateStoppedError: Error, Equatable { case busy, unknown, released }

/// No arguments, profile paths or credentials are read. A snapshot is fresh
/// observation of legacy processes, not a lock against an old binary's launch.
enum DirectUpdateProcessInventory {
    struct Entry: Equatable {
        let processID: pid_t
        let identity: ProxyRelayOwnerProcessIdentity
        let executable: String
    }
    static let maximumProcesses = 65_536

    static func isNeAntik(_ executable: String) -> Bool {
        let url = URL(fileURLWithPath: executable.lowercased())
        return ["neantik", "nevision"].contains(where: { brand in
            url.lastPathComponent.hasPrefix(brand) || url.pathComponents.contains(brand + ".app") ||
                url.pathComponents.contains(brand + " browser.app") ||
                url.pathComponents.contains(brand + " browser framework.framework")
        })
    }

    static func requireQuiet(_ entries: [Entry], allowed: Entry? = nil) throws {
        for entry in entries where isNeAntik(entry.executable) {
            guard let allowed, entry == allowed else { throw DirectUpdateStoppedError.busy }
        }
        // A disappeared allowed child must not look like a successful ACK.
        if let allowed, !entries.contains(allowed) { throw DirectUpdateStoppedError.unknown }
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard path.hasPrefix("/"), !path.isEmpty else { return nil }
        return path
    }

    private static func confirmedZombie(_ pid: pid_t, generation: BrowserProcessKernelIdentity) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var current = kinfo_proc(), bytes = MemoryLayout<kinfo_proc>.stride
        let result = withUnsafeMutableBytes(of: &current) { sysctl(&mib, u_int(mib.count), $0.baseAddress, &bytes, nil, 0) }
        return result == 0 && bytes == MemoryLayout<kinfo_proc>.stride && current.kp_proc.p_pid == pid &&
            current.kp_proc.p_stat == SZOMB && current.kp_eproc.e_ucred.cr_uid == geteuid() &&
            generation == .init(startSeconds: Int64(current.kp_proc.p_starttime.tv_sec),
                startMicroseconds: Int32(current.kp_proc.p_starttime.tv_usec))
    }

    static func capture(onRefusal: (String) -> Void = { _ in }) throws -> [Entry] {
        func unknown(_ stage: String) -> DirectUpdateStoppedError { onRefusal(stage); return .unknown }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(geteuid())]
        var bytes = 0
        guard sysctl(&mib, u_int(mib.count), nil, &bytes, nil, 0) == 0,
              bytes > 0, bytes % MemoryLayout<kinfo_proc>.stride == 0 else { throw unknown("size-query") }
        let requested = bytes / MemoryLayout<kinfo_proc>.stride
        guard requested <= maximumProcesses - 32 else { throw unknown("limit") }
        var table = [kinfo_proc](repeating: kinfo_proc(), count: requested + 32)
        bytes = table.count * MemoryLayout<kinfo_proc>.stride
        let result = table.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &bytes, nil, 0) }
        guard result == 0, bytes > 0, bytes <= table.count * MemoryLayout<kinfo_proc>.stride,
              bytes % MemoryLayout<kinfo_proc>.stride == 0 else { throw unknown("table-read") }
        let count = bytes / MemoryLayout<kinfo_proc>.stride
        guard table.prefix(count).contains(where: { $0.kp_proc.p_pid == getpid() }) else { throw unknown("self-missing") }
        var entries: [Entry] = []; entries.reserveCapacity(count)
        for info in table.prefix(count) {
            let pid = info.kp_proc.p_pid
            guard pid > 0, pid != getpid() else { continue }
            let generation = BrowserProcessKernelIdentity(startSeconds: Int64(info.kp_proc.p_starttime.tv_sec),
                startMicroseconds: Int32(info.kp_proc.p_starttime.tv_usec))
            // libproc returns ESRCH for a zombie while kill(0) still succeeds.
            // Verify the reserved generation through fresh sysctl before skip.
            if info.kp_proc.p_stat == SZOMB, confirmedZombie(pid, generation: generation) { continue }
            guard let before = DirectProcessIdentityInspector.processIdentity(pid) else {
                if kill(pid, 0) == -1 && errno == ESRCH { continue }
                if confirmedZombie(pid, generation: generation) { continue }
                throw unknown("identity-unreadable")
            }
            guard before.userID == geteuid(), before.generation == generation else {
                if kill(pid, 0) == -1 && errno == ESRCH { continue }
                throw unknown("generation-changed")
            }
            // A proved same-generation zombie cannot execute or reopen data;
            // its unreaped PID remains reserved. Reused/live PID never qualifies.
            if info.kp_proc.p_stat == SZOMB { continue }
            guard let executable = path(pid), DirectProcessIdentityInspector.processIdentity(pid) == before,
                  path(pid) == executable else {
                if kill(pid, 0) == -1 && errno == ESRCH { continue }
                throw unknown("path-unreadable-or-changed")
            }
            entries.append(.init(processID: pid, identity: before, executable: executable))
        }
        return entries
    }
}

/// Separate updater owner only; it never joins the participant side of the
/// lifecycle fence. Conservative first policy requires every NeAntik instance
/// for this UID to stop, including another installation and detached helpers.
final package class DirectUpdateStoppedAuthority {
    private let lock = NSRecursiveLock()
    private var intent: InstallLifecycleIntent?
    private var released = false

    package init(installation: URL) throws {
        let parentURL = URL(fileURLWithPath: "/private/tmp/neantik-update-lifecycle-\(geteuid())")
        // Shared system tmp is root-owned. BackupFS.directory intentionally
        // requires current UID and applies only to the newly created child.
        let tmp = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard tmp >= 0 else { throw DirectUpdateStoppedError.unknown }; defer { close(tmp) }
        guard mkdirat(tmp, parentURL.lastPathComponent, 0o700) == 0 || errno == EEXIST else { throw DirectUpdateStoppedError.unknown }
        let parent = try BackupFS.directory(parentURL); defer { close(parent) }
        let identity = try BackupFS.identity(parent)
        guard identity.uid == geteuid(), identity.mode & 0o7777 == 0o700 else { throw DirectUpdateStoppedError.unknown }
        try BackupFS.validateDirectoryPath(parentURL, identity)
        intent = try InstallLifecycleIntent(namespaceURL: parentURL.appendingPathComponent(InstallLifecycle.namespaceName(installationURL: installation)))
    }

    package func validateStopped() throws {
        lock.lock(); defer { lock.unlock() }
        try validateFence()
        try DirectUpdateProcessInventory.requireQuiet(DirectUpdateProcessInventory.capture())
        try validateFence()
    }

    package func tryDrainParticipants() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !released, let intent else { throw DirectUpdateStoppedError.released }
        return try intent.tryAcquireParticipantFence()
    }

    package func validateLaunch(_ readiness: DirectUpdateCandidateReadiness, receipt: InstallFilesystemReceipt) throws {
        lock.lock(); defer { lock.unlock() }
        try validateFence(); try readiness.validate(receipt: receipt)
        let pid = readiness.processID
        guard let identity = DirectProcessIdentityInspector.processIdentity(pid), identity.userID == geteuid(),
              identity.parentProcessID == getpid(), let executable = DirectUpdateProcessInventory.path(pid) else {
            throw DirectUpdateStoppedError.unknown
        }
        try DirectUpdateProcessInventory.requireQuiet(DirectUpdateProcessInventory.capture(),
            allowed: .init(processID: pid, identity: identity, executable: executable))
        try readiness.validate(receipt: receipt); try validateFence()
    }

    /// Call only after actual acknowledge()/recovery completion. Object release
    /// alone is not a durable ACK; orchestration retains it across failures.
    package func releaseAfterCompletion() throws {
        lock.lock(); defer { lock.unlock() }
        guard !released, let intent else { throw DirectUpdateStoppedError.released }
        try intent.validateHeldParticipantFence()
        self.intent = nil; released = true
    }

    private func validateFence() throws {
        guard !released, let intent else { throw DirectUpdateStoppedError.released }
        guard try intent.tryAcquireParticipantFence() else { throw DirectUpdateStoppedError.busy }
    }
}
