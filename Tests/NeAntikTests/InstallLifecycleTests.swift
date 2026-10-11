import Darwin
import Foundation
import Testing
@testable import DirectInstallFilesystem

private final class InstallLifecycleTestBundle: NSObject {}

@Suite(.serialized)
struct InstallLifecycleTests {
    enum ChildFailure: Error { case refused(String) }
    struct Fixture {
        let root: URL
        var namespace: URL { root.appendingPathComponent("lifecycle") }
        init() throws {
            var template = Array("/private/tmp/neantik-install-fixture-XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else { throw POSIXError(.EIO) }
            root = URL(fileURLWithPath: String(cString: path))
            try Data("isolated-install-filesystem-qa\n".utf8).write(to: root.appendingPathComponent("fixture.marker"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("NeAntik.app"), withIntermediateDirectories: false)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    final class Child {
        let process = Process(), input = Pipe(), output = Pipe()
        init(_ root: URL, mode: String) throws {
            var executable: URL?
            for base in [Bundle(for: InstallLifecycleTestBundle.self).bundleURL,
                         URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()] {
                var path = base
                for _ in 0..<6 {
                    let candidate = path.appendingPathComponent("NeAntikInstallFilesystemFixture")
                    if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
                    path.deleteLastPathComponent()
                }
                if executable != nil { break }
            }
            guard let executable else { throw InstallFilesystemError.unsupported }
            process.executableURL = executable; process.arguments = [mode, root.path, "none"]
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "TMPDIR": "/private/tmp"]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
            try process.run()
        }
        deinit { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        func line() throws -> String {
            var data = Data()
            while let byte = output.fileHandleForReading.readData(ofLength: 1).first {
                if byte == 10 { return String(decoding: data, as: UTF8.self) }
                guard data.count < 128 else { throw InstallFilesystemError.limit }; data.append(byte)
            }
            process.waitUntilExit()
            throw ChildFailure.refused("fixture exited \(process.terminationStatus) before reply")
        }
        func send(_ command: String) throws { try input.fileHandleForWriting.write(contentsOf: Data(command.utf8)) }
        func stop() throws -> Int32 {
            try input.fileHandleForWriting.close(); process.waitUntilExit(); return process.terminationStatus
        }
        func crash() { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }

    @Test func actualParticipantsDrainAndNewStartsRefuse() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var first = try Child(f.root, mode: "participant"), second = try Child(f.root, mode: "participant")
        func ready(_ child: Child) throws -> Bool {
            do { #expect(try child.line() == "participant"); return true }
            catch ChildFailure.refused(_) {
                #expect(child.process.terminationStatus == 75)
                guard child.process.terminationStatus == 75 else { throw InstallFilesystemError.unsafe }
                return false
            }
        }
        let a = try ready(first), b = try ready(second)
        #expect(a || b) // an entrant may legitimately lose EX_NB, never unsafe
        if !a { first = try Child(f.root, mode: "participant"); #expect(try ready(first)) }
        if !b { second = try Child(f.root, mode: "participant"); #expect(try ready(second)) }
        try first.send("w"); #expect(try first.line() == "allowed")
        let owner = try Child(f.root, mode: "intent"); #expect(try owner.line() == "intent")
        try owner.send("q"); #expect(try owner.line() == "live")
        try first.send("w"); #expect(try first.line() == "busy")
        let denied = try Child(f.root, mode: "participant"); #expect(try denied.stop() == 75)
        #expect(try second.stop() == 0)
        try owner.send("q"); #expect(try owner.line() == "live")
        first.crash()
        try owner.send("q"); #expect(try owner.line() == "quiet")
        #expect(try owner.stop() == 0)
        let resumed = try Child(f.root, mode: "participant"); #expect(try resumed.line() == "participant")
        #expect(try resumed.stop() == 0)
    }

    @Test func killedOwnerReleasesAdmissionWithoutKillingParticipant() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let participant = try Child(f.root, mode: "participant"); #expect(try participant.line() == "participant")
        let owner = try Child(f.root, mode: "intent"); #expect(try owner.line() == "intent")
        owner.crash()
        try participant.send("w"); #expect(try participant.line() == "allowed")
        #expect(try participant.stop() == 0)
    }

    @Test func execDoesNotInheritParticipantLocks() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try Child(f.root, mode: "participant"); #expect(try child.line() == "participant")
        try child.send("e"); #expect(try child.line() == "intent")
        try child.send("q"); #expect(try child.line() == "quiet")
        #expect(try child.stop() == 0)
    }

    @Test func participantAcquisitionKeepsAdmissionUntilStartupCheckFinishes() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let participant = try InstallLifecycleParticipant(namespaceURL: f.namespace) {
            #expect(throws: InstallFilesystemError.busy) { try InstallLifecycleIntent(namespaceURL: f.namespace) }
        }
        try participant.requireNewWork()
    }

    @Test(arguments: ["admission", "participants", "namespace", "parent"])
    func replacementIsDetectedBeforeNewWork(kind: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let participant = try InstallLifecycleParticipant(namespaceURL: f.namespace)
        let target: URL
        if kind == "parent" { target = f.root }
        else if kind == "namespace" { target = f.namespace }
        else { target = f.namespace.appendingPathComponent(kind + ".guard") }
        let moved = target.appendingPathExtension("old")
        try FileManager.default.moveItem(at: target, to: moved)
        defer { try? FileManager.default.removeItem(at: target); try? FileManager.default.moveItem(at: moved, to: target) }
        if ["parent", "namespace"].contains(kind) {
            #expect(mkdir(target.path, 0o700) == 0)
        } else {
            let fd = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            #expect(fd >= 0); if fd >= 0 { close(fd) }
        }
        #expect(throws: (any Error).self) { try participant.requireNewWork() }
    }

    @Test(arguments: ["symlink", "hardlink", "content", "mode", "parentMode", "acl"])
    func unsafeNamespaceRefusesWithoutRepair(kind: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        // Close participant before injecting faults; constructor never repairs.
        do { let p = try InstallLifecycleParticipant(namespaceURL: f.namespace); try p.requireNewWork() }
        let guardURL = f.namespace.appendingPathComponent("admission.guard")
        switch kind {
        case "symlink":
            try FileManager.default.removeItem(at: guardURL)
            #expect(symlink("participants.guard", guardURL.path) == 0)
        case "hardlink": #expect(link(guardURL.path, f.root.appendingPathComponent("other.guard").path) == 0)
        case "content": try Data("foreign".utf8).write(to: guardURL)
        case "mode": #expect(chmod(guardURL.path, 0o644) == 0)
        case "parentMode": #expect(chmod(f.root.path, 0o755) == 0)
        default:
            let command = Process(); command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = ["+a", "everyone allow read", f.namespace.path]
            command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
            try command.run(); command.waitUntilExit(); #expect(command.terminationStatus == 0)
        }
        #expect(throws: (any Error).self) { try InstallLifecycleParticipant(namespaceURL: f.namespace) }
        #expect(FileManager.default.fileExists(atPath: guardURL.path))
    }

    @Test(arguments: [".neantik-install-active", ".neantik-install-preparing-unknown"])
    func pendingTransactionRefusesActualStartup(record: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try Data("unknown retained record".utf8).write(to: f.root.appendingPathComponent(record))
        let child = try Child(f.root, mode: "participantPending"); #expect(try child.stop() == 74)
        #expect(try String(contentsOf: f.root.appendingPathComponent(record), encoding: .utf8) == "unknown retained record")
        let owner = try InstallLifecycleIntent(namespaceURL: f.namespace)
        #expect(try owner.tryAcquireParticipantFence()) // failed startup leaked no SH
    }

    @Test func aliasesShareScopeAndSeparateInstallationsDoNot() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("NeAntik.app"), alias = f.root.appendingPathComponent("Alias.app")
        #expect(symlink("NeAntik.app", alias.path) == 0)
        let first = try InstallLifecycle.namespaceName(installationURL: app)
        #expect(try InstallLifecycle.namespaceName(installationURL: alias) == first)
        #expect(try InstallLifecycle.namespaceName(installationURL: URL(fileURLWithPath: f.root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") + "/NeAntik.app")) == first)
        let other = f.root.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        #expect(try InstallLifecycle.namespaceName(installationURL: other) != first)
        try FileManager.default.moveItem(at: app, to: f.root.appendingPathComponent("Old.app"))
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        #expect(try InstallLifecycle.namespaceName(installationURL: app) == first)
    }

    @Test func unrelatedInstallParentNamesDoNotBlockStartup() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try Data().write(to: f.root.appendingPathComponent("unrelated\nentry"))
        try InstallLifecycle.requireNoPendingTransaction(installationURL: f.root.appendingPathComponent("NeAntik.app"))
    }
}
