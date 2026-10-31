import Darwin
import DirectInstallFilesystem
import Foundation
import Testing
@testable import DirectUpdateCore

private final class StoppedAuthorityTestBundle: NSObject {}

@Suite(.serialized) struct DirectUpdateStoppedAuthorityTests {
    private func entry(_ path: String, pid: pid_t = 42, start: Int64 = 1) -> DirectUpdateProcessInventory.Entry {
        .init(processID: pid, identity: .init(generation: .init(startSeconds: start, startMicroseconds: 2),
            userID: geteuid(), parentProcessID: getpid()), executable: path)
    }
    @Test(arguments: ["/tmp/NeAntik", "/tmp/NeAntikUpdateOwner", "/tmp/NeAntik.app/Contents/MacOS/renamed",
        "/tmp/NeAntik Browser.app/Contents/MacOS/browser", "/tmp/NeAntik Browser Framework.framework/Helpers/renderer",
        "/tmp/neantik", "/tmp/NEANTIK.APP/Contents/MacOS/renamed", "/tmp/nevision",
        "/tmp/NeVision Browser.app/Contents/MacOS/old-helper"])
    func everyManagerRelayAndRuntimeShapeBlocks(path: String) {
        #expect(throws: DirectUpdateStoppedError.busy) { try DirectUpdateProcessInventory.requireQuiet([entry(path)]) }
    }
    @Test func exactAllowedCandidateAndNoOtherProcess() throws {
        let candidate = entry("/tmp/NeAntik"), ordinary = entry("/usr/bin/cat", pid: 43)
        try DirectUpdateProcessInventory.requireQuiet([ordinary])
        try DirectUpdateProcessInventory.requireQuiet([candidate, ordinary], allowed: candidate)
        #expect(throws: DirectUpdateStoppedError.busy) {
            try DirectUpdateProcessInventory.requireQuiet([entry(candidate.executable, start: 9)], allowed: candidate)
        }
        #expect(throws: DirectUpdateStoppedError.busy) {
            try DirectUpdateProcessInventory.requireQuiet([candidate, entry("/tmp/NeAntik", pid: 44)], allowed: candidate)
        }
        #expect(throws: DirectUpdateStoppedError.unknown) { try DirectUpdateProcessInventory.requireQuiet([ordinary], allowed: candidate) }
    }
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-install-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("isolated-install-filesystem-qa\n".utf8).write(to: root.appendingPathComponent("fixture.marker"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("NeAntik.app"), withIntermediateDirectories: false)
        return root
    }
    private func fixtureBinary() throws -> URL {
        for base in [Bundle(for: StoppedAuthorityTestBundle.self).bundleURL,
                     URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()] {
            var directory = base
            for _ in 0..<6 {
                let url = directory.appendingPathComponent("NeAntikInstallFilesystemFixture")
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
                directory.deleteLastPathComponent()
            }
        }
        throw InstallFilesystemError.unsupported
    }
    private func ownedKernelRecord(_ pid: pid_t) throws -> [kinfo_proc] {
        let rows = try DirectUpdateProcessInventory.captureKernelTable().filter { $0.kp_proc.p_pid == pid }
        try #require(rows.count == 1 && rows[0].kp_eproc.e_ucred.cr_uid == geteuid(), "Owned kernel record missing")
        return rows
    }
    @Test(arguments: ["NeAntikLegacyFixture", "NeAntikRelayFixture", "NeAntik Browser.app/Contents/MacOS/helper", "OrdinaryFixture"])
    func actualFreshKernelInventoryRecognizesOwnedLiveProcess(name: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = try fixtureBinary()
        try FileManager.default.copyItem(at: source, to: binary)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = binary; child.arguments = ["hold", root.path, "none"]
        child.standardInput = input; child.standardOutput = output
        child.standardError = FileHandle.nullDevice; child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        try child.run()
        defer { try? input.fileHandleForWriting.close(); if child.isRunning { kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit() }
        #expect(output.fileHandleForReading.readData(ofLength: 5) == Data("held\n".utf8))
        let records = try ownedKernelRecord(child.processIdentifier)
        let entries = try DirectUpdateProcessInventory.captureEntries(table: records)
        #expect(entries.count == 1 && entries.first?.identity == DirectProcessIdentityInspector.processIdentity(child.processIdentifier))
        if name == "OrdinaryFixture" { try DirectUpdateProcessInventory.requireQuiet(entries) }
        else { #expect(throws: DirectUpdateStoppedError.busy) { try DirectUpdateProcessInventory.requireQuiet(entries) } }
    }
    @Test func actualExitedUnreapedChildIsNotLiveAuthority() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("NeAntikZombieFixture")
        try FileManager.default.copyItem(at: fixtureBinary(), to: executable)
        let argument = try #require(strdup(executable.path)); defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil], pid: pid_t = 0
        try #require(posix_spawn(&pid, executable.path, nil, nil, &arguments, &environment) == 0)
        defer { var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        // Wait without reaping: ESRCH is intentionally unavailable until defer.
        var info = siginfo_t()
        try #require(waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0)
        #expect(kill(pid, 0) == 0)
        let records = try ownedKernelRecord(pid)
        try #require(records[0].kp_proc.p_stat == SZOMB, "Owned child is not an unreaped zombie")
        #expect(try DirectUpdateProcessInventory.captureEntries(table: records).isEmpty)
    }
    @Test func liveUnlinkedOwnedExecutableAndChangedGenerationStillRefuse() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("OwnedUnlinkedFixture")
        try FileManager.default.copyItem(at: fixtureBinary(), to: binary)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = binary; child.arguments = ["hold", root.path, "none"]
        child.standardInput = input; child.standardOutput = output
        child.standardError = FileHandle.nullDevice; child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        try child.run()
        defer { try? input.fileHandleForWriting.close(); if child.isRunning { kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit() }
        try #require(output.fileHandleForReading.readData(ofLength: 5) == Data("held\n".utf8))
        var changed = try ownedKernelRecord(child.processIdentifier)
        changed[0].kp_proc.p_starttime.tv_sec += 1
        #expect(throws: DirectUpdateStoppedError.unknown) {
            try DirectUpdateProcessInventory.captureEntries(table: changed)
        }
        // No process is exempted by name or by a missing path. Reproduce the
        // actual host condition on our child, while preserving all user apps.
        try FileManager.default.removeItem(at: binary)
        try #require(kill(child.processIdentifier, 0) == 0)
        try #require(DirectUpdateProcessInventory.path(child.processIdentifier) == nil,
                     "This OS retained the executable path; unreadable-path control was not reproduced")
        let live = try ownedKernelRecord(child.processIdentifier)
        #expect(throws: DirectUpdateStoppedError.unknown) {
            try DirectUpdateProcessInventory.captureEntries(table: live)
        }
        #expect(kill(child.processIdentifier, 0) == 0)
    }
    @Test func participantAndReleasedAuthorityRefuse() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("NeAntik.app")
        // Use the same fixed namespace as ordinary startup; no user data lives here.
        let first = try DirectUpdateStoppedAuthority(installation: app)
        #expect(throws: InstallFilesystemError.busy) { try first.releaseAfterCompletion() }
        #expect(try first.tryDrainParticipants())
        try first.releaseAfterCompletion()
        #expect(throws: DirectUpdateStoppedError.released) { try first.validateStopped() }
        let base = URL(fileURLWithPath: "/private/tmp/neantik-update-lifecycle-\(geteuid())")
        let namespace = base.appendingPathComponent(try InstallLifecycle.namespaceName(installationURL: app))
        var participant: InstallLifecycleParticipant? = try InstallLifecycleParticipant(namespaceURL: namespace)
        let authority = try DirectUpdateStoppedAuthority(installation: app)
        #expect(throws: DirectUpdateStoppedError.busy) { try authority.validateStopped() }
        #expect(throws: InstallFilesystemError.busy) { try participant!.requireNewWork() }
        participant = nil
        #expect(try authority.tryDrainParticipants())
        try authority.releaseAfterCompletion()
        #expect(throws: DirectUpdateStoppedError.released) { try authority.releaseAfterCompletion() }
    }
    @Test func actualTaskCancellationCannotReverseCompletionRelease() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task.detached {
            let authority = try DirectUpdateStoppedAuthority(installation: root.appendingPathComponent("NeAntik.app"))
            try #require(try authority.tryDrainParticipants())
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            try authority.releaseAfterCompletion()
            #expect(throws: DirectUpdateStoppedError.released) { try authority.tryDrainParticipants() }
        }
        try await task.value
    }
}
