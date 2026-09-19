import Dispatch
import Foundation
import Testing
@testable import NeAntik

struct BrowserLaunchMemoryGuardTests {
    @MainActor @Test func latePressureReleasesNewLeaseAndKeepsExistingBrowser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-browser")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let paths = AppPaths(rootDirectory: root.appendingPathComponent("data"))
        var admissionChecks = 0
        let manager = BrowserProcessManager(paths: paths,
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent },
            launchIsBlockedByMemoryPressure: {
                admissionChecks += 1
                return admissionChecks >= 4
            })
        let runtime = BrowserRuntime(name: "Test", executableURL: executable, source: "Test")
        let existing = BrowserProfile(name: "Existing")
        let rejected = BrowserProfile(name: "Rejected")
        defer { manager.stop(profileID: existing.id) }
        try manager.launch(profile: existing, runtime: runtime)
        let sentinel = paths.browserDataDirectory(for: existing.id).appendingPathComponent("synthetic-data")
        try Data("retain-me".utf8).write(to: sentinel)
        do {
            try manager.launch(profile: rejected, runtime: runtime)
            Issue.record("Expected late memory rejection")
        } catch {
            #expect(error.localizedDescription.contains("оперативной памяти"))
        }
        #expect(admissionChecks == 4)
        #expect(manager.runningProfileIDs == [existing.id])
        #expect(!FileManager.default.fileExists(atPath: paths.lockFile(for: rejected.id).path))
        #expect(try Data(contentsOf: sentinel) == Data("retain-me".utf8))
        manager.stop(profileID: existing.id)
        for _ in 0..<100 where !manager.runningProfileIDs.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(manager.runningProfileIDs.isEmpty)
    }

    @Test func criticalBlocksUntilNormalAndWinsCoalescedEvents() {
        let guardState = BrowserLaunchMemoryGuard(observeSystem: false)
        #expect(!guardState.isLaunchBlocked)
        guardState.receive(.warning)
        #expect(!guardState.isLaunchBlocked)
        guardState.receive(.critical)
        #expect(guardState.isLaunchBlocked)
        guardState.receive(.warning)
        #expect(guardState.isLaunchBlocked)
        guardState.receive([])
        #expect(guardState.isLaunchBlocked)
        guardState.receive([.critical, .normal])
        #expect(guardState.isLaunchBlocked)
        guardState.receive(.normal)
        #expect(!guardState.isLaunchBlocked)
    }

    @MainActor @Test func criticalAdmissionHasNoProfileSideEffectsAndCanRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let guardState = BrowserLaunchMemoryGuard(observeSystem: false)
        let manager = BrowserProcessManager(paths: AppPaths(rootDirectory: root),
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent },
            launchIsBlockedByMemoryPressure: { guardState.isLaunchBlocked })
        let runtime = BrowserRuntime(name: "Test", executableURL: URL(fileURLWithPath: "/missing-browser"), source: "Test")
        guardState.receive(.critical)
        do {
            try manager.launch(profile: BrowserProfile(name: "Synthetic"), runtime: runtime)
            Issue.record("Expected memory admission rejection")
        } catch NeAntikError.criticalMemoryPressure {
            // Expected before runtime preparation or profile-directory creation.
        }
        #expect(manager.runningProfileIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        guardState.receive(.normal)
        try manager.validateMemoryForLaunch()
    }
}
