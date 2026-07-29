import Foundation

@main
struct NeAntikRuntimeAuditCLI {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(
                Data("Runtime audit failed: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        guard (3...5).contains(CommandLine.arguments.count) else {
            throw AuditCLIError.usage
        }

        let executableURL = URL(
            fileURLWithPath: CommandLine.arguments[1]
        ).standardizedFileURL
        let reportURL = URL(
            fileURLWithPath: CommandLine.arguments[2]
        ).standardizedFileURL
        guard executableURL.path.hasPrefix("/"),
              reportURL.path.hasPrefix("/")
        else {
            throw AuditCLIError.absolutePathsRequired
        }
        let executionMode: FingerprintAuditExecutionMode
        var managerVersion: String?
        var managerBuild: String?
        if CommandLine.arguments.count == 4 {
            guard CommandLine.arguments[3] ==
                    "--headless-single-process-diagnostic"
            else {
                throw AuditCLIError.usage
            }
            guard executableURL.lastPathComponent == "headless_shell" else {
                throw AuditCLIError.diagnosticRequiresHeadlessShell
            }
            executionMode = .headlessSingleProcessDiagnostic
        } else if CommandLine.arguments.count == 5 {
            guard CommandLine.arguments[3] == "--manager-app" else {
                throw AuditCLIError.usage
            }
            let managerApp = URL(
                fileURLWithPath: CommandLine.arguments[4],
                isDirectory: true
            ).standardizedFileURL
            guard managerApp.path.hasPrefix("/"),
                  let managerBundle = Bundle(url: managerApp),
                  let version = managerBundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                  ) as? String,
                  let build = managerBundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                  ) as? String
            else {
                throw AuditCLIError.invalidManagerApp
            }
            managerVersion = version
            managerBuild = build
            executionMode = .browser
        } else {
            executionMode = .browser
        }

        let runtime = BrowserRuntime(
            name: "NeAntik Chromium",
            executableURL: executableURL,
            source: "Owned runtime audit",
            flavor: .fingerprintChromium
        )
        let preflight = BrowserRuntimePreflightValidator.validate(runtime)
        guard preflight.isReady else {
            throw NeAntikError.runtimeValidationFailed(
                preflight.errors.joined(separator: " ")
            )
        }

        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "app.neantik.runtime-audit-cli",
                isDirectory: true
            )
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var removeWorkingRoot = false
        defer {
            if removeWorkingRoot {
                try? FileManager.default.removeItem(at: workingRoot)
            }
        }

        let paths = AppPaths(rootDirectory: workingRoot)
        let processes = BrowserProcessManager(paths: paths)
        let coordinator = FingerprintAuditCoordinator(
            paths: paths,
            processes: processes
        )
        let first = BrowserProfile(
            name: "Audit A",
            identity: BrowserIdentity(seed: 0x1357_9BDF)
        )
        let second = BrowserProfile(
            name: "Audit B",
            identity: BrowserIdentity(seed: 0x2468_ACE0)
        )

        coordinator.start(
            first: first,
            second: second,
            runtime: runtime,
            executionMode: executionMode,
            managerVersion: managerVersion,
            managerBuild: managerBuild
        )
        while coordinator.isRunning {
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if let errorMessage = coordinator.errorMessage {
            throw AuditCLIError.runtimeFailure(
                errorMessage,
                diagnosticsPath: workingRoot.path
            )
        }
        guard let report = coordinator.report,
              let savedURL = coordinator.reportURL
        else {
            throw AuditCLIError.noReport(
                diagnosticsPath: workingRoot.path
            )
        }

        let reportData = try Data(contentsOf: savedURL)
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try reportData.write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: reportURL.path
        )

        guard report.effectiveExecutionMode == executionMode else {
            throw AuditCLIError.executionModeMismatch
        }

        print("Execution mode: \(executionMode.rawValue)")
        if !executionMode.isReleaseEvidence {
            print(
                "DIAGNOSTIC ONLY: this does not replace the production GUI " +
                    "A → B → A release gate."
            )
        }
        print("Verdict: \(report.verdict.rawValue)")
        print(
            "Changed critical: " +
                report.changedCriticalKeys.joined(separator: ", ")
        )
        print(
            "Unstable critical: " +
                report.unstableCriticalKeys.joined(separator: ", ")
        )
        print("Report: \(reportURL.path)")

        guard report.verdict == .verified else {
            throw AuditCLIError.verdict(
                report.verdict.rawValue,
                diagnosticsPath: workingRoot.path
            )
        }
        if executionMode.isReleaseEvidence {
            guard report.isPublicAlphaReleaseQualified else {
                throw AuditCLIError.releaseQualification(
                    report.publicAlphaReleaseIssues,
                    diagnosticsPath: workingRoot.path
                )
            }
            print("Public alpha GUI qualification: passed")
            if !report.productionReleaseIssues.isEmpty {
                print(
                    "Hardening notes: " +
                        report.productionReleaseIssues.joined(separator: "; ")
                )
            }
        }
        removeWorkingRoot = true
    }
}

private enum AuditCLIError: LocalizedError {
    case usage
    case absolutePathsRequired
    case diagnosticRequiresHeadlessShell
    case executionModeMismatch
    case invalidManagerApp
    case runtimeFailure(String, diagnosticsPath: String)
    case noReport(diagnosticsPath: String)
    case verdict(String, diagnosticsPath: String)
    case releaseQualification([String], diagnosticsPath: String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: NeAntikRuntimeAudit /absolute/path/to/Chromium " +
                "/absolute/path/to/report.json " +
                "[--headless-single-process-diagnostic]"
        case .absolutePathsRequired:
            "The runtime executable and report paths must be absolute."
        case .diagnosticRequiresHeadlessShell:
            "The single-process diagnostic mode accepts only an executable " +
                "named headless_shell."
        case .executionModeMismatch:
            "The saved report does not match the requested execution mode."
        case .invalidManagerApp:
            "Provide a valid absolute NeAntik.app after --manager-app."
        case let .runtimeFailure(message, diagnosticsPath):
            "\(message) Diagnostics preserved at \(diagnosticsPath)."
        case let .noReport(diagnosticsPath):
            "The audit finished without producing a report. " +
                "Diagnostics preserved at \(diagnosticsPath)."
        case let .verdict(value, diagnosticsPath):
            "The owned runtime diagnostic verdict was \(value). " +
                "Diagnostics preserved at \(diagnosticsPath)."
        case let .releaseQualification(issues, diagnosticsPath):
            "The browser report is verified but not production-qualified: " +
                issues.joined(separator: " ") + " " +
                "Diagnostics preserved at \(diagnosticsPath)."
        }
    }
}
