import Darwin
import Foundation

/// Only the authenticated app composition can grant disposable Chromium
/// storage. A temporary pathname, editable Info.plist or MCP request is not
/// enough. No signing authority or system Keychain reference is retained.
final class ReleaseAuditBrowserIsolation: CustomReflectable {
    private let root: URL
    private let directory: Int32, parent: Int32
    private let identity: BackupIdentity, parentIdentity: BackupIdentity
    private let continuation: DirectUpdateAuditIsolation?
    var customMirror: Mirror { Mirror(self, children: [:]) }

    static func authenticatedRelease(_ context: FingerprintEvidenceReleaseContext) throws -> Self {
        let result = try Self(root: context.request.managerDataRoot, continuation: nil)
        try result.validate(); return result
    }
    static func authenticatedContinuation(_ isolation: DirectUpdateAuditIsolation) throws -> Self {
        try isolation.validate()
        let result = try Self(root: isolation.root, continuation: isolation)
        try result.validate(); return result
    }
    private init(root: URL, continuation: DirectUpdateAuditIsolation?) throws {
        // Foundation standardization rewrites an existing /private/tmp root
        // to its /tmp symlink alias. Custody uses the nofollow spelling instead.
        guard root.isFileURL, !root.pathComponents.contains(".."), !root.pathComponents.contains("."),
              root.lastPathComponent == "manager-data" else { throw DirectUpdateInstallSessionError.custody }
        let parent = try BackupFS.directory(root.deletingLastPathComponent())
        var rootFD: Int32 = -1, kept = false
        defer { if !kept { if rootFD >= 0 { close(rootFD) }; close(parent) } }
        try DirectAssessmentHelper.validatePrivateDirectory(parent)
        // Capture before ProfileStore initialization can write into this root.
        if try BackupFS.entry(parent, root.lastPathComponent) == nil {
            guard mkdirat(parent, root.lastPathComponent, 0o700) == 0 else { throw BackupFS.posix() }
        }
        rootFD = openat(parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw DirectUpdateInstallSessionError.custody }
        try DirectAssessmentHelper.validatePrivateDirectory(rootFD)
        self.root = root; self.parent = parent; directory = rootFD
        identity = try BackupFS.identity(rootFD); parentIdentity = try BackupFS.identity(parent)
        self.continuation = continuation
        // Fresh validation happens in the factory after initialization returns,
        // so a failed capture has exactly one descriptor-cleanup owner.
        kept = true
    }
    deinit { close(directory); close(parent) }

    func validate() throws {
        try continuation?.validate()
        try BackupFS.validateDirectoryPath(root, identity)
        try BackupFS.validateDirectoryPath(root.deletingLastPathComponent(), parentIdentity)
        guard try BackupFS.identity(directory).sameObject(identity),
              try BackupFS.identity(parent).sameObject(parentIdentity),
              try BackupFS.entry(parent, root.lastPathComponent)?.sameObject(identity) == true else {
            throw DirectUpdateInstallSessionError.custody
        }
        try DirectAssessmentHelper.validatePrivateDirectory(directory)
        try DirectAssessmentHelper.validatePrivateDirectory(parent)
    }

    func reservationRoot(paths: AppPaths) throws -> URL {
        try validate()
        guard paths.rootDirectory.path == root.path else { throw DirectUpdateInstallSessionError.custody }
        return root.appendingPathComponent("FingerprintAuditSessions", isDirectory: true)
    }

    func arguments(paths: AppPaths, browserDataDirectory: URL) throws -> [String] {
        try validate()
        guard paths.rootDirectory.path == root.path,
              browserDataDirectory.isFileURL,
              !browserDataDirectory.pathComponents.contains(".."), !browserDataDirectory.pathComponents.contains("."),
              browserDataDirectory.path.hasPrefix(root.path + "/") else {
            throw DirectUpdateInstallSessionError.custody
        }
        return ["--use-mock-keychain"]
    }

    /// After launch preparation creates the directory, open each component
    /// from retained root custody. No symlink or permissive directory may send
    /// a disposable browser into another profile's data before exec.
    @discardableResult
    func validateBeforeExec(paths: AppPaths, browserDataDirectory: URL) throws -> BrowserDirectoryCustody {
        _ = try arguments(paths: paths, browserDataDirectory: browserDataDirectory)
        let suffix = String(browserDataDirectory.path.dropFirst(root.path.count + 1))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 16,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw DirectUpdateInstallSessionError.custody
        }
        let custody = try BrowserDirectoryCustody(root: directory, components: components.map(String.init))
        try custody.validate()
        try validate()
        return custody
    }

    /// Retain the entire parent/child chain through exec, rather than checking
    /// a detached old directory while the pathname selects its replacement.
    /// A final pathname check cannot prevent a same-user mutation after it;
    /// these descriptors are custody evidence, not a filesystem sandbox.
    final class BrowserDirectoryCustody {
        private let root: Int32
        private let entries: [(descriptor: Int32, parent: Int32, name: String, identity: BackupIdentity)]
        fileprivate init(root: Int32, components: [String]) throws {
            let ownedRoot = fcntl(root, F_DUPFD_CLOEXEC, 0)
            guard ownedRoot >= 0 else { throw DirectUpdateInstallSessionError.custody }
            var entries: [(descriptor: Int32, parent: Int32, name: String, identity: BackupIdentity)] = []
            var kept = false
            defer { if !kept { entries.forEach { close($0.descriptor) }; close(ownedRoot) } }
            var current = ownedRoot
            for component in components {
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw DirectUpdateInstallSessionError.custody }
                do {
                    try DirectAssessmentHelper.validatePrivateDirectory(next)
                    entries.append((next, current, component, try BackupFS.identity(next)))
                } catch { close(next); throw error }
                current = next
            }
            self.root = ownedRoot; self.entries = entries; kept = true
        }
        deinit { entries.forEach { close($0.descriptor) }; close(root) }
        func validate() throws {
            guard fcntl(root, F_GETFD) & FD_CLOEXEC != 0,
                  entries.allSatisfy({ fcntl($0.descriptor, F_GETFD) & FD_CLOEXEC != 0 }) else {
                throw DirectUpdateInstallSessionError.custody
            }
            try DirectAssessmentHelper.validatePrivateDirectory(root)
            for entry in entries {
                guard try BackupFS.identity(entry.descriptor).sameObject(entry.identity),
                      try BackupFS.entry(entry.parent, entry.name)?.sameObject(entry.identity) == true else {
                    throw DirectUpdateInstallSessionError.custody
                }
                try DirectAssessmentHelper.validatePrivateDirectory(entry.descriptor)
            }
        }
    }
}
