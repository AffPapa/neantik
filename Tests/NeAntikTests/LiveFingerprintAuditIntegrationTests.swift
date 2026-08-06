import Foundation
import Testing
@testable import NeAntik

struct LiveFingerprintAuditIntegrationTests {
    @Test
    @MainActor
    func exactPackagedRuntimeCompletesBrowserModeAudit() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEANTIK_RUN_LIVE_FINGERPRINT_AUDIT"] == "1" else {
            return
        }
        let resultURL = environment["NEANTIK_LIVE_AUDIT_RESULT"].map {
            URL(fileURLWithPath: $0)
        }
        guard let appPath = environment["NEANTIK_LIVE_AUDIT_APP"],
              !appPath.isEmpty
        else {
            Issue.record("NEANTIK_LIVE_AUDIT_APP is required.")
            return
        }

        let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
        let runtimeExecutable = appURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent("NeAntik Browser.app")
            .appendingPathComponent("Contents/MacOS/NeAntik Browser")
        guard FileManager.default.isExecutableFile(
            atPath: runtimeExecutable.path
        ) else {
            Issue.record("Packaged NeAntik runtime is unavailable.")
            return
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "neantik-live-fingerprint-audit-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let paths = AppPaths(rootDirectory: temporaryRoot)
        let processes = BrowserProcessManager(paths: paths)
        let coordinator = FingerprintAuditCoordinator(
            paths: paths,
            processes: processes
        )
        let runtime = BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: runtimeExecutable,
            source: "Packaged live integration test",
            flavor: .fingerprintChromium
        )
        let first = BrowserProfile(
            name: "Integration A",
            identity: BrowserIdentity(seed: 11)
        )
        let second = BrowserProfile(
            name: "Integration B",
            identity: BrowserIdentity(seed: 12)
        )

        coordinator.start(
            first: first,
            second: second,
            runtime: runtime,
            executionMode: .browser,
            managerVersion: "live-integration",
            managerBuild: "0"
        )

        for _ in 0..<600 where coordinator.isRunning {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard !coordinator.isRunning else {
            coordinator.cancel()
            Issue.record("Live fingerprint audit timed out.")
            return
        }
        guard let report = coordinator.report else {
            if let resultURL {
                try (
                    "error: " +
                    (coordinator.errorMessage ?? "unknown error") +
                    "\n"
                ).write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            print(
                "LIVE_FINGERPRINT_ERROR " +
                    (coordinator.errorMessage ?? "unknown error")
            )
            Issue.record(
                "Live fingerprint audit did not produce a report."
            )
            return
        }

        if let resultURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes
            ]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(
                to: resultURL,
                options: .atomic
            )
        }
        if !report.publicAlphaReleaseIssues.isEmpty {
            print("LIVE_FINGERPRINT_RELEASE_ISSUES")
            for issue in report.publicAlphaReleaseIssues {
                print("- \(issue)")
            }
        }
        #expect(report.isPublicAlphaReleaseQualified)
    }
}
