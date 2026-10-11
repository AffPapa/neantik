import CryptoKit
import Darwin
import Foundation

/// Test-data custody only. This object carries no fingerprint signer, channel
/// policy, credentials or installation authority. The app creates it only after
/// release-audit authentication; the owner accepts its frame only from its exact
/// authenticated manager. There is no argv, environment or MCP entry point.
final package class DirectUpdateAuditIsolation: @unchecked Sendable, CustomReflectable {
    package let root: URL
    package let bytes: Data
    package var customMirror: Mirror { Mirror(self, children: [:]) }
    private let descriptor: Int32, parent: Int32
    private let identity: BackupIdentity, parentIdentity: BackupIdentity
    package static let maximumPreparedManifestBytes = 1_048_576
    private static let prefix = "neantik-update-audit-"
    private init(root: URL, bytes: Data, descriptor: Int32, parent: Int32,
                 identity: BackupIdentity, parentIdentity: BackupIdentity) {
        self.root = root; self.bytes = bytes; self.descriptor = descriptor; self.parent = parent
        self.identity = identity; self.parentIdentity = parentIdentity
    }
    deinit { close(descriptor); close(parent) }

    /// Internal composition factory, not validation of an untrusted release
    /// request. Its caller must already hold a validated release-audit context.
    package static func capture(root: URL, validatedManifest: Data) throws -> Self {
        guard !validatedManifest.isEmpty, validatedManifest.count <= maximumPreparedManifestBytes else {
            throw DirectUpdateInstallSessionError.custody
        }
        let (fd, parent, identity, parentIdentity) = try openRoot(root)
        var bytes = Data("NIA1".utf8)
        bytes.append(contentsOf: SHA256.hash(data: validatedManifest))
        for value in [UInt64(identity.device), UInt64(identity.inode), UInt64(parentIdentity.device), UInt64(parentIdentity.inode)] {
            var big = value.bigEndian; withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
        }
        let path = Data(root.path.utf8)
        var count = UInt32(path.count).bigEndian; withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
        bytes.append(path)
        let result = Self(root: root, bytes: bytes, descriptor: fd, parent: parent, identity: identity, parentIdentity: parentIdentity)
        try result.validate(); return result
    }
    /// Wire syntax is not authority. Only the mutually authenticated owner or
    /// candidate may adopt this record after its independent process checks.
    package static func adoptAuthenticatedFrame(_ input: Data) throws -> Self {
        let root = try frameRoot(input)
        let (fd, parent, identity, parentIdentity) = try openRoot(root)
        guard identity.device >= 0, parentIdentity.device >= 0,
              UInt64(identity.device) == integer(input, 36), UInt64(identity.inode) == integer(input, 44),
              UInt64(parentIdentity.device) == integer(input, 52), UInt64(parentIdentity.inode) == integer(input, 60) else {
            close(fd); close(parent); throw DirectUpdateInstallSessionError.custody
        }
        let result = Self(root: root, bytes: Data(input), descriptor: fd, parent: parent, identity: identity, parentIdentity: parentIdentity)
        try result.validate(); return result
    }
    package static func validateFrameSyntax(_ input: Data) throws { _ = try frameRoot(input) }
    package func validate() throws {
        try BackupFS.validateDirectoryPath(root, identity)
        try BackupFS.validateDirectoryPath(root.deletingLastPathComponent(), parentIdentity)
        guard try BackupFS.identity(descriptor).sameObject(identity),
              try BackupFS.identity(parent).sameObject(parentIdentity),
              try BackupFS.entry(parent, "manager-data")?.sameObject(identity) == true else {
            throw DirectUpdateInstallSessionError.custody
        }
        try DirectAssessmentHelper.validatePrivateDirectory(descriptor)
        try DirectAssessmentHelper.validatePrivateDirectory(parent)
    }
    private static func frameRoot(_ bytes: Data) throws -> URL {
        guard (73..<(72 + Int(PATH_MAX))).contains(bytes.count), bytes.prefix(4) == Data("NIA1".utf8),
              integer(bytes, 68, count: 4) == bytes.count - 72,
              let path = String(data: bytes.dropFirst(72), encoding: .utf8) else { throw DirectUpdateInstallSessionError.request }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard root.path == path else { throw DirectUpdateInstallSessionError.request }
        try validateNamespace(root)
        return root
    }
    private static func validateNamespace(_ root: URL) throws {
        let parent = root.deletingLastPathComponent(), name = parent.lastPathComponent
        guard root.isFileURL, root.lastPathComponent == "manager-data", parent.deletingLastPathComponent().path == "/private/tmp",
              name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + id.uuidString.lowercased() else { throw DirectUpdateInstallSessionError.custody }
    }
    private static func openRoot(_ root: URL) throws -> (Int32, Int32, BackupIdentity, BackupIdentity) {
        try validateNamespace(root)
        let parent = try BackupFS.directory(root.deletingLastPathComponent())
        do {
            try DirectAssessmentHelper.validatePrivateDirectory(parent)
            let fd = try BackupFS.directory(root)
            do {
                try DirectAssessmentHelper.validatePrivateDirectory(fd)
                let identity = try BackupFS.identity(fd), parentIdentity = try BackupFS.identity(parent)
                guard identity.device >= 0, parentIdentity.device >= 0 else { throw DirectUpdateInstallSessionError.custody }
                return (fd, parent, identity, parentIdentity)
            } catch { close(fd); throw error }
        } catch { close(parent); throw error }
    }
    private static func integer(_ bytes: Data, _ offset: Int, count: Int = 8) -> UInt64 {
        bytes.subdata(in: offset..<(offset + count)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// Published only by the live authenticated owner in its retained private
/// workspace. The candidate derives this location from the owner's kernel
/// executable path, never from caller-supplied path text.
package enum DirectUpdateAuditRecord {
    package static let name = "launch-audit-context.bin"
    package static func directory(authenticatedOwnerExecutable: URL) throws -> URL {
        let helpers = authenticatedOwnerExecutable.deletingLastPathComponent(), root = helpers.deletingLastPathComponent()
        let prefix = "neantik-update-operation-"
        guard authenticatedOwnerExecutable.lastPathComponent == "NeAntikUpdateOwner", helpers.lastPathComponent == "Helpers",
              root.deletingLastPathComponent().path == "/private/tmp", root.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))),
              root.lastPathComponent == prefix + id.uuidString.lowercased() else { throw DirectUpdateInstallSessionError.custody }
        let fd = try BackupFS.directory(root); defer { close(fd) }
        try DirectAssessmentHelper.validatePrivateDirectory(fd)
        return root.appendingPathComponent("apps", isDirectory: true)
    }
    package static func publish(_ isolation: DirectUpdateAuditIsolation, request: DirectUpdateBootstrapRequest,
                                directory: URL) throws -> Data {
        try isolation.validate()
        let fd = try BackupFS.directory(directory); defer { close(fd) }
        try DirectAssessmentHelper.validatePrivateDirectory(fd)
        let identity = try BackupFS.identity(fd)
        let bytes = Data("NAR1".utf8) + Data(SHA256.hash(data: request.bytes)) + isolation.bytes
        let temporary = ".audit-" + UUID().uuidString.lowercased()
        let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw DirectUpdateInstallSessionError.io }
        defer { close(output); _ = unlinkat(fd, temporary, 0) }
        try BackupFS.write(output, bytes, at: 0)
        guard fsync(output) == 0 else { throw DirectUpdateInstallSessionError.io }
        // Exclusive publication refuses a stale/replayed record.
        guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0, fsync(fd) == 0 else {
            throw DirectUpdateInstallSessionError.custody
        }
        try BackupFS.validateDirectoryPath(directory, identity); try isolation.validate()
        return Data(SHA256.hash(data: bytes))
    }
    package static func load(directory: URL, request: DirectUpdateBootstrapRequest) throws -> (DirectUpdateAuditIsolation, Data)? {
        let fd = try BackupFS.directory(directory); defer { close(fd) }
        try DirectAssessmentHelper.validatePrivateDirectory(fd)
        let directoryIdentity = try BackupFS.identity(fd)
        guard let initial = try BackupFS.entry(fd, name) else { return nil }
        let input = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw DirectUpdateInstallSessionError.custody }; defer { close(input) }
        let identity = try BackupFS.identity(input); try identity.validateFile(device: directoryIdentity.device)
        guard identity == initial, identity.mode & 0o7777 == 0o600, (109..<8_192).contains(identity.size) else {
            throw DirectUpdateInstallSessionError.custody
        }
        var status = stat(); guard fstat(input, &status) == 0, status.st_flags == 0 else { throw DirectUpdateInstallSessionError.custody }
        // Reuse private-directory ACL enforcement by applying the same empty-ACL
        // rule to this regular record; directories themselves were checked above.
        errno = 0
        if let acl = acl_get_fd_np(input, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }; var entry: acl_entry_t?
            errno = 0
            guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL, entry == nil else {
                throw DirectUpdateInstallSessionError.custody
            }
        } else if errno != ENOENT { throw DirectUpdateInstallSessionError.custody }
        let bytes = try BackupFS.read(input, at: 0, count: Int(identity.size))
        guard bytes.count == identity.size, bytes.prefix(4) == Data("NAR1".utf8),
              bytes.subdata(in: 4..<36) == Data(SHA256.hash(data: request.bytes)),
              try BackupFS.identity(input) == identity, try BackupFS.entry(fd, name) == identity else {
            throw DirectUpdateInstallSessionError.custody
        }
        try BackupFS.validateDirectoryPath(directory, directoryIdentity)
        return (try .adoptAuthenticatedFrame(Data(bytes.dropFirst(36))), Data(SHA256.hash(data: bytes)))
    }
}
