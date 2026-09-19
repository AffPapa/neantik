import Darwin
import XCTest
@testable import NeAntik

final class SnapshotCrashBoundaryTests: XCTestCase {
    func testChildRestorationCrashBoundary() throws {
        guard let path = ProcessInfo.processInfo.environment["NEANTIK_TEST_RESTORE_CRASH_ROOT"] else {
            throw XCTSkip("Only run inside the isolated subprocess fixture")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("neantik-restore-crash-"),
              root.deletingLastPathComponent().resolvingSymlinksInPath() ==
                FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else {
            XCTFail("Unsafe synthetic test root"); return
        }
        let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: root.appendingPathComponent("owner.json")))
        let data = root.appendingPathComponent("BrowserData")
        let snapshots = AtomicProfileSnapshotStore(rootDirectory: root)
        let snapshot = try XCTUnwrap(snapshots.snapshots(for: id).first)
        let coordinator = ChromiumCompatibilityCoordinator(rootDirectory: root)
        try coordinator.record(profileID: id, runtimeVersion: "152", restorationPending: true)
        _ = try snapshots.restore(snapshot: snapshot, to: data, profileID: id, requireKnownVersion: true)
        try Data("replaced".utf8).write(to: root.appendingPathComponent("boundary"), options: .atomic)
        // Kill only this explicitly selected fixture subprocess, never another PID.
        Darwin.kill(Darwin.getpid(), SIGKILL)
        XCTFail("SIGKILL unexpectedly returned")
    }

    func testKilledRestorationProcessLeavesLaunchBlocked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-restore-crash-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("BrowserData")
        let source = root.appendingPathComponent("Source")
        for folder in [data, source] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let id = UUID()
        try JSONEncoder().encode(id).write(to: root.appendingPathComponent("owner.json"))
        try Data("old".utf8).write(to: data.appendingPathComponent("Preferences"))
        try Data("new".utf8).write(to: source.appendingPathComponent("Preferences"))
        let snapshots = AtomicProfileSnapshotStore(rootDirectory: root)
        _ = try snapshots.create(profileID: id, browserData: source, runtimeVersion: "153")
        let coordinator = ChromiumCompatibilityCoordinator(rootDirectory: root)
        try coordinator.record(profileID: id, runtimeVersion: "152")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest",
            "NeAntikTests.SnapshotCrashBoundaryTests/testChildRestorationCrashBoundary",
            Bundle(for: Self.self).bundleURL.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "NEANTIK_TEST_RESTORE_CRASH_ROOT": root.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let finished = expectation(description: "Owned crash fixture exited")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 20)
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("Fixture timed out"); return
        }
        guard process.terminationReason == .uncaughtSignal else {
            XCTFail(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            return
        }
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("boundary"), encoding: .utf8), "replaced")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("Preferences"), encoding: .utf8), "new")
        let restarted = ChromiumCompatibilityCoordinator(rootDirectory: root)
        XCTAssertNil(try restarted.recordedVersion(for: id))
        for version in ["152", "153"] {
            XCTAssertEqual(restarted.action(for: id, runtimeVersion: version,
                profileDataExists: true, snapshotAvailable: true), .rollbackRequired)
        }
    }
}
