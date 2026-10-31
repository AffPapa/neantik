import Darwin
import Foundation

/// The owner and assessment helper must survive replacement of either app
/// slot. This private workspace holds exact installed helper copies and the
/// admission stages. It never supplies channel policy or an install target.
final package class DirectUpdateOwnerWorkspace: @unchecked Sendable, CustomReflectable {
    package let root: URL, owner: DirectAssessmentHelper, assessment: DirectAssessmentHelper
    package var archives: URL { root.appendingPathComponent("archives") }
    package var apps: URL { root.appendingPathComponent("apps") }
    package var customMirror: Mirror { Mirror(self, children: [:]) }
    private let descriptor: Int32, identity: BackupIdentity
    private let children: [String: OwnerWorkspaceDirectory]
    private static let prefix = "neantik-update-operation-"
    private init(root: URL, descriptor: Int32, identity: BackupIdentity,
                 owner: DirectAssessmentHelper, assessment: DirectAssessmentHelper, children: [String: OwnerWorkspaceDirectory]) {
        self.root = root; self.descriptor = descriptor; self.identity = identity
        self.owner = owner; self.assessment = assessment
        self.children = children
    }
    deinit { close(descriptor) }
    package static func prepare(policy: DirectUpdateInstalledPolicy) throws -> Self {
        try policy.validate()
        let temporary = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard temporary >= 0 else { throw DirectAssessmentParentError.helper }; defer { close(temporary) }
        let name = prefix + UUID().uuidString.lowercased()
        guard mkdirat(temporary, name, 0o700) == 0 else { throw DirectAssessmentParentError.helper }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name)
        let descriptor = try BackupFS.directory(root)
        var retained = false; defer { if !retained { close(descriptor) } }
        let identity = try BackupFS.identity(descriptor)
        guard identity.mode & 0o7777 == 0o700 else { throw DirectAssessmentParentError.helper }
        try DirectAssessmentHelper.validatePrivateDirectory(descriptor)
        for child in ["Helpers", "archives", "apps"] {
            guard mkdirat(descriptor, child, 0o700) == 0 else { throw DirectAssessmentParentError.helper }
        }
        guard fsync(descriptor) == 0 else { throw DirectAssessmentParentError.helper }
        let directory = root.appendingPathComponent("Helpers")
        let owner = try policy.owner.relocate(to: directory)
        let assessment = try policy.assessment.relocate(to: directory)
        try policy.validate()
        let result = Self(root: root, descriptor: descriptor, identity: identity, owner: owner, assessment: assessment,
            children: try captureChildren(root))
        retained = true; try result.validate(); return result
    }
    /// Fixed pathname is derived from this process's kernel executable path.
    /// The authentic installed policy supplies both pins, never stdin/argv.
    package static func inspect(ownerExecutable: URL, policy: DirectUpdateInstalledPolicy) throws -> Self {
        guard ownerExecutable.lastPathComponent == "NeAntikUpdateOwner",
              ownerExecutable.deletingLastPathComponent().lastPathComponent == "Helpers" else { throw DirectAssessmentParentError.helper }
        let root = ownerExecutable.deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent().path == "/private/tmp", root.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))),
              root.lastPathComponent == prefix + id.uuidString.lowercased() else { throw DirectAssessmentParentError.helper }
        try policy.validate()
        let descriptor = try BackupFS.directory(root)
        var retained = false; defer { if !retained { close(descriptor) } }
        let identity = try BackupFS.identity(descriptor)
        // Factories have fixed paths/identifiers. The workspace mimics only the
        // helper layout; it has no Info.plist or app trust of its own.
        let owner = try DirectAssessmentHelper.relocatedOwner(in: root, pin: policy.metadata.owner)
        let assessment = try DirectAssessmentHelper.relocatedAssessment(in: root, pin: policy.metadata.assessment)
        let result = Self(root: root, descriptor: descriptor, identity: identity, owner: owner, assessment: assessment,
            children: try captureChildren(root))
        retained = true; try result.validate(); try policy.validate(); return result
    }
    package func validate() throws {
        try Task.checkCancellation()
        try BackupFS.validateDirectoryPath(root, identity)
        guard try BackupFS.identity(descriptor).sameObject(identity),
              try BackupFS.identity(descriptor).mode & 0o7777 == 0o700,
              Set(try BackupFS.names(descriptor)) == ["Helpers", "archives", "apps"] else { throw DirectAssessmentParentError.helper }
        try DirectAssessmentHelper.validatePrivateDirectory(descriptor)
        for child in ["Helpers", "archives", "apps"] {
            let fd = try BackupFS.directory(root.appendingPathComponent(child)); defer { close(fd) }
            guard let original = children[child], try BackupFS.identity(fd).sameObject(original.identity),
                  try BackupFS.identity(original.descriptor).sameObject(original.identity),
                  try BackupFS.identity(fd).mode & 0o7777 == 0o700 else { throw DirectAssessmentParentError.helper }
            try DirectAssessmentHelper.validatePrivateDirectory(fd)
        }
        try owner.validate(); try assessment.validate()
        try BackupFS.validateDirectoryPath(root, identity)
    }
    private static func captureChildren(_ root: URL) throws -> [String: OwnerWorkspaceDirectory] {
        var identities: [String: OwnerWorkspaceDirectory] = [:]
        for child in ["Helpers", "archives", "apps"] {
            let fd = try BackupFS.directory(root.appendingPathComponent(child))
            do {
                try DirectAssessmentHelper.validatePrivateDirectory(fd)
                identities[child] = OwnerWorkspaceDirectory(fd, try BackupFS.identity(fd))
            } catch { close(fd); throw error }
        }
        return identities
    }
}
/// Retaining the descriptor reserves the inode as well as checking its number.
/// Recreated private directories cannot silently become the operation's stage.
private final class OwnerWorkspaceDirectory {
    let descriptor: Int32, identity: BackupIdentity
    init(_ descriptor: Int32, _ identity: BackupIdentity) { self.descriptor = descriptor; self.identity = identity }
    deinit { close(descriptor) }
}
