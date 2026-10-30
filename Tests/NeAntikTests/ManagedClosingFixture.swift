import Foundation
@testable import NeAntik

/// File-controlled shell child and injected inventory; never a browser, real
/// profile, Keychain or native QA result. Every exit is explicitly released.
@MainActor
final class ManagedClosingFixture {
    let root: URL
    let paths: AppPaths
    let executable: URL
    var profile = BrowserProfile(name: "Own closing fixture")
    var inspection = BrowserDataProcessInspection.absent
    var identity = BrowserProcessIdentityInspection.unrelated
    var time = Date(timeIntervalSince1970: 2_000)
    var acceptsStop = true
    var stopCalls = 0
    lazy var runtime = BrowserRuntime(name: "Own shell", executableURL: executable, source: "Synthetic")
    lazy var manager = BrowserProcessManager(
        launchAdmission: ManagerLaunchAdmission(observePressure: false, thermalState: { .nominal }),
        paths: paths, processIdentityInspector: { [unowned self] _ in identity },
        processLivenessValidator: { _ in false },
        managedProcessTerminator: { [unowned self] _ in stopCalls += 1; return acceptsStop },
        observationIntervalNanoseconds: 10_000_000,
        browserDataProcessInspector: { [unowned self] _ in inspection },
        potentialRelayOwnerInspector: { .absent },
        now: { [unowned self] in time }
    )

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-closing-\(UUID())")
        paths = AppPaths(rootDirectory: root.appendingPathComponent("data"))
        executable = root.appendingPathComponent("owned-child")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nwhile [ -f \"$0\" ] && [ ! -f \"$0.finish\" ]; do sleep 0.01; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func launch() throws { try manager.launch(profile: profile, runtime: runtime) }
    func finishMain() throws { try Data().write(to: executable.appendingPathExtension("finish")) }

    func waitForMainExit() async throws {
        for _ in 0..<200 {
            if (try? String(contentsOf: paths.logFile(for: profile.id), encoding: .utf8))?.contains("browser_exit") == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure.mainExitMissing
    }

    func waitForStopped() async throws {
        for _ in 0..<200 {
            if manager.processState(for: profile.id) == .stopped { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure.settlementMissing
    }

    func cleanup() {
        try? finishMain()
        manager.suspendPassiveObservations()
        // The child also exits when its own executable disappears, so an early
        // failed assertion cannot leave a shell waiting for a deleted marker.
        try? FileManager.default.removeItem(at: root)
    }

    private enum FixtureFailure: Error { case mainExitMissing, settlementMissing }
}
