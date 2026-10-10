import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

struct BrowserDataBackupStorageTests {
    private let password = "storage fixture password 🔐"
    private let fs = FileManager.default

    @Test func encryptedExportAndPrivateStagePreserveOwnBrowserDataBytes() throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), archive = root.appendingPathComponent("own.nabackup")
        let original = try bytes(source)
        let manifest = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        #expect(manifest.entries.count == 10)
        #expect(try bytes(source) == original)
        let stage = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password)
        #expect(stage.manifest == manifest)
        #expect(try bytes(stage.url) == original)
        #expect(try bytes(source) == original)
        #expect((try fs.attributesOfItem(atPath: stage.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try fs.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try stage.discard(); try stage.discard()
        #expect(!fs.fileExists(atPath: stage.url.path))
        #expect(try fs.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".neantik-") }.isEmpty)
    }

    @Test func explicitRestoreStageNameIsStrictAndNeverAdoptsCollision() throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), archive = root.appendingPathComponent("own.nabackup")
        _ = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        for name in ["../outside", ".neantik-backup-restore-../outside", ".neantik-backup-restore-not-a-uuid", "BrowserData"] {
            #expect(throws: BrowserDataBackupStorageError.unsafeEntry) {
                try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password, stageName: name)
            }
        }
        let name = ".neantik-backup-restore-" + UUID().uuidString.lowercased()
        let stage = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password, stageName: name)
        #expect(stage.url.lastPathComponent == name)
        #expect(throws: (any Error).self) {
            try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password, stageName: name)
        }
        try stage.validatePreparedContents(); try stage.discard()
    }

    @Test(arguments: ["symlink", "hardlink", "fifo", "ancestor"])
    func unsafeSourceRefusesBeforePublishing(kind: String) throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), destination = root.appendingPathComponent("own.nabackup")
        let outside = root.appendingPathComponent("outside"); try Data([7]).write(to: outside)
        let bad = source.appendingPathComponent("Default/bad")
        switch kind {
        case "symlink": try fs.createSymbolicLink(at: bad, withDestinationURL: outside)
        case "hardlink": try fs.linkItem(at: outside, to: bad)
        case "fifo": try #require(mkfifo(bad.path, 0o600) == 0)
        default:
            let old = source.appendingPathComponent("Default")
            try fs.moveItem(at: old, to: root.appendingPathComponent("moved"))
            try fs.createSymbolicLink(at: old, withDestinationURL: root.appendingPathComponent("moved"))
        }
        #expect(throws: (any Error).self) { try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: destination, password: password) }
        #expect(!fs.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: outside) == Data([7]))
    }

    @Test(arguments: ["ENOSPC", "cancel", "changed-source", "collision", "changed-parent"])
    func exportFailuresPreserveSourceAndExistingDestination(kind: String) throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), parent = root.appendingPathComponent("output")
        try fs.createDirectory(at: parent, withIntermediateDirectories: false)
        let archive = parent.appendingPathComponent("own.nabackup"), sentinel = Data("existing destination".utf8)
        #expect(throws: (any Error).self) {
            try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password, fault: { point in
                switch point {
                case .frameWritten(1) where kind == "ENOSPC": throw CocoaError(.fileWriteOutOfSpace)
                case .frameWritten(1) where kind == "cancel": throw CancellationError()
                case .beforePublish where kind == "changed-source": try Data([1]).write(to: source.appendingPathComponent("Default/Cookies"))
                case .beforePublish where kind == "collision": try sentinel.write(to: archive)
                case .beforePublish where kind == "changed-parent":
                    try fs.moveItem(at: parent, to: root.appendingPathComponent("moved-output"))
                    try fs.createDirectory(at: parent, withIntermediateDirectories: false)
                default: break
                }
            })
        }
        if kind == "collision" { #expect(try Data(contentsOf: archive) == sentinel) }
        else { #expect(!fs.fileExists(atPath: archive.path)) }
        let pendingParent = kind == "changed-parent" ? root.appendingPathComponent("moved-output") : parent
        #expect(try fs.contentsOfDirectory(atPath: pendingParent.path).filter { $0.hasSuffix(".partial") }.isEmpty)
        #expect(try Data(contentsOf: source.appendingPathComponent("Default/IndexedDB/fixture")) == Data("own IndexedDB".utf8))
    }

    @Test(arguments: ["wrong-password", "corrupt", "truncated", "incompatible", "ENOSPC"])
    func failedRestoreStageNeverTouchesLiveDataAndCleansPrivateStage(kind: String) throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), archive = root.appendingPathComponent("own.nabackup")
        _ = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        let original = try bytes(source)
        if kind == "corrupt" || kind == "truncated" {
            var data = try Data(contentsOf: archive)
            if kind == "corrupt" { data[data.count - 1] ^= 1 } else { data.removeLast(5) }
            try data.write(to: archive)
        }
        var expected = context()
        if kind == "incompatible" { expected = context(id: UUID()) }
        #expect(throws: (any Error).self) {
            try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: expected,
                password: kind == "wrong-password" ? "different password" : password,
                fault: { point in if case .restoredChunk = point, kind == "ENOSPC" { throw CocoaError(.fileWriteOutOfSpace) } })
        }
        #expect(try bytes(source) == original)
        #expect(try fs.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".neantik-backup-restore-") }.isEmpty)
    }

    @Test func trueTaskCancellationStillDiscardsPartialPlaintextStage() async throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), archive = root.appendingPathComponent("own.nabackup")
        _ = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        let original = try bytes(source)
        let task = Task {
            try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password, fault: { point in
                if case .restoreBegan = point { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; Issue.record("Cancelled restore unexpectedly returned success") }
        catch { #expect(error is CancellationError) }
        #expect(try bytes(source) == original)
        #expect(try fs.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".neantik-backup-restore-") }.isEmpty)
    }

    @Test func substitutedStageFileIsPreservedInsteadOfAdoptedOrRemoved() throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), archive = root.appendingPathComponent("own.nabackup")
        _ = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        let stage = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password)
        let target = stage.url.appendingPathComponent("Default/Cookies"), old = root.appendingPathComponent("old-cookie")
        try fs.moveItem(at: target, to: old)
        let replacement = Data("foreign synthetic file".utf8); try replacement.write(to: target)
        #expect(throws: BrowserDataBackupStorageError.changed) { try stage.discard() }
        #expect(try Data(contentsOf: target) == replacement)
        #expect(try Data(contentsOf: old) == Data("own cookies".utf8))
    }

    @Test func emptyStageRootReplacementBetweenCheckAndCaptureRefuses() throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = root.appendingPathComponent("BrowserData"); try fs.createDirectory(at: source, withIntermediateDirectories: false)
        let archive = root.appendingPathComponent("own.nabackup")
        _ = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        let stage = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password)
        let saved = root.appendingPathComponent("retained-empty-stage")
        #expect(throws: BrowserDataBackupStorageError.changed) {
            try stage.validatePreparedContents(afterRootValidation: {
                try fs.moveItem(at: stage.url, to: saved)
                try fs.createDirectory(at: stage.url, withIntermediateDirectories: false)
            })
        }
        #expect(fs.fileExists(atPath: stage.url.path) && fs.fileExists(atPath: saved.path))
        #expect(throws: BrowserDataBackupStorageError.changed) { try stage.discard() }
    }

    @Test func privateStageCannotAdoptAnUnlistedSingletonSymlink() throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), archive = root.appendingPathComponent("own.nabackup")
        let outside = root.appendingPathComponent("outside"); try Data("preserve".utf8).write(to: outside)
        // A stopped browser's stale singleton is an explicit export exclusion.
        try fs.createSymbolicLink(at: source.appendingPathComponent("SingletonLock"), withDestinationURL: outside)
        _ = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        let stage = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password)
        try fs.createSymbolicLink(at: stage.url.appendingPathComponent("SingletonLock"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try stage.validatePreparedContents() }
        #expect(throws: (any Error).self) { try stage.discard() }
        #expect(try Data(contentsOf: outside) == Data("preserve".utf8))
        #expect(try fs.destinationOfSymbolicLink(atPath: stage.url.appendingPathComponent("SingletonLock").path) == outside.path)
    }

    @Test func cancelledEmptyArchiveCannotReturnSuccess() async throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = root.appendingPathComponent("BrowserData"); try fs.createDirectory(at: source, withIntermediateDirectories: false)
        let archive = root.appendingPathComponent("own.nabackup")
        _ = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        let task = Task {
            try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password, fault: {
                if case .restoreVerified = $0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; Issue.record("Cancelled empty restore returned success") }
        catch { #expect(error is CancellationError) }
        #expect(try fs.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".neantik-backup-restore-") }.isEmpty)
    }

    @Test func openedDescriptorsCloseWhenIdentityCaptureThrows() throws {
        let root = try fixture(); defer { try? fs.removeItem(at: root) }
        let source = try populate(root), archive = root.appendingPathComponent("own.nabackup")
        var output: Int32 = -1
        var outputBefore = stat()
        #expect(throws: POSIXError(.EIO)) {
            try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password, fault: {
                if case .outputIdentity(let fd) = $0 { output = fd; _ = fstat(fd, &outputBefore); throw POSIXError(.EIO) }
            })
        }
        var outputAfter = stat()
        let outputResult = fstat(output, &outputAfter)
        #expect(output >= 0 && (outputResult < 0 || outputAfter.st_dev != outputBefore.st_dev || outputAfter.st_ino != outputBefore.st_ino))
        _ = try BrowserDataBackupStorage.export(browserData: source, context: context(), destination: archive, password: password)
        var restoreRoot: Int32 = -1
        var restoreBefore = stat()
        #expect(throws: POSIXError(.EIO)) {
            try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: root, expectedContext: context(), password: password, fault: {
                if case .restoreRootIdentity(let fd) = $0 { restoreRoot = fd; _ = fstat(fd, &restoreBefore); throw POSIXError(.EIO) }
            })
        }
        var restoreAfter = stat()
        let restoreResult = fstat(restoreRoot, &restoreAfter)
        #expect(restoreRoot >= 0 && (restoreResult < 0 || restoreAfter.st_dev != restoreBefore.st_dev || restoreAfter.st_ino != restoreBefore.st_ino))
        // No inode proof exists after this injected failure. Private unknown
        // objects are preserved rather than deleted by prefix or assumption.
        #expect(try fs.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-backup-storage-\(UUID().uuidString)")
        try fs.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func populate(_ root: URL) throws -> URL {
        let source = root.appendingPathComponent("BrowserData")
        for directory in ["Default", "Default/IndexedDB", "Default/Local Storage", "Default/Sessions", "Default/Empty"] {
            try fs.createDirectory(at: source.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for (path, bytes) in ["Default/Cookies": Data("own cookies".utf8), "Default/IndexedDB/fixture": Data("own IndexedDB".utf8),
                              "Default/Local Storage/fixture": Data("own localStorage".utf8), "Default/Sessions/fixture": Data("own tabs".utf8),
                              "Default/empty-file": Data()] { try bytes.write(to: source.appendingPathComponent(path)) }
        return source
    }
    private func bytes(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let iterator = try #require(fs.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in iterator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            result[path] = try Data(contentsOf: url)
        }
        return result
    }
    private func context(id: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!) -> EncryptedBackupArchive.Manifest {
        let hash = SHA256.hash(data: Data("synthetic context".utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(profileID: id, identitySHA256: hash, runtimeExecutableSHA256: hash, runtimeFrameworkSHA256: hash,
                     runtimeVersion: "156.0.8078.12", compatibilityScopeSHA256: hash, entries: [])
    }
}
