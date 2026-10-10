import Darwin
import AppKit
import Foundation
import SwiftUI

@main
struct NeAntikApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var helpNavigation = HelpNavigation()
    @StateObject private var store: ProfileStore
    @StateObject private var processes: BrowserProcessManager
    @StateObject private var telemetry: TelemetryController
    @StateObject private var fingerprintObservationStore:
        FingerprintObservationStore
    @StateObject private var proxyHealthCoordinator:
        ProxyHealthCoordinator

    private let keychain: KeychainStore
    private let credentialCleanup: DeletedProfileCredentialCleanup
    private let runtimeLocator = BrowserRuntimeLocator()
    private let launchIntent: NeAntikLaunchIntent
    private let fingerprintEvidenceReleaseContext:
        FingerprintEvidenceReleaseContext?

    private var uiSmokeColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment[
            "NEANTIK_UI_SMOKE_COLOR_SCHEME"
        ]?.lowercased() {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    init() {
        #if DEBUG
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == BackupScopeQualification.argument {
            BackupScopeQualification.runAndExit()
        }
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == ProxyRelayOwnerQualification.argument {
            ProxyRelayOwnerQualification.runAndExit()
        }
        #endif
        let launchIntent = NeAntikLaunchIntent.parse(
            arguments: CommandLine.arguments
        )
        switch launchIntent.mode {
        case .proxyRelayOwner:
            ProxyRelayOwner.runAndExit()
        case let .mcpStdio(dataRoot):
            MCPStdioServer.runAndExit(dataRoot: dataRoot)
        case let .mcpManagement(dataRoot):
            MCPStdioServer.runAndExit(dataRoot: dataRoot, allowsManagement: true)
        case let .fingerprintEnrollment(outputURL):
            Self.runFingerprintEnrollmentAndExit(outputURL: outputURL)
        case .invalidControlArguments:
            Self.writeControlErrorAndExit(
                "Неверные параметры защищённого режима NeAntik.\n",
                code: EX_USAGE
            )
        case let .interactive(request):
            self.launchIntent = launchIntent
            if let request {
                do {
                    let executableURL = URL(
                        fileURLWithPath: CommandLine.arguments[0]
                    )
                    guard let bundleURL =
                            NeAntikLaunchIntent.applicationBundleURL(
                                forExecutablePath:
                                    CommandLine.arguments[0]
                            ),
                          let releaseBundle = Bundle(url: bundleURL)
                    else {
                        throw FingerprintEvidenceReleaseError
                            .candidateMetadataMismatch
                    }
                    switch try FingerprintEvidenceReleaseContext.load(
                            request: request,
                            executableURL: executableURL,
                            bundle: releaseBundle
                        ) {
                    case let .audit(context):
                        fingerprintEvidenceReleaseContext = context
                    case .recovered:
                        Darwin.exit(EXIT_SUCCESS)
                    }
                } catch {
                    Self.writeControlErrorAndExit(
                        "Не удалось подготовить защищённую проверку выпуска: " +
                            error.localizedDescription + "\n",
                        code: EX_DATAERR
                    )
                }
            } else {
                fingerprintEvidenceReleaseContext = nil
            }
        }

        let environment = NeAntikApplicationEnvironment.resolve(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        let auditRoot = fingerprintEvidenceReleaseContext?.request.managerDataRoot
        let paths: AppPaths
        if let auditRoot {
            paths = AppPaths(rootDirectory: auditRoot)
        } else if environment.isDevelopment {
            paths = AppPaths(rootDirectory: environment.applicationSupportRoot())
        } else {
            paths = AppPaths()
        }
        let keychain = auditRoot == nil
            ? KeychainStore.applicationStore(environment: environment, paths: paths)
            : KeychainStore(service: "app.neantik.release-audit.proxy", legacyService: nil)
        self.keychain = keychain
        credentialCleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: keychain
        )
        _store = StateObject(wrappedValue: ProfileStore(paths: paths))
        _processes = StateObject(wrappedValue: BrowserProcessManager(paths: paths))
        _telemetry = StateObject(
            wrappedValue: TelemetryController(edition: .direct)
        )
        _fingerprintObservationStore = StateObject(
            wrappedValue: FingerprintObservationStore()
        )
        _proxyHealthCoordinator = StateObject(
            wrappedValue: ProxyHealthCoordinator(
                fileURL: paths.proxyHealthFile
            )
        )
    }

    var body: some Scene {
        Window("NeAntik", id: "main") {
            ContentView(
                store: store,
                processes: processes,
                telemetry: telemetry,
                fingerprintObservationStore: fingerprintObservationStore,
                proxyHealthCoordinator: proxyHealthCoordinator,
                keychain: keychain,
                credentialCleanup: credentialCleanup,
                runtimeLocator: runtimeLocator,
                launchIntent: launchIntent,
                fingerprintEvidenceReleaseContext:
                    fingerprintEvidenceReleaseContext
            )
            .environmentObject(helpNavigation)
            .preferredColorScheme(uiSmokeColorScheme)
            .background {
                WindowMinimumSizeEnforcer(
                    minimumContentSize: CGSize(
                        width: WorkspaceLayout.minimumWindowWidth,
                        height: WorkspaceLayout.minimumWindowHeight
                    )
                )
                .frame(width: 0, height: 0)
            }
            .onAppear {
                NativeMenuLocalization.applyAfterMenuCreation()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                NativeMenuLocalization.applyAfterMenuCreation()
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            WorkspaceCommandMenu()
            ProfileCommandMenu()
            NeAntikHelpCommands(navigation: helpNavigation)
        }
        // Audit entry is explicit: do not depend on macOS restoring a main
        // scene after a previous stdio-only or closed-window session.
        .onChange(of: launchIntent.opensFingerprintAudit, initial: true) {
            if launchIntent.opensFingerprintAudit {
                Task { @MainActor in
                    await Task.yield() // Let SwiftUI register the named scene.
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
        }

        Window("Справка NeAntik", id: "help") {
            NeAntikHelpWindow(
                navigation: helpNavigation,
                connection: MCPConnectionConfiguration(
                    executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                    dataRoot: store.paths.rootDirectory
                )
            )
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)
    }

    private static func runFingerprintEnrollmentAndExit(
        outputURL: URL
    ) -> Never {
        do {
            try FingerprintEvidenceEnrollmentRunner().run(
                outputURL: outputURL
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            let detail = error.localizedDescription
            writeControlErrorAndExit(
                "Secure Enclave не подготовил данные проверки выпуска: " +
                    "\(detail)\n",
                code: EX_UNAVAILABLE
            )
        }
    }

    private static func writeControlErrorAndExit(
        _ message: String,
        code: Int32
    ) -> Never {
        if let data = message.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
        Darwin.exit(code)
    }
}
