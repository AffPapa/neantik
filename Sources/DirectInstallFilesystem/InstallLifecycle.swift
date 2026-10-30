import Darwin
import Foundation

@_silgen_name("flock") private func lifecycleFlock(_ fd: Int32, _ operation: Int32) -> Int32

/// Cooperation only: legacy managers and Chromium do not participate. A quiet
/// fence must be combined with fresh process inventory before an install.
/// Names are permanent; deleting them would create independent inode locks.
private final class LifecycleHandles {
    static let admissionName = "admission.guard", participantsName = "participants.guard"
    let url: URL, parent: Int32, directory: Int32, admission: Int32, participants: Int32
    let parentIdentity: InstallObject, identity: InstallObject, admissionIdentity: InstallObject, participantsIdentity: InstallObject

    init(namespaceURL: URL) throws {
        let parentURL = namespaceURL.deletingLastPathComponent()
        let parent = try InstallFS.directory(parentURL)
        var retained = false
        defer { if !retained { close(parent) } }
        let parentIdentity = try InstallFS.privateDirectory(parent)
        try InstallFS.name(namespaceURL.lastPathComponent)
        guard mkdirat(parent, namespaceURL.lastPathComponent, 0o700) == 0 || errno == EEXIST else { throw InstallFS.posix() }
        let directory = try InstallFS.directory(namespaceURL)
        var admission: Int32 = -1, participants: Int32 = -1
        defer { if !retained { if admission >= 0 { close(admission) }; if participants >= 0 { close(participants) }; close(directory) } }
        let identity = try InstallFS.privateDirectory(directory)
        func openGuard(_ name: String) throws -> (Int32, InstallObject) {
            let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            // Separate exclusive creation from opening an existing name. On
            // this macOS cold concurrent O_CREAT opens reproduced ENOENT.
            // EEXIST is the only fallback; disappearance still refuses.
            var fd = openat(directory, name, flags | O_CREAT | O_EXCL, 0o600)
            if fd < 0, errno == EEXIST { fd = openat(directory, name, flags) }
            guard fd >= 0 else { throw InstallFS.posix() }
            do {
                let object = try InstallFS.object(fd)
                try InstallFS.owned(object, device: identity.device)
                guard object.file, object.size == 0, object.mode & 0o777 == 0o600 else { throw InstallFilesystemError.unsafe }
                try InstallFS.noACL(fd)
                guard try InstallFS.entry(directory, name) == object else { throw InstallFilesystemError.changed }
                return (fd, object)
            } catch { close(fd); throw error }
        }
        let a = try openGuard(Self.admissionName); admission = a.0
        let p = try openGuard(Self.participantsName); participants = p.0
        let fresh = try InstallFS.directory(namespaceURL); defer { close(fresh) }
        let freshParent = try InstallFS.directory(parentURL); defer { close(freshParent) }
        guard try InstallFS.privateDirectory(fresh).sameObject(identity),
              try InstallFS.privateDirectory(freshParent).sameObject(parentIdentity),
              try InstallFS.entry(directory, Self.admissionName) == a.1,
              try InstallFS.entry(directory, Self.participantsName) == p.1 else { throw InstallFilesystemError.changed }
        self.url = namespaceURL; self.parent = parent; self.parentIdentity = parentIdentity
        self.directory = directory; self.identity = identity
        self.admission = admission; admissionIdentity = a.1
        self.participants = participants; participantsIdentity = p.1
        retained = true
    }
    deinit { close(participants); close(admission); close(directory); close(parent) }
    func validate() throws {
        let fresh = try InstallFS.directory(url); defer { close(fresh) }
        let freshParent = try InstallFS.directory(url.deletingLastPathComponent()); defer { close(freshParent) }
        guard try InstallFS.privateDirectory(freshParent).sameObject(parentIdentity),
              try InstallFS.privateDirectory(parent).sameObject(parentIdentity),
              try InstallFS.privateDirectory(fresh).sameObject(identity),
              try InstallFS.privateDirectory(directory).sameObject(identity),
              try InstallFS.object(admission) == admissionIdentity,
              try InstallFS.object(participants) == participantsIdentity,
              try InstallFS.entry(directory, Self.admissionName) == admissionIdentity,
              try InstallFS.entry(directory, Self.participantsName) == participantsIdentity else { throw InstallFilesystemError.changed }
        try InstallFS.noACL(admission); try InstallFS.noACL(participants)
    }
    func exclusiveAdmission() throws {
        try validate()
        guard lifecycleFlock(admission, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw InstallFilesystemError.busy }; throw InstallFS.posix()
        }
    }
}

public enum InstallLifecycle {
    /// Resolve filesystem aliases to the same installation. Atomic replacement
    /// changes app inodes, so the scope is its canonical pathname, not its inode.
    public static func namespaceName(installationURL: URL) throws -> String {
        guard installationURL.isFileURL, installationURL.path.hasPrefix("/"),
              let path = realpath(installationURL.path, nil) else { throw InstallFilesystemError.unsafe }
        defer { free(path) }
        let canonical = String(cString: path)
        guard canonical.hasSuffix(".app") else { throw InstallFilesystemError.unsafe }
        let fd = try InstallFS.directory(URL(fileURLWithPath: canonical)); defer { close(fd) }
        guard try InstallFS.object(fd).directory else { throw InstallFilesystemError.unsafe }
        return InstallFS.hash(Data(canonical.utf8))
    }

    /// No adoption, deletion or migration on ordinary startup after an uncertain
    /// swap. Only the current canonical NeAntik install target uses these records.
    public static func requireNoPendingTransaction(installationURL: URL) throws {
        guard installationURL.lastPathComponent == InstallFilesystemTransaction.appName else { return }
        let parent = try InstallFS.directory(installationURL.deletingLastPathComponent()); defer { close(parent) }
        if try InstallFS.entry(parent, InstallFilesystemTransaction.activeName) != nil { throw InstallFilesystemError.pending }
        // An install parent can contain unrelated apps with decomposed Unicode
        // or other names outside the transaction-name contract. Inspect only the
        // ASCII pending prefix; do not reject those unrelated entries.
        let copy = dup(parent); guard copy >= 0 else { throw InstallFS.posix() }
        guard let stream = fdopendir(copy) else { close(copy); throw InstallFS.posix() }
        defer { closedir(stream) }; rewinddir(stream)
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw InstallFS.posix() }; break }
            count += 1; guard count <= 6_000 else { throw InstallFilesystemError.limit }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { p in
                p.withMemoryRebound(to: UInt8.self, capacity: 256) { String(decodingCString: $0, as: UTF8.self) }
            }
            if name.hasPrefix(".neantik-install-preparing-") { throw InstallFilesystemError.pending }
        }
    }
}

/// Independently acquired for each GUI, MCP or relay process; keep until exit.
/// CLOEXEC prevents a child from accidentally prolonging its parent's lease.
public final class InstallLifecycleParticipant {
    private let handles: LifecycleHandles
    private let lock = NSLock()
    public init(namespaceURL: URL, beforeAdmissionRelease: () throws -> Void = {}) throws {
        let handles = try LifecycleHandles(namespaceURL: namespaceURL)
        try handles.exclusiveAdmission()
        defer { _ = lifecycleFlock(handles.admission, LOCK_UN) }
        guard lifecycleFlock(handles.participants, LOCK_SH | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw InstallFilesystemError.busy }; throw InstallFS.posix()
        }
        try handles.validate(); try beforeAdmissionRelease(); try handles.validate()
        self.handles = handles
    }
    /// Brief nonblocking check before admitting new work. This does not cancel
    /// existing work; the retained SH keeps the updater waiting for process exit.
    public func requireNewWork() throws {
        lock.lock(); defer { lock.unlock() }
        try handles.exclusiveAdmission()
        defer { _ = lifecycleFlock(handles.admission, LOCK_UN) }
        try handles.validate()
    }
}

/// For a separate updater owner with NO participant lease. Retains admission
/// while participants drain. Never attempts a non-atomic SH-to-EX conversion.
public final class InstallLifecycleIntent {
    private let handles: LifecycleHandles
    private let lock = NSLock()
    private var quiet = false
    public init(namespaceURL: URL) throws {
        let handles = try LifecycleHandles(namespaceURL: namespaceURL)
        try handles.exclusiveAdmission(); try handles.validate()
        self.handles = handles
    }
    /// Nonblocking, cancellable polling primitive; false means participants live.
    /// True is only cooperative quiescence, not authority to replace an app.
    public func tryAcquireParticipantFence() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation(); try handles.validate()
        if quiet { return true }
        if lifecycleFlock(handles.participants, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return false }; throw InstallFS.posix()
        }
        try handles.validate(); quiet = true; return true
    }
    /// Verify a previously acquired fence after a durable filesystem decision.
    /// Cancellation cannot reverse ACK; this neither acquires a new fence nor
    /// treats a still-running participant as quiet.
    public func validateHeldParticipantFence() throws {
        lock.lock(); defer { lock.unlock() }
        guard quiet else { throw InstallFilesystemError.busy }
        try handles.validate()
    }
}
