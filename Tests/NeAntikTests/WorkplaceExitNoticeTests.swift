import Foundation
import Testing
@testable import NeAntik

@MainActor
struct WorkplaceExitNoticeTests {
    @Test
    func onlyUnexpectedExitsOfferRecovery() {
        #expect(WorkplaceExitNotice.resolve(
            classification: .crashOrSignal, wasForceStopped: false
        ) != nil)
        for classification in [BrowserExitClassification.expectedOrdinaryStop,
                               .normalExternalExit, .startupFailure] {
            #expect(WorkplaceExitNotice.resolve(
                classification: classification, wasForceStopped: false
            ) == nil)
        }
        #expect(WorkplaceExitNotice.resolve(
            classification: .crashOrSignal, wasForceStopped: true
        ) == nil)
    }

    @Test
    func crashIsScopedAndClearsOnlyAfterSuccessfulRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = BrowserProcessManager(
            paths: AppPaths(rootDirectory: root.appendingPathComponent("data")),
            processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }
        )
        let profile = BrowserProfile(name: "Private workplace")
        let other = BrowserProfile(name: "Other workplace")
        let failing = try runtime(root: root, name: "crash", script: "exit 7")
        let normal = try runtime(root: root, name: "normal", script: "exit 0")
        try manager.launch(profile: profile, runtime: failing)
        try await waitUntilStopped(manager, profile.id)
        let notice = try #require(manager.workplaceExitNotices[profile.id])
        #expect(!notice.message.contains(profile.name))
        #expect(!notice.message.contains(root.path))

        try manager.launch(profile: other, runtime: normal)
        try await waitUntilStopped(manager, other.id)
        #expect(manager.workplaceExitNotices[other.id] == nil)
        #expect(manager.workplaceExitNotices[profile.id] == notice)

        let missing = BrowserRuntime(
            name: "Missing", executableURL: root.appendingPathComponent("missing"), source: "Test"
        )
        #expect(throws: NeAntikError.self) {
            try manager.launch(profile: profile, runtime: missing)
        }
        #expect(manager.workplaceExitNotices[profile.id] == notice)

        let running = try runtime(root: root, name: "running", script: "exec /bin/sleep 30")
        defer { manager.stop(profileID: profile.id) }
        try manager.launch(profile: profile, runtime: running)
        #expect(manager.workplaceExitNotices[profile.id] == nil)
        manager.stop(profileID: profile.id)
        try await waitUntilStopped(manager, profile.id)
        #expect(manager.workplaceExitNotices[profile.id] == nil)
    }

    private func runtime(root: URL, name: String, script: String) throws -> BrowserRuntime {
        let executable = root.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        return BrowserRuntime(name: "Test", executableURL: executable, source: "Test")
    }

    private func waitUntilStopped(_ manager: BrowserProcessManager, _ id: UUID) async throws {
        for _ in 0..<400 where manager.runningProfileIDs.contains(id) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!manager.runningProfileIDs.contains(id))
    }
}
