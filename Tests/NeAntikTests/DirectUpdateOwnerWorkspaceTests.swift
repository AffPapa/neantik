import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DirectUpdateCore

@Suite(.serialized) struct DirectUpdateOwnerWorkspaceTests {
    @Test func fixedManagerLayoutDoesNotAcceptASelectedTarget() throws {
        let app = URL(fileURLWithPath: "/synthetic/Applications/NeAntik.app")
        let observed = try DirectUpdateOwnerAuthentication.installedApp(executable: app.appendingPathComponent("Contents/MacOS/NeAntik"))
        #expect(observed.path == app.path)
        for path in ["/synthetic/Other.app/Contents/MacOS/NeAntik", "/synthetic/NeAntik.app/Contents/MacOS/Other",
                     "/synthetic/NeAntik.app/Helpers/NeAntik", "/synthetic/NeAntik.app/Contents/MacOS/NeAntikUpdateOwner"] {
            #expect(throws: DirectUpdateInstallSessionError.identity) {
                try DirectUpdateOwnerAuthentication.installedApp(executable: URL(fileURLWithPath: path))
            }
        }
        // A test runner/terminal is not an authenticated installed manager.
        #expect(throws: (any Error).self) { try DirectUpdateOwnerAuthentication.authenticate() }
    }
    @Test func earlyCancellationAndDrainedAcknowledgementBindTheExactSession() throws {
        let manifest = Data([1, 2]), archive = URL(fileURLWithPath: "/synthetic/archive.zip")
        let a = try DirectUpdateOwnerInit(archive: archive, manifest: manifest, nonce: Data(repeating: 1, count: 32))
        let b = try DirectUpdateOwnerInit(archive: archive, manifest: manifest, nonce: Data(repeating: 2, count: 32))
        #expect(DirectUpdateOwnerConsent.earlyCancel(request: a).count == 68)
        #expect(DirectUpdateOwnerConsent.cancelled(request: a).count == 68)
        #expect(DirectUpdateOwnerConsent.earlyCancel(request: a) != DirectUpdateOwnerConsent.earlyCancel(request: b))
        #expect(DirectUpdateOwnerConsent.cancelled(request: a) != DirectUpdateOwnerConsent.cancelled(request: b))
        #expect(DirectUpdateOwnerConsent.cancelled(request: a) != DirectUpdateOwnerConsent.earlyCancel(request: a))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_HELPER_PACKAGE_QA"] != nil))
    func actualSignedRelocationSurvivesRemovedSourceAndRefusesReplacement() throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_HELPER_PACKAGE_QA"]))
        let source = fixture.deletingLastPathComponent().appendingPathComponent("PolicyQA.app")
        let root = URL(fileURLWithPath: "/private/tmp/neantik-update-helper-package-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("isolated-update-helper-package-qa\n".utf8).write(to: root.appendingPathComponent("fixture.marker"))
        let app = root.appendingPathComponent("PolicyQA.app")
        try FileManager.default.copyItem(at: source, to: app)
        let policy = try DirectUpdateInstalledPolicy.qualification(app: app)
        let workspace = try DirectUpdateOwnerWorkspace.prepare(policy: policy)
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try workspace.validate()
        let recaptured = try DirectUpdateOwnerWorkspace.inspect(ownerExecutable: workspace.owner.url, policy: policy)
        try recaptured.validate()
        #expect(workspace.owner.url.deletingLastPathComponent().deletingLastPathComponent().path == workspace.root.path)
        #expect(!workspace.owner.url.path.hasPrefix(app.path + "/"))
        for pair in [(policy.owner, workspace.owner), (policy.assessment, workspace.assessment)] {
            let original = try Data(contentsOf: pair.0.url), copy = try Data(contentsOf: pair.1.url)
            #expect(original == copy)
            let fd = open(pair.1.url.path, O_RDONLY | O_NOFOLLOW); defer { close(fd) }
            let identity = try BackupFS.identity(fd)
            #expect(identity.links == 1 && identity.mode & 0o7777 == 0o500)
        }
        let unsafe = workspace.root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(throws: (any Error).self) { try policy.owner.relocate(to: unsafe) }
        try FileManager.default.removeItem(at: unsafe)
        #expect(throws: (any Error).self) { try policy.owner.relocate(to: workspace.owner.url.deletingLastPathComponent()) }
        // Source removal simulates the old app leaving its slot. Copied helper
        // custody remains valid without adopting files from the new app.
        try FileManager.default.removeItem(at: app)
        try workspace.validate(); try recaptured.validate()
        #expect(throws: (any Error).self) { try policy.validate() }
        let bytes = try Data(contentsOf: workspace.owner.url)
        let replacement = workspace.owner.url.deletingLastPathComponent().appendingPathComponent("replacement")
        try bytes.write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: replacement.path)
        try #require(rename(replacement.path, workspace.owner.url.path) == 0)
        #expect(throws: (any Error).self) { try workspace.validate() }
        #expect(throws: (any Error).self) { try recaptured.validate() }
        try workspace.assessment.validate()
        // Restoring bytes by another inode cannot restore the old capture.
        // Likewise, a new private directory must not silently replace custody.
        let second = try DirectUpdateOwnerWorkspace.prepare(policy: DirectUpdateInstalledPolicy.qualification(app: source))
        defer { try? FileManager.default.removeItem(at: second.root) }
        try FileManager.default.removeItem(at: second.archives)
        try FileManager.default.createDirectory(at: second.archives, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(throws: (any Error).self) { try second.validate() }
    }
}
