import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ManagedBrowserQuitTests {
    @Test func acceptedQuitIsCoalescedAndKeepsLeaseUntilActualExit() async throws {
        try await exercise(accept: true)
    }
    @Test func refusedQuitKeepsRunningAndCanBeRetriedWithoutForce() async throws {
        try await exercise(accept: false)
    }
    private func exercise(accept: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-quit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let paths = AppPaths(rootDirectory: root.appendingPathComponent("data"))
        let profile = BrowserProfile(name: "Fixture")
        var calls = 0
        var ownedProcess: Process?
        let manager = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in true },
            managedProcessTerminator: { process in calls += 1; ownedProcess = process; return accept },
            browserDataProcessInspector: { _ in .absent })
        try manager.launch(profile: profile, runtime: BrowserRuntime(name: "Fixture", executableURL: executable, source: "Test"))
        manager.stop(profileID: profile.id)
        manager.stop(profileID: profile.id)
        #expect(calls == (accept ? 1 : 2))
        #expect(manager.processState(for: profile.id) == .managed)
        #expect(FileManager.default.fileExists(atPath: paths.lockFile(for: profile.id).path))
        #expect(ownedProcess?.isRunning == true)
        if !accept { #expect(manager.lastError?.contains("безопасное завершение") == true) }
        // End the disposable sleep fixture; production stop has no force fallback.
        ownedProcess?.terminate()
        for _ in 0..<50 {
            if manager.processState(for: profile.id) == .stopped { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.processState(for: profile.id) == .stopped)
        #expect(!FileManager.default.fileExists(atPath: paths.lockFile(for: profile.id).path))
    }
}
