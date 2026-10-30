import Darwin
import Foundation

/// Custody of one exclusively created audit directory. Retaining its inode
/// prevents an identical pathname from admitting a replacement before exec.
final class FingerprintAuditDirectoryCustody {
    private let url: URL, parentURL: URL
    private let directory: Int32, parent: Int32
    private let identity: BackupIdentity, parentIdentity: BackupIdentity
    init(_ url: URL) throws {
        self.url = url; parentURL = url.deletingLastPathComponent()
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw DirectUpdateInstallSessionError.custody }
        var child: Int32 = -1, kept = false
        defer { if !kept { if child >= 0 { close(child) }; close(parent) } }
        try DirectAssessmentHelper.validatePrivateDirectory(parent)
        child = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw DirectUpdateInstallSessionError.custody }
        try DirectAssessmentHelper.validatePrivateDirectory(child)
        directory = child; self.parent = parent
        identity = try BackupFS.identity(child); parentIdentity = try BackupFS.identity(parent)
        kept = true
    }
    deinit { close(directory); close(parent) }
    func validate() throws {
        let currentParent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentParent >= 0 else { throw DirectUpdateInstallSessionError.custody }
        defer { close(currentParent) }
        guard try BackupFS.identity(currentParent).sameObject(parentIdentity),
              try BackupFS.entry(parent, url.lastPathComponent)?.sameObject(identity) == true,
              try BackupFS.identity(directory).sameObject(identity) else { throw DirectUpdateInstallSessionError.custody }
        try DirectAssessmentHelper.validatePrivateDirectory(parent)
        try DirectAssessmentHelper.validatePrivateDirectory(directory)
    }
    /// Only after the browser has stopped. Changed or unsafe trees are retained;
    /// a stale pathname must never turn rejection into deletion of a replacement.
    func discard() throws {
        try validate()
        let tree = try BackupTree.capture(url, checksCancellation: false,
            includeHashes: false, excludeRootTransients: false)
        defer { tree.close() }
        guard tree.rootIdentity.sameObject(identity) else { throw DirectUpdateInstallSessionError.custody }
        try tree.validateAll()
        try validate()
        try tree.removeContents()
        try validate()
        guard unlinkat(parent, url.lastPathComponent, AT_REMOVEDIR) == 0 else { throw BackupFS.posix() }
    }
}
