import Darwin
import Foundation
import Testing
@testable import DirectInstallFilesystem
private final class InstallFilesystemTestBundle: NSObject {}

@Suite(.serialized)
struct DirectInstallFilesystemTests {
    struct Fixture {
        let root: URL, candidateName: String
        init() throws {
            var template = Array("/private/tmp/neantik-install-fixture-XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else { throw POSIXError(.EIO) }
            root = URL(fileURLWithPath: String(cString: path))
            candidateName = ".neantik-next-" + UUID().uuidString.lowercased() + ".app"
            try Data("isolated-install-filesystem-qa\n".utf8).write(to: root.appendingPathComponent("fixture.marker"))
            try Data(candidateName.utf8).write(to: root.appendingPathComponent("candidate.name"))
            try tree("NeAntik.app", version: "old"); try tree(candidateName, version: "new")
        }
        func tree(_ name: String, version: String) throws {
            let base = root.appendingPathComponent(name)
            let framework = base.appendingPathComponent("Contents/Frameworks/Fixture.framework")
            let actual = framework.appendingPathComponent("Versions/A")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: base.appendingPathComponent("Contents/version"))
            try Data((version + "-framework").utf8).write(to: actual.appendingPathComponent("value"))
            #expect(symlink("A", framework.appendingPathComponent("Versions/Current").path) == 0)
            #expect(symlink("Versions/Current/value", framework.appendingPathComponent("value").path) == 0)
        }
        func version(_ name: String = "NeAntik.app") throws -> String {
            try String(contentsOf: root.appendingPathComponent(name + "/Contents/version"), encoding: .utf8)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        var active: URL { root.appendingPathComponent(InstallFilesystemTransaction.activeName) }
        func begin(_ lease: InstallFilesystemLease, fault: ((InstallFilesystemPoint) throws -> Void)? = nil) throws -> InstallFilesystemReceipt {
            try InstallFilesystemTransaction.begin(lease: lease, candidateName: candidateName,
                candidateReceiptSHA256: String(repeating: "a", count: 64), validateStoppedAuthority: {}, fault: fault)
        }
    }
    private func executable() throws -> URL {
        for base in [Bundle(for: InstallFilesystemTestBundle.self).bundleURL,
                     URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()] {
            var path = base
            for _ in 0..<6 {
                let candidate = path.appendingPathComponent("NeAntikInstallFilesystemFixture")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                path.deleteLastPathComponent()
            }
        }
        throw InstallFilesystemError.unsupported
    }
    private func child(_ fixture: Fixture, _ action: String, _ point: String = "none") throws -> Int32 {
        let process = Process(); process.executableURL = try executable()
        process.arguments = [action, fixture.root.path, point]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": "/private/tmp", "LANG": "C"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
    @Test(arguments: [InstallFilesystemPoint.prepared, .journalWrittenBeforeSync, .journalFileSynced, .journalSynced, .beforeActivation, .activatedBeforeSync,
                      .intentDurable, .beforeSwap, .swappedBeforeSync, .pendingLaunch])
    func realProcessCrashBeforeAcknowledgementRestoresOld(point: InstallFilesystemPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try child(f, "begin", point.rawValue) == 73)
        #expect(try child(f, "recover") == 0)
        #expect(try f.version() == "old"); #expect(try f.version(f.candidateName) == "new")
        #expect(try child(f, "recover") == 0)
        if [.prepared, .journalWrittenBeforeSync, .journalFileSynced, .journalSynced, .beforeActivation].contains(point) {
            #expect(!FileManager.default.fileExists(atPath: f.active.path))
            #expect(try child(f, "begin") == 74) // orphan retained, no silent cleanup/adoption
        }
    }
    @Test(arguments: [InstallFilesystemPoint.beforeAcknowledgement, .acknowledgementWrittenBeforeSync, .acknowledgementFileSynced, .beforeAcknowledgementPublication, .acknowledgementPublishedBeforeSync,
                      .acknowledgementDurable, .beforeFinish, .finalizedBeforeSync, .finished])
    func realProcessCrashDuringAcknowledgementUsesVisibleDecision(point: InstallFilesystemPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try child(f, "begin") == 0); #expect(try f.version() == "new")
        #expect(try child(f, "ack", point.rawValue) == 73)
        #expect(try child(f, "recover") == 0)
        let committed = ![InstallFilesystemPoint.beforeAcknowledgement, .acknowledgementWrittenBeforeSync, .acknowledgementFileSynced, .beforeAcknowledgementPublication].contains(point)
        #expect(try f.version() == (committed ? "new" : "old"))
        #expect(try f.version(f.candidateName) == (committed ? "old" : "new"))
        #expect(try child(f, "recover") == 0)
    }
    @Test(arguments: [InstallFilesystemPoint.beforeRollback, .beforeRollbackSwap, .rolledBackBeforeSync, .rollbackDurable,
                      .beforeFinish, .finalizedBeforeSync, .finished])
    func realProcessCrashDuringRollbackNeverSwapsTwice(point: InstallFilesystemPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try child(f, "begin") == 0)
        #expect(try child(f, "recover", point.rawValue) == 73)
        #expect(try child(f, "recover") == 0); #expect(try child(f, "recover") == 0)
        #expect(try f.version() == "old"); #expect(try f.version(f.candidateName) == "new")
    }
    @Test func twoFreshProcessesCannotHoldLeaseTogether() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = try executable(); process.arguments = ["hold", f.root.path, "none"]
        process.standardOutput = output; process.standardInput = input; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try #require(output.fileHandleForReading.readData(ofLength: 5) == Data("held\n".utf8))
        #expect(try child(f, "begin") == 75)
        input.fileHandleForWriting.write(Data([1])); process.waitUntilExit()
        #expect(process.terminationStatus == 0); #expect(try child(f, "begin") == 0)
    }
    @Test(arguments: ["body", "root", "journal", "extra", "lock", "hardlink", "symlink", "parentMode", "commit"])
    func changedObjectsRetainBothTreesAndFence(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try child(f, "begin") == 0)
        switch control {
        case "body": try Data("changed".utf8).write(to: f.root.appendingPathComponent("NeAntik.app/Contents/version"))
        case "root":
            try FileManager.default.moveItem(at: f.root.appendingPathComponent("NeAntik.app"), to: f.root.appendingPathComponent("unknown.app"))
            try f.tree("NeAntik.app", version: "new") // same content, different inode
        case "journal": try Data("{}".utf8).write(to: f.active.appendingPathComponent("journal.json"))
        case "extra": try Data([1]).write(to: f.active.appendingPathComponent("unknown"))
        case "lock":
            try FileManager.default.removeItem(at: f.root.appendingPathComponent(InstallFilesystemLease.lockName))
            try Data().write(to: f.root.appendingPathComponent(InstallFilesystemLease.lockName))
            #expect(chmod(f.root.appendingPathComponent(InstallFilesystemLease.lockName).path, 0o600) == 0)
        case "hardlink": #expect(link(f.active.appendingPathComponent("journal.json").path, f.root.appendingPathComponent("unknown-link").path) == 0)
        case "symlink":
            try FileManager.default.moveItem(at: f.active, to: f.root.appendingPathComponent("unknown-journal"))
            #expect(symlink("unknown-journal", f.active.path) == 0)
        case "parentMode": #expect(chmod(f.root.path, 0o755) == 0)
        default:
            try Data("foreign-ack".utf8).write(to: f.active.appendingPathComponent("commit.json"))
            #expect(chmod(f.active.appendingPathComponent("commit.json").path, 0o600) == 0)
        }
        #expect(try child(f, "recover") == 74)
        #expect(FileManager.default.fileExists(atPath: f.active.path))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.candidateName).path))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("NeAntik.app").path))
    }
    @Test func partialAcknowledgementIsRetainedAndNeverCommits() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try child(f, "begin") == 0)
        let file = f.active.appendingPathComponent("ack.pending")
        try Data("{partial".utf8).write(to: file); #expect(chmod(file.path, 0o600) == 0)
        #expect(try child(f, "recover") == 0); #expect(try f.version() == "old")
        let retired = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".neantik-install-rolledback-") }
        #expect(FileManager.default.fileExists(atPath: try #require(retired).appendingPathComponent("ack.pending").path))
    }
    @Test func staleReceiptAndLiveLaunchRefuseAcknowledgement() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let lease = try InstallFilesystemLease(parentURL: f.root), receipt = try f.begin(lease)
        var object = try #require(JSONSerialization.jsonObject(with: InstallFS.encode(receipt)) as? [String: Any])
        object["transactionID"] = UUID().uuidString
        let stale = try JSONDecoder().decode(InstallFilesystemReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: InstallFilesystemError.invalidAcknowledgement) {
            try InstallFilesystemTransaction.acknowledge(lease: lease, expected: stale, validateLaunchAuthority: {})
        }
        #expect(throws: InstallFilesystemError.busy) {
            try InstallFilesystemTransaction.acknowledge(lease: lease, expected: receipt, validateLaunchAuthority: { throw InstallFilesystemError.busy })
        }
        #expect(!FileManager.default.fileExists(atPath: f.active.appendingPathComponent("commit.json").path))
        #expect(throws: InstallFilesystemError.busy) {
            try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: { throw InstallFilesystemError.busy })
        }
        #expect(try f.version() == "new")
        #expect(try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {})?.committed == false)
    }
    @Test func syncFailureAndLateAuthorityLossPreserveRecovery() throws {
        for point in [InstallFilesystemPoint.activatedBeforeSync, .swappedBeforeSync] {
            let f = try Fixture(); defer { f.cleanup() }
            let lease = try InstallFilesystemLease(parentURL: f.root)
            #expect(throws: POSIXError(.EIO)) { try f.begin(lease, fault: { if $0 == point { throw POSIXError(.EIO) } }) }
            #expect(FileManager.default.fileExists(atPath: f.active.path))
            #expect(try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {})?.committed == false)
            #expect(try f.version() == "old")
        }
        let f = try Fixture(); defer { f.cleanup() }
        let lease = try InstallFilesystemLease(parentURL: f.root); var authority = true
        #expect(throws: InstallFilesystemError.busy) {
            try InstallFilesystemTransaction.begin(lease: lease, candidateName: f.candidateName,
                candidateReceiptSHA256: String(repeating: "a", count: 64),
                validateStoppedAuthority: { if !authority { throw InstallFilesystemError.busy } },
                fault: { if $0 == .beforeSwap { authority = false } })
        }
        #expect(try f.version() == "old"); #expect(FileManager.default.fileExists(atPath: f.active.path))
    }
    @Test(arguments: ["hardlink", "escape", "composedEscape", "cycle", "missingTarget", "fileAncestor", "rootlink", "worldWrite", "badCandidate"])
    func unsafeInputRefusesBeforeIntent(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent(f.candidateName)
        switch control {
        case "hardlink": #expect(link(app.appendingPathComponent("Contents/version").path, f.root.appendingPathComponent("link").path) == 0)
        case "escape": #expect(symlink("../../outside", app.appendingPathComponent("escape").path) == 0)
        case "composedEscape":
            try FileManager.default.createDirectory(at: app.appendingPathComponent("dir"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("safe"), withIntermediateDirectories: true)
            #expect(symlink("../safe", app.appendingPathComponent("dir/back").path) == 0)
            #expect(symlink("back/../../outside", app.appendingPathComponent("dir/escape").path) == 0)
        case "cycle":
            #expect(symlink("cycle2", app.appendingPathComponent("cycle1").path) == 0)
            #expect(symlink("cycle1", app.appendingPathComponent("cycle2").path) == 0)
        case "missingTarget": #expect(symlink("absent", app.appendingPathComponent("link").path) == 0)
        case "fileAncestor": #expect(symlink("Contents/version/child", app.appendingPathComponent("link").path) == 0)
        case "rootlink":
            try FileManager.default.moveItem(at: app, to: f.root.appendingPathComponent("unknown"))
            #expect(symlink("unknown", app.path) == 0)
        case "worldWrite": #expect(chmod(app.appendingPathComponent("Contents/version").path, 0o666) == 0)
        default: break
        }
        let lease = try InstallFilesystemLease(parentURL: f.root)
        #expect(throws: (any Error).self) {
            try InstallFilesystemTransaction.begin(lease: lease, candidateName: control == "badCandidate" ? "../NeAntik.app" : f.candidateName,
                candidateReceiptSHA256: String(repeating: "a", count: 64), validateStoppedAuthority: {})
        }
        #expect(!FileManager.default.fileExists(atPath: f.active.path)); #expect(try f.version() == "old")
    }
    @Test func parentModeAndRootOwnedSystemDirectoryAreUnsupportedWithoutMutation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(chmod(f.root.path, 0o755) == 0)
        #expect(throws: InstallFilesystemError.unsupported) { try InstallFilesystemLease(parentURL: f.root) }
        var observed = stat(); #expect(lstat(f.root.path, &observed) == 0); #expect(observed.st_mode & 0o777 == 0o755)
        #expect(throws: (any Error).self) { try InstallFilesystemLease(parentURL: URL(fileURLWithPath: "/Applications")) }
        #expect(!FileManager.default.fileExists(atPath: "/Applications/" + InstallFilesystemLease.lockName))
    }
    @Test(arguments: ["parentACL", "fileACL", "flags", "depth", "bytes", "ancestorLink"])
    func actualPlatformAndResourceLimitsRefuse(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = f.root.appendingPathComponent(f.candidateName + "/Contents/version")
        switch control {
        case "parentACL", "fileACL":
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "everyone allow read", control == "parentACL" ? f.root.path : file.path]
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
        case "flags":
            try #require(chflags(file.path, UInt32(UF_NODUMP)) == 0)
            defer { _ = chflags(file.path, 0) }
            let lease = try InstallFilesystemLease(parentURL: f.root)
            #expect(throws: InstallFilesystemError.unsafe) { try f.begin(lease) }
            #expect(!FileManager.default.fileExists(atPath: f.active.path)); return
        case "depth":
            let path = (0..<34).map { "d\($0)" }.joined(separator: "/")
            try FileManager.default.createDirectory(at: f.root.appendingPathComponent(f.candidateName + "/" + path), withIntermediateDirectories: true)
        case "bytes":
            let fd = open(file.path, O_WRONLY); try #require(fd >= 0); defer { close(fd) }
            try #require(ftruncate(fd, 1_073_741_825) == 0) // sparse; rejected before reading >1GiB
        default:
            let alias = URL(fileURLWithPath: f.root.path + "-alias")
            try #require(symlink(f.root.path, alias.path) == 0); defer { try? FileManager.default.removeItem(at: alias) }
            #expect(throws: InstallFilesystemError.unsafe) { try InstallFilesystemLease(parentURL: alias) }; return
        }
        #expect(throws: (any Error).self) { let lease = try InstallFilesystemLease(parentURL: f.root); _ = try f.begin(lease) }
        #expect(!FileManager.default.fileExists(atPath: f.active.path))
    }
    @Test func finalAuthorityChecksPrecedeAckAndRollback() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let lease = try InstallFilesystemLease(parentURL: f.root), receipt = try f.begin(lease)
        var valid = true
        #expect(throws: InstallFilesystemError.busy) {
            try InstallFilesystemTransaction.acknowledge(lease: lease, expected: receipt,
                validateLaunchAuthority: { if !valid { throw InstallFilesystemError.busy } },
                fault: { if $0 == .beforeAcknowledgementPublication { valid = false } })
        }
        #expect(!FileManager.default.fileExists(atPath: f.active.appendingPathComponent("commit.json").path))
        valid = true
        #expect(throws: InstallFilesystemError.busy) {
            try InstallFilesystemTransaction.recover(lease: lease,
                validateStoppedAuthority: { if !valid { throw InstallFilesystemError.busy } },
                fault: { if $0 == .beforeRollbackSwap { valid = false } })
        }
        #expect(try f.version() == "new")
        #expect(try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {})?.committed == false)
    }
    @Test(arguments: [InstallFilesystemPoint.intentDurable, .swappedBeforeSync, .beforeAcknowledgementPublication, .acknowledgementPublishedBeforeSync])
    func actualTaskCancellationFollowsDecisionBoundary(point: InstallFilesystemPoint) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let operation = Task.detached {
            let lease = try InstallFilesystemLease(parentURL: f.root)
            let cancel: (InstallFilesystemPoint) throws -> Void = { if $0 == point { withUnsafeCurrentTask { $0?.cancel() } } }
            if [.intentDurable, .swappedBeforeSync].contains(point) { _ = try f.begin(lease, fault: cancel) }
            else {
                let receipt = try f.begin(lease)
                _ = try InstallFilesystemTransaction.acknowledge(lease: lease, expected: receipt, validateLaunchAuthority: {}, fault: cancel)
            }
        }
        if point == .acknowledgementPublishedBeforeSync { try await operation.value }
        else {
            do { try await operation.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { throw error }
        }
        let lease = try InstallFilesystemLease(parentURL: f.root)
        _ = try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {})
        #expect(try f.version() == (point == .acknowledgementPublishedBeforeSync ? "new" : "old"))
    }
    @Test func replacedParentIsNotAdoptedAndRetainsPendingOriginal() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let lease = try InstallFilesystemLease(parentURL: f.root); _ = try f.begin(lease)
        let displaced = URL(fileURLWithPath: f.root.path + "-displaced")
        try FileManager.default.moveItem(at: f.root, to: displaced)
        defer { try? FileManager.default.removeItem(at: displaced) }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(throws: InstallFilesystemError.changed) { try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {}) }
        #expect(FileManager.default.fileExists(atPath: displaced.appendingPathComponent(InstallFilesystemTransaction.activeName).path))
        #expect(try String(contentsOf: displaced.appendingPathComponent("NeAntik.app/Contents/version"), encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }
    @Test(arguments: ["candidate", "duplicate", "schema", "oversize", "ackOversize"])
    func invalidBoundedJournalRecordsRefuseWithFence(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try child(f, "begin") == 0)
        let file = f.active.appendingPathComponent("journal.json")
        if control == "oversize" { try Data(repeating: 32, count: InstallFilesystemTransaction.maximumJournalBytes + 1).write(to: file) }
        else if control == "ackOversize" {
            let ack = f.active.appendingPathComponent("commit.json")
            try Data(repeating: 32, count: 2_049).write(to: ack); #expect(chmod(ack.path, 0o600) == 0)
        } else {
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var journal = try #require(envelope["journal"] as? [String: Any])
            switch control {
            case "candidate": journal["candidateName"] = ".neantik-next-not-a-uuid.app"
            case "schema": journal["schema"] = 2
            default:
                var candidate = try #require(journal["candidate"] as? [String: Any])
                var entries = try #require(candidate["entries"] as? [[String: Any]])
                entries.append(try #require(entries.first)); candidate["entries"] = entries; journal["candidate"] = candidate
            }
            let bytes = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys, .withoutEscapingSlashes])
            envelope["journal"] = journal; envelope["sha256"] = InstallFS.hash(bytes)
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
        }
        #expect(try child(f, "recover") == 74)
        #expect(FileManager.default.fileExists(atPath: f.active.path))
        #expect(try f.version() == "new"); #expect(try f.version(f.candidateName) == "old")
    }
    @Test func actualEntryLimitRefusesBeforeIntent() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let dir = f.root.appendingPathComponent(f.candidateName + "/Contents/many")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        for index in 0..<6_001 {
            let fd = open(dir.appendingPathComponent("entry-\(index)").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            try #require(fd >= 0); close(fd)
        }
        let lease = try InstallFilesystemLease(parentURL: f.root)
        #expect(throws: InstallFilesystemError.limit) { try f.begin(lease) }
        #expect(!FileManager.default.fileExists(atPath: f.active.path)); #expect(try f.version() == "old")
    }
    @Test func unexpectedPreSwapAcknowledgementRetainsOriginal() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let lease = try InstallFilesystemLease(parentURL: f.root)
        #expect(throws: InstallFilesystemError.changed) {
            try f.begin(lease, fault: { point in
                if point == .beforeSwap {
                    let path = f.active.appendingPathComponent("commit.json")
                    try Data("unexpected".utf8).write(to: path); try #require(chmod(path.path, 0o600) == 0)
                }
            })
        }
        #expect(try f.version() == "old"); #expect(FileManager.default.fileExists(atPath: f.active.path))
    }
}
