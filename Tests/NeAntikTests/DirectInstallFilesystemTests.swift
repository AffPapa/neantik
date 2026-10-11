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
    @Test func largeDirectoryEnumerationIsRepeatableOnRetainedDescriptor() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let directory = f.root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for number in 0..<1_000 { try Data().write(to: directory.appendingPathComponent("fixture-\(number)")) }
        let fd = try InstallFS.directory(directory); defer { close(fd) }
        let expected = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for _ in 0..<10 { #expect(try InstallFS.names(fd) == expected) }
    }
    private func markMetadata(_ url: URL) throws {
        let marker: [UInt8] = [1]
        guard marker.withUnsafeBytes({ setxattr(url.path, "com.neantik.install-fixture", $0.baseAddress, $0.count, 0, 0) }) == 0 else {
            throw InstallFS.posix()
        }
    }
    @Test func bundleRootMetadataChangeDuringCapturePreservesExactContentCustody() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let fd = try InstallFS.directory(f.root); defer { close(fd) }
        let before = try InstallTree.capture(parent: fd, name: "NeAntik.app")
        let after = try InstallTree.capture(parent: fd, name: "NeAntik.app", beforeScanRecheck: { prefix in
            if prefix.isEmpty { try markMetadata(f.root.appendingPathComponent("NeAntik.app")) }
        })
        let current = try #require(try InstallFS.entry(fd, "NeAntik.app"))
        #expect(before.root.changedSeconds != current.changedSeconds || before.root.changedNanos != current.changedNanos)
        #expect(before.matches(after))
        #expect(before.entries == after.entries)
    }
    @Test(arguments: ["rootACL", "rootMode", "rootFlags", "rootMtime", "rootNamespace", "rootReplacement", "descendantMetadata", "descendantContent"])
    func bundleRootMetadataToleranceNeverAdmitsOtherChanges(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let fd = try InstallFS.directory(f.root); defer { close(fd) }
        let app = f.root.appendingPathComponent("NeAntik.app")
        defer { _ = chflags(app.path, 0) }
        var injected = false
        do {
            _ = try InstallTree.capture(parent: fd, name: "NeAntik.app", beforeScanRecheck: { prefix in
                guard !injected, prefix == (control == "descendantMetadata" ? "Contents" : "") else { return }
                injected = true
                switch control {
                case "rootACL":
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
                    process.arguments = ["+a", "everyone allow read", app.path]
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
                case "rootMode": try #require(chmod(app.path, 0o700) == 0)
                case "rootFlags": try #require(chflags(app.path, UInt32(UF_NODUMP)) == 0)
                case "rootMtime":
                    var status = stat(); try #require(lstat(app.path, &status) == 0)
                    var times = [timeval(tv_sec: status.st_atimespec.tv_sec, tv_usec: 0),
                                 timeval(tv_sec: status.st_mtimespec.tv_sec + 1, tv_usec: 0)]
                    try #require(utimes(app.path, &times) == 0)
                case "rootNamespace": try Data([1]).write(to: app.appendingPathComponent("unexpected"))
                case "rootReplacement":
                    try FileManager.default.moveItem(at: app, to: f.root.appendingPathComponent("replaced.app"))
                    try f.tree("NeAntik.app", version: "old")
                case "descendantMetadata": try markMetadata(app.appendingPathComponent("Contents"))
                default: try Data("mutated".utf8).write(to: app.appendingPathComponent("Contents/version"))
                }
            })
            Issue.record("Changed bundle custody was accepted")
        } catch is InstallFilesystemError { }
        #expect(injected)
    }
    @Test(arguments: [InstallFilesystemPoint.finalizedBeforeSync, .finished])
    func exactFinalizedReceiptRecoversLateCompletionFailure(point: InstallFilesystemPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let lease = try InstallFilesystemLease(parentURL: f.root), receipt = try f.begin(lease)
        #expect(try lease.validatedApplicationURL() == f.root.appendingPathComponent("NeAntik.app"))
        #expect(try InstallFilesystemTransaction.finalizedResult(lease: lease, expected: receipt) == nil)
        #expect(throws: POSIXError(.EIO)) {
            try InstallFilesystemTransaction.acknowledge(lease: lease, expected: receipt,
                validateLaunchAuthority: {}, fault: { if $0 == point { throw POSIXError(.EIO) } })
        }
        #expect(try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {}) == nil)
        let result = try #require(try InstallFilesystemTransaction.finalizedResult(lease: lease, expected: receipt))
        #expect(result.committed && result.transactionID == receipt.transactionID)
        #expect(try f.version() == "new")
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        fields["journalSHA256"] = String(repeating: "f", count: 64)
        let altered = try JSONDecoder().decode(InstallFilesystemReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(throws: InstallFilesystemError.changed) { try InstallFilesystemTransaction.finalizedResult(lease: lease, expected: altered) }
        fields["transactionID"] = UUID().uuidString
        let unrelated = try JSONDecoder().decode(InstallFilesystemReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(try InstallFilesystemTransaction.finalizedResult(lease: lease, expected: unrelated) == nil)
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
    @Test func readableApplicationParentSupportsTransferSwapAndAcknowledgement() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try prepareSource(f)
        try #require(chmod(f.root.path, 0o755) == 0)
        let lease = try InstallFilesystemLease(parentURL: f.root)
        let slot = try transfer(f, lease: lease)
        let receipt = try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {})
        #expect(try InstallFilesystemTransaction.pendingReceipt(lease: lease) == receipt)
        #expect(try f.version() == "new")
        var observed = stat()
        for directory in [source, f.active] {
            try #require(lstat(directory.path, &observed) == 0)
            #expect(observed.st_mode & 0o777 == 0o700)
        }
        for file in [f.active.appendingPathComponent("journal.json"), f.root.appendingPathComponent(InstallFilesystemLease.lockName)] {
            try #require(lstat(file.path, &observed) == 0)
            #expect(observed.st_mode & 0o777 == 0o600)
        }
        _ = try InstallFilesystemTransaction.acknowledge(lease: lease, expected: receipt, validateLaunchAuthority: {})
        try #require(lstat(f.root.path, &observed) == 0)
        #expect(observed.st_mode & 0o777 == 0o755)
        #expect(try f.version(f.candidateName) == "old")
        #expect(try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {}) == nil)
    }
    @Test(arguments: [0o750, 0o775, 0o777])
    func unsafeOrUnsupportedApplicationParentRefusesBeforeLock(mode: Int) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try #require(chmod(f.root.path, mode_t(mode)) == 0)
        #expect(throws: (any Error).self) { try InstallFilesystemLease(parentURL: f.root) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(InstallFilesystemLease.lockName).path))
        #expect(try f.version() == "old")
        #expect(try f.version(f.candidateName) == "new")
    }
    @Test func rootOwnedSystemDirectoryIsUnsupportedWithoutMutation() throws {
        #expect(throws: (any Error).self) { try InstallFilesystemLease(parentURL: URL(fileURLWithPath: "/Applications")) }
        #expect(!FileManager.default.fileExists(atPath: "/Applications/" + InstallFilesystemLease.lockName))
    }
    @Test(arguments: ["mode", "replacement"])
    func readableParentLeaseRejectsChangedCustody(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try #require(chmod(f.root.path, 0o755) == 0)
        let lease = try InstallFilesystemLease(parentURL: f.root)
        let retained = URL(fileURLWithPath: f.root.path + "-retained")
        defer { try? FileManager.default.removeItem(at: retained) }
        if control == "mode" {
            try #require(chmod(f.root.path, 0o700) == 0)
        } else {
            try FileManager.default.moveItem(at: f.root, to: retained)
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        #expect(throws: InstallFilesystemError.changed) { try lease.validate() }
        #expect(throws: (any Error).self) { try f.begin(lease) }
    }
    @Test(arguments: ["ACL", "flags", "ancestorLink"])
    func readableParentStillRejectsPlatformAccessHazards(control: String) throws {
        let f = try Fixture(); defer { f.cleanup(); _ = chflags(f.root.path, 0) }
        try #require(chmod(f.root.path, 0o755) == 0)
        let alias = URL(fileURLWithPath: f.root.path + "-alias")
        defer { try? FileManager.default.removeItem(at: alias); _ = chflags(f.root.path, 0) }
        if control == "ACL" {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "everyone allow read", f.root.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
        } else if control == "flags" {
            try #require(chflags(f.root.path, UInt32(UF_NODUMP)) == 0)
        } else {
            try #require(symlink(f.root.path, alias.path) == 0)
        }
        #expect(throws: (any Error).self) { try InstallFilesystemLease(parentURL: control == "ancestorLink" ? alias : f.root) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(InstallFilesystemLease.lockName).path))
        #expect(try f.version() == "old")
    }
    @Test(arguments: ["source", "transferJournal", "transactionJournal"])
    func readableParentNeverMakesPrivateStorageReadable(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try prepareSource(f)
        try #require(chmod(f.root.path, 0o755) == 0)
        let lease = try InstallFilesystemLease(parentURL: f.root)
        if control == "source" {
            try #require(chmod(source.path, 0o755) == 0)
            #expect(throws: InstallFilesystemError.unsupported) { try transfer(f, lease: lease) }
            #expect(try f.version() == "old")
            return
        }
        let slot = try transfer(f, lease: lease)
        if control == "transferJournal" {
            let record = f.root.appendingPathComponent(".neantik-install-transfer-" + String(f.candidateName.dropFirst(14).dropLast(4)))
            try #require(chmod(record.path, 0o755) == 0)
            #expect(throws: (any Error).self) { try slot.withValidatedCandidate { _ in () } }
            #expect(throws: (any Error).self) { try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {}) }
            #expect(try f.version() == "old")
        } else {
            _ = try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {})
            try #require(chmod(f.active.path, 0o755) == 0)
            // This process already holds the lease. A child would stop at the
            // cooperation lock rather than exercise private journal admission.
            #expect(throws: InstallFilesystemError.unsupported) {
                try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {})
            }
            #expect(try f.version() == "new")
            #expect(try f.version(f.candidateName) == "old")
            #expect(FileManager.default.fileExists(atPath: f.active.path))
        }
    }
    @Test(arguments: [InstallFilesystemPoint.swappedBeforeSync, .pendingLaunch])
    func readableParentFreshProcessRecoveryRestoresOld(point: InstallFilesystemPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        try #require(chmod(f.root.path, 0o755) == 0)
        #expect(try child(f, "transferBegin", point.rawValue) == 73)
        #expect(try child(f, "recover") == 0)
        #expect(try f.version() == "old")
        #expect(try child(f, "recover") == 0)
        #expect(try f.version(f.candidateName) == "new")
    }
    @Test(arguments: [InstallFilesystemPoint.beforeAcknowledgementPublication, .acknowledgementPublishedBeforeSync])
    func readableParentFreshProcessAcknowledgementPreservesVisibleDecision(point: InstallFilesystemPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        try #require(chmod(f.root.path, 0o755) == 0)
        #expect(try child(f, "transferBegin") == 0)
        #expect(try child(f, "ack", point.rawValue) == 73)
        #expect(try child(f, "recover") == 0)
        #expect(try f.version() == (point == .beforeAcknowledgementPublication ? "old" : "new"))
        #expect(try child(f, "recover") == 0)
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
    private func prepareSource(_ f: Fixture) throws -> URL {
        let source = f.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: f.root.appendingPathComponent(f.candidateName), to: source.appendingPathComponent("NeAntik.app"))
        return source
    }
    private func transfer(_ f: Fixture, lease: InstallFilesystemLease, didTransfer: () -> Void = {},
                          fault: ((InstallPreparationPoint) throws -> Void)? = nil) throws -> PreparedInstallSlot {
        let source = f.root.appendingPathComponent("source"), fd = try InstallFS.directory(source); defer { close(fd) }
        let id = try #require(UUID(uuidString: String(f.candidateName.dropFirst(14).dropLast(4))))
        return try InstallPreparation.transfer(lease: lease, sourceParentURL: source, sourceParentDescriptor: fd,
            candidateID: id, candidateReceiptSHA256: String(repeating: "a", count: 64),
            validateSource: {}, didTransfer: didTransfer, fault: fault)
    }
    @Test(arguments: InstallPreparationPoint.allCases)
    func transferCrashesRetainExactCustody(point: InstallPreparationPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        #expect(try child(f, "transfer", point.rawValue) == 73)
        let moved = [InstallPreparationPoint.renamedBeforeSync, .sourceDirectorySynced, .destinationDirectorySynced, .beforeReturn].contains(point)
        #expect(try f.version() == "old")
        let sourceApp = f.root.appendingPathComponent("source/NeAntik.app")
        #expect(FileManager.default.fileExists(atPath: sourceApp.path) == !moved)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.candidateName).path) == moved)
        let published = ![InstallPreparationPoint.created, .recordWrittenBeforeSync, .recordFileSynced, .recordDirectorySynced].contains(point)
        #expect(try child(f, "inspectTransfer", moved ? "candidate" : "source") == (published ? 0 : 74))
        #expect(try child(f, "inspectTransfer", moved ? "candidate" : "source") == (published ? 0 : 74))
        #expect(try child(f, "transfer") == 74) // retained intent/incomplete record fences retry
    }
    @Test(arguments: [InstallFilesystemPoint.activatedBeforeSync, .beforeSwap, .swappedBeforeSync, .pendingLaunch])
    func transferredTokenJournalCrashRecovery(point: InstallFilesystemPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        #expect(try child(f, "transferBegin", point.rawValue) == 73)
        #expect(try child(f, "inspectTransfer", "journal") == 0)
        #expect(try child(f, "recover") == 0); #expect(try f.version() == "old")
        #expect(try child(f, "inspectTransfer", "journal") == 0)
        #expect(try child(f, "recover") == 0); #expect(try f.version(f.candidateName) == "new")
    }
    @Test func typedSlotConsumedOnVisibleActivationAndNeverOwnsOldApp() async throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        let lease = try InstallFilesystemLease(parentURL: f.root), slot = try transfer(f, lease: lease)
        #expect(try slot.withValidatedCandidate { try String(contentsOf: $0.appendingPathComponent("Contents/version"), encoding: .utf8) } == "new")
        let receipt = try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {})
        let immediateReceipt = try InstallFilesystemTransaction.pendingReceipt(lease: lease)
        #expect(immediateReceipt == receipt)
        let workerReceipt = try await Task.detached(priority: .utility) {
            try InstallFilesystemTransaction.pendingReceipt(lease: lease)
        }.value
        #expect(workerReceipt == receipt)
        #expect(try f.version(f.candidateName) == "old")
        #expect(throws: InstallFilesystemError.changed) { try slot.withValidatedCandidate { _ in () } }
        #expect(throws: InstallFilesystemError.changed) { try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {}) }
        _ = try InstallFilesystemTransaction.acknowledge(lease: lease, expected: receipt, validateLaunchAuthority: {})
        #expect(throws: InstallFilesystemError.changed) { try slot.withValidatedCandidate { _ in () } }
        let record = ".neantik-install-transfer-" + String(f.candidateName.dropFirst(14).dropLast(4))
        #expect(try InstallPreparation.inspect(lease: lease, recordName: record, sourceParentURL: f.root.appendingPathComponent("source")) == .journal)
        #expect(try f.version(f.candidateName) == "old")
    }
    @Test(arguments: [false, true]) func fullBundlePendingReceiptAcrossUtilityWorker(prepared: Bool) async throws {
        guard let path = ProcessInfo.processInfo.environment["NEANTIK_UPDATE_CODE_APP"] else { return }
        let f = try Fixture(); defer { f.cleanup() }
        for name in ["NeAntik.app", f.candidateName] {
            let destination = f.root.appendingPathComponent(name)
            try FileManager.default.removeItem(at: destination)
            let copy = Process(); copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            copy.arguments = [path, destination.path]; copy.standardOutput = FileHandle.nullDevice
            copy.standardError = FileHandle.nullDevice; try copy.run(); copy.waitUntilExit()
            try #require(copy.terminationStatus == 0)
        }
        if prepared { _ = try prepareSource(f) }
        let lease = try InstallFilesystemLease(parentURL: f.root)
        let receipt: InstallFilesystemReceipt
        if prepared {
            let slot = try transfer(f, lease: lease)
            receipt = try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {})
        } else { receipt = try f.begin(lease) }
        let immediate = try InstallFilesystemTransaction.pendingReceipt(lease: lease)
        #expect(immediate == receipt)
        let worker = try await Task.detached(priority: .utility) {
            try InstallFilesystemTransaction.pendingReceipt(lease: lease)
        }.value
        #expect(worker == receipt)
        _ = try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {})
    }
    @Test(arguments: [InstallPreparationPoint.recordPublishedBeforeSync, .renamedBeforeSync, .sourceDirectorySynced, .destinationDirectorySynced])
    func transferSyncErrorsNeverReturnCustody(point: InstallPreparationPoint) throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        let lease = try InstallFilesystemLease(parentURL: f.root); var invalidated = false
        #expect(throws: POSIXError(.EIO)) {
            try transfer(f, lease: lease, didTransfer: { invalidated = true }, fault: { if $0 == point { throw POSIXError(.EIO) } })
        }
        let moved = point != .recordPublishedBeforeSync
        #expect(invalidated == moved)
        let record = ".neantik-install-transfer-" + String(f.candidateName.dropFirst(14).dropLast(4))
        #expect(try InstallPreparation.inspect(lease: lease, recordName: record, sourceParentURL: f.root.appendingPathComponent("source")) == (moved ? .candidate : .source))
        #expect(try f.version() == "old")
    }
    @Test(arguments: ["body", "candidateCollision", "sourceReplacement", "parentMode", "record", "recordExtra", "lock", "hardlink"])
    func transferUnknownCustodyIsRetained(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }; let sourceURL = try prepareSource(f)
        let lease = try InstallFilesystemLease(parentURL: f.root); var invalidated = false
        #expect(throws: (any Error).self) {
            try transfer(f, lease: lease, didTransfer: { invalidated = true }, fault: { point in
                guard point == .beforeRename else { return }
                let record = f.root.appendingPathComponent(".neantik-install-transfer-" + String(f.candidateName.dropFirst(14).dropLast(4)))
                switch control {
                case "body": try Data("bad".utf8).write(to: sourceURL.appendingPathComponent("NeAntik.app/Contents/version"))
                case "candidateCollision": try f.tree(f.candidateName, version: "foreign")
                case "sourceReplacement":
                    try FileManager.default.moveItem(at: sourceURL, to: f.root.appendingPathComponent("retained-source"))
                    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                case "parentMode": #expect(chmod(f.root.path, 0o755) == 0)
                case "record": try Data("{}".utf8).write(to: record.appendingPathComponent("transfer.json"))
                case "recordExtra": try Data([1]).write(to: record.appendingPathComponent("unexpected"))
                case "lock":
                    try FileManager.default.removeItem(at: f.root.appendingPathComponent(InstallFilesystemLease.lockName))
                    try Data().write(to: f.root.appendingPathComponent(InstallFilesystemLease.lockName))
                default: #expect(link(sourceURL.appendingPathComponent("NeAntik.app/Contents/version").path, f.root.appendingPathComponent("alias").path) == 0)
                }
            })
        }
        #expect(!invalidated); #expect(try f.version() == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(InstallPreparation.prefix) })
    }
    @Test func scalarBeginCannotBypassPreparedRecordAndActivationErrorConsumesToken() throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        let lease = try InstallFilesystemLease(parentURL: f.root), slot = try transfer(f, lease: lease)
        #expect(throws: InstallFilesystemError.pending) { try f.begin(lease) }
        #expect(throws: POSIXError(.EIO)) {
            try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {},
                fault: { if $0 == .activatedBeforeSync { throw POSIXError(.EIO) } })
        }
        #expect(throws: InstallFilesystemError.changed) { try slot.withValidatedCandidate { _ in () } }
        #expect(try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {})?.committed == false)
        #expect(try f.version() == "old"); #expect(try f.version(f.candidateName) == "new")
    }

    @Test(arguments: ["plain", "NFD", "newline", "backslash"])
    func twoFreshProcessUpdatesKeepHistoricalRecordsWithoutBlockingNext(sibling: String) throws {
        let f = try Fixture(); defer { f.cleanup() }; let source = try prepareSource(f)
        let unrelatedName: String
        switch sibling {
        case "NFD": unrelatedName = "Cafe\u{301}.app"
        case "newline": unrelatedName = "unrelated\nentry"
        case "backslash": unrelatedName = "unrelated\\entry"
        default: unrelatedName = "unrelated.app"
        }
        let unrelated = f.root.appendingPathComponent(unrelatedName)
        let original = Data("untouched-unrelated-sibling".utf8)
        try original.write(to: unrelated)
        try #require(try child(f, "transferBegin") == 0); try #require(try child(f, "ack") == 0)
        let second = ".neantik-next-" + UUID().uuidString.lowercased() + ".app"
        try f.tree(second, version: "newer")
        try FileManager.default.moveItem(at: f.root.appendingPathComponent(second), to: source.appendingPathComponent("NeAntik.app"))
        try Data(second.utf8).write(to: f.root.appendingPathComponent("candidate.name"))
        #expect(try child(f, "transferBegin") == 0); #expect(try child(f, "ack") == 0)
        #expect(try f.version() == "newer"); #expect(try f.version(second) == "new"); #expect(try f.version(f.candidateName) == "old")
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        #expect(names.filter { $0.hasPrefix(InstallPreparation.prefix) }.count == 2)
        #expect(names.filter { $0.hasPrefix(".neantik-install-committed-") }.count == 2)
        #expect(try child(f, "inspectTransfer", "journal") == 0)
        try Data(f.candidateName.utf8).write(to: f.root.appendingPathComponent("candidate.name"))
        #expect(try child(f, "inspectTransfer", "journal") == 0) // first history, now a different active app
        #expect(try Data(contentsOf: unrelated) == original)
    }
    @Test(arguments: ["unrelated\nentry", "unrelated\\entry"])
    func unrelatedParentNamesSurviveFreshProcessRollback(sibling: String) throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        let unrelated = f.root.appendingPathComponent(sibling), bytes = Data("retained-sibling".utf8)
        try bytes.write(to: unrelated)
        try #require(try child(f, "transferBegin", InstallFilesystemPoint.swappedBeforeSync.rawValue) == 73)
        #expect(try child(f, "inspectTransfer", "journal") == 0)
        #expect(try child(f, "recover") == 0); #expect(try f.version() == "old")
        #expect(try child(f, "recover") == 0)
        #expect(try Data(contentsOf: unrelated) == bytes)
    }
    @Test(arguments: [".neantik-install-preparing-unknown", ".neantik-install-transfer-unknown", ".neantik-install-unknown\nentry"])
    func malformedOwnedParentNamespaceStillFencesTransfer(name: String) throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try prepareSource(f)
        let unexpected = f.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lease = try InstallFilesystemLease(parentURL: f.root)
        #expect(throws: (any Error).self) { try transfer(f, lease: lease) }
        #expect(try f.version() == "old"); #expect(!FileManager.default.fileExists(atPath: f.active.path))
        #expect(FileManager.default.fileExists(atPath: unexpected.path))
    }
    @Test(arguments: ["app", "source", "journal"])
    func namespaceSelectionNeverRelaxesPrivateTreeNames(scope: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let lease = try InstallFilesystemLease(parentURL: f.root)
        if scope == "app" {
            try Data([1]).write(to: f.root.appendingPathComponent(f.candidateName + "/Contents/unrelated\nentry"))
            #expect(throws: InstallFilesystemError.unsafe) { try f.begin(lease) }
            #expect(try f.version() == "old"); #expect(!FileManager.default.fileExists(atPath: f.active.path))
        } else if scope == "source" {
            let source = try prepareSource(f)
            try Data([1]).write(to: source.appendingPathComponent("unrelated\nentry"))
            #expect(throws: InstallFilesystemError.unsafe) { try transfer(f, lease: lease) }
            #expect(try f.version() == "old"); #expect(!FileManager.default.fileExists(atPath: f.active.path))
        } else {
            _ = try f.begin(lease)
            try Data([1]).write(to: f.active.appendingPathComponent("unrelated\nentry"))
            #expect(throws: InstallFilesystemError.unsafe) { try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {}) }
            #expect(try f.version() == "new"); #expect(try f.version(f.candidateName) == "old")
            #expect(FileManager.default.fileExists(atPath: f.active.path))
        }
    }
    @Test func unrelatedParentEntriesStillCountTowardsEnumerationLimit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let directory = f.root.appendingPathComponent("many-unrelated")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fd = try InstallFS.directory(directory); defer { close(fd) }
        for index in 0..<6_001 {
            let file = openat(fd, "unrelated-\(index)", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            try #require(file >= 0); close(file)
        }
        #expect(throws: InstallFilesystemError.limit) { try InstallFS.installParentNames(fd) }
    }
    @Test func unknownRecordCannotPretendToBeHistoricalFinalized() throws {
        let f = try Fixture(); defer { f.cleanup() }; let source = try prepareSource(f)
        #expect(try child(f, "transferBegin") == 0); #expect(try child(f, "ack") == 0)
        let committed = try #require(FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".neantik-install-committed-") })
        try Data("foreign".utf8).write(to: committed.appendingPathComponent("commit.json"))
        let second = ".neantik-next-" + UUID().uuidString.lowercased() + ".app"
        try f.tree(second, version: "newer")
        try FileManager.default.moveItem(at: f.root.appendingPathComponent(second), to: source.appendingPathComponent("NeAntik.app"))
        try Data(second.utf8).write(to: f.root.appendingPathComponent("candidate.name"))
        #expect(try child(f, "transfer") == 74); #expect(try f.version() == "new")
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("NeAntik.app").path))
    }

    @Test(arguments: ["body", "record", "sourceExtra"])
    func postRenameChangesRetainCandidateAndRefuseUnknownCustody(control: String) throws {
        let f = try Fixture(); defer { f.cleanup() }; let source = try prepareSource(f)
        let lease = try InstallFilesystemLease(parentURL: f.root); var moved = false
        #expect(throws: (any Error).self) {
            try transfer(f, lease: lease, didTransfer: { moved = true }, fault: { point in
                guard point == .destinationDirectorySynced else { return }
                if control == "body" { try Data("unknown".utf8).write(to: f.root.appendingPathComponent(f.candidateName + "/Contents/version")) }
                else if control == "record" {
                    let record = f.root.appendingPathComponent(".neantik-install-transfer-" + String(f.candidateName.dropFirst(14).dropLast(4)))
                    try Data("{}".utf8).write(to: record.appendingPathComponent("transfer.json"))
                } else { try Data([1]).write(to: source.appendingPathComponent("foreign")) }
            })
        }
        #expect(moved); #expect(try f.version() == "old")
        let record = ".neantik-install-transfer-" + String(f.candidateName.dropFirst(14).dropLast(4))
        #expect(throws: (any Error).self) { try InstallPreparation.inspect(lease: lease, recordName: record, sourceParentURL: source) }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.candidateName).path))
    }
    @Test func substitutedSourceDescriptorPathAndWrongLeaseRefuse() throws {
        let f = try Fixture(); defer { f.cleanup() }; let source = try prepareSource(f)
        let other = source.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lease = try InstallFilesystemLease(parentURL: f.root), fd = try InstallFS.directory(source); defer { close(fd) }
        #expect(throws: InstallFilesystemError.changed) {
            try InstallPreparation.transfer(lease: lease, sourceParentURL: other, sourceParentDescriptor: fd,
                candidateReceiptSHA256: String(repeating: "a", count: 64), validateSource: {}, didTransfer: {})
        }
        try FileManager.default.removeItem(at: other)
        let slot = try transfer(f, lease: lease), second = try Fixture(); defer { second.cleanup() }
        let otherLease = try InstallFilesystemLease(parentURL: second.root)
        #expect(throws: InstallFilesystemError.changed) { try InstallFilesystemTransaction.begin(lease: otherLease, preparedSlot: slot, validateStoppedAuthority: {}) }
        #expect(try f.version() == "old")
        try Data("unknown".utf8).write(to: f.root.appendingPathComponent(f.candidateName + "/Contents/version"))
        #expect(throws: InstallFilesystemError.changed) { try slot.withValidatedCandidate { _ in () } }
    }

}
