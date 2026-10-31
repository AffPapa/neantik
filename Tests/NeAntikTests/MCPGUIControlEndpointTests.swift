import Darwin
import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized)
struct MCPGUIControlEndpointTests {
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-own-mcp-endpoint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return value
    }

    @Test func privateDescriptorBindsThisLibraryAndSocketAndCleansOnce() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        let endpoint = try MCPGUIControlEndpoint.Listener(library: library, generation: UUID())
        defer { endpoint.cleanup() }
        let client = try MCPGUIControlEndpoint.Library(root: root, exclusive: false)
        let (value, captured) = try client.read()
        #expect(value == endpoint.value)
        #expect(value.libraryIdentitySHA256 == library.identitySHA256)
        #expect(client.fileIsCurrent(captured) && endpoint.isCurrent)
        #expect(throws: (any Error).self) { try MCPGUIControlEndpoint.Library(root: root, exclusive: true) }
        endpoint.cleanup()
        #expect(!endpoint.isCurrent)
        #expect(!FileManager.default.fileExists(atPath: MCPGUIControlEndpoint.rootPath(value.generation)))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(MCPGUIControlEndpoint.descriptorName).path))
        let marker = root.appendingPathComponent("own-fd-marker")
        let fd = Darwin.open(marker.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try #require(fd >= 0); defer { _ = Darwin.close(fd) }
        endpoint.cleanup() // Must not close a descriptor reused after cleanup.
        #expect(fcntl(fd, F_GETFD) >= 0)
    }

    @Test func replacedDescriptorIsPreservedAndNeverAdopted() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        let endpoint = try MCPGUIControlEndpoint.Listener(library: library, generation: UUID())
        defer { endpoint.cleanup() }
        let file = root.appendingPathComponent(MCPGUIControlEndpoint.descriptorName)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("retained-own-descriptor"))
        let marker = Data("synthetic replacement; preserve".utf8)
        try marker.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(!endpoint.isCurrent)
        #expect(throws: (any Error).self) { try library.read() }
        endpoint.cleanup()
        #expect(try Data(contentsOf: file) == marker)
    }

    @Test func replacedSocketDirectoryAndForeignFileArePreserved() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        let endpoint = try MCPGUIControlEndpoint.Listener(library: library, generation: UUID())
        let path = URL(fileURLWithPath: MCPGUIControlEndpoint.rootPath(endpoint.value.generation))
        let held = URL(fileURLWithPath: path.path + "-own-held")
        defer { endpoint.cleanup(); try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: held) }
        try FileManager.default.moveItem(at: path, to: held)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let marker = path.appendingPathComponent("socket")
        try Data("preserve replacement socket name".utf8).write(to: marker)
        #expect(!endpoint.isCurrent)
        endpoint.cleanup()
        #expect(try String(contentsOf: marker, encoding: .utf8) == "preserve replacement socket name")
        #expect(FileManager.default.fileExists(atPath: held.appendingPathComponent("socket").path))
    }

    @Test func lockAndRootReplacementInvalidateHeldCustody() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        let lock = root.appendingPathComponent(".mcp-gui-control.lock")
        try FileManager.default.moveItem(at: lock, to: root.appendingPathComponent("retained-own-lock"))
        try Data().write(to: lock); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        #expect(!library.isCurrent)
        #expect(throws: (any Error).self) { try MCPGUIControlEndpoint.Listener(library: library, generation: UUID()) }
        let held = root.appendingPathExtension("own-held")
        defer { try? FileManager.default.removeItem(at: held) }
        try FileManager.default.moveItem(at: root, to: held)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(!library.isCurrent)
    }

    @Test func symlinkHardlinkAndMalformedDescriptorCannotBecomeAuthority() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        let file = root.appendingPathComponent(MCPGUIControlEndpoint.descriptorName)
        let target = root.appendingPathComponent("own-target")
        try Data("synthetic bytes".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try library.read() }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        #expect(throws: (any Error).self) { try library.read() }
        #expect(throws: (any Error).self) { try library.retireStaleIfPresent() }
        #expect(try Data(contentsOf: target) == Data("synthetic bytes".utf8))
    }

    @Test func liveOwnerDescriptorCannotBeRetiredAsCrashResidue() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        let endpoint = try MCPGUIControlEndpoint.Listener(library: library, generation: UUID())
        defer { endpoint.cleanup() }
        #expect(!endpoint.value.ownerDefinitelyGone)
        #expect(throws: MCPGUIControlProtocol.Failure.busy) { try library.retireStaleIfPresent() }
        #expect(endpoint.isCurrent)
        let anotherRoot = try self.root(); defer { try? FileManager.default.removeItem(at: anotherRoot) }
        let another = try MCPGUIControlEndpoint.Library(root: anotherRoot, exclusive: true)
        #expect(another.identitySHA256 != library.identitySHA256)
        #expect(throws: MCPGUIControlProtocol.Failure.unavailable) { try another.publish(endpoint.value) }
    }

    @Test func interruptionBeforeCommitNeverPublishesPartialDescriptor() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        let endpoint = try MCPGUIControlEndpoint.Listener(library: library, generation: UUID())
        defer { endpoint.cleanup() }
        library.retire(endpoint.file)
        let file = root.appendingPathComponent(MCPGUIControlEndpoint.descriptorName)
        enum OwnFailure: Error { case beforeRename }
        #expect(throws: OwnFailure.beforeRename) {
            try library.publishForTesting(endpoint.value) {
                #expect(!FileManager.default.fileExists(atPath: file.path))
                throw OwnFailure.beforeRename
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let published = try library.publish(endpoint.value)
        defer { library.retire(published) }
        #expect(try library.read().0 == endpoint.value)
    }

    @Test func atomicPublishCannotReplaceAFileCreatedBeforeCommit() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        let endpoint = try MCPGUIControlEndpoint.Listener(library: library, generation: UUID())
        defer { endpoint.cleanup() }
        library.retire(endpoint.file)
        let file = root.appendingPathComponent(MCPGUIControlEndpoint.descriptorName)
        let marker = Data("own simulated concurrent replacement".utf8)
        #expect(throws: MCPGUIControlProtocol.Failure.busy) {
            try library.publishForTesting(endpoint.value) {
                try marker.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        #expect(try Data(contentsOf: file) == marker)
        let stages = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".mcp-gui-control-stage-") }
        #expect(stages.isEmpty)
    }
}
