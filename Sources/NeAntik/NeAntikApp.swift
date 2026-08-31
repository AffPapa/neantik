import Darwin
import AppKit
import Foundation
import SwiftUI

@main
struct NeAntikApp: App {
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
        let launchIntent = NeAntikLaunchIntent.parse(
            arguments: CommandLine.arguments
        )
        switch launchIntent.mode {
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
        let processEnvironment = ProcessInfo.processInfo.environment
        let startupIsolation = ManagerStartupProbe.isolationConfiguration(
            environment: processEnvironment,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        if ManagerStartupProbe.isRequested(environment: processEnvironment),
           startupIsolation == nil
        {
            Self.writeControlErrorAndExit(
                "Небезопасная конфигурация измерения запуска NeAntik.\n",
                code: EX_USAGE
            )
        }
        let paths: AppPaths
        let keychain: KeychainStore
        if let startupIsolation {
            paths = AppPaths(rootDirectory: startupIsolation.dataRoot)
            keychain = KeychainStore(
                backend: ManagerStartupKeychainBackend(),
                service: startupIsolation.keychainService,
                legacyService: nil
            )
        } else {
            paths = environment.isDevelopment
                ? AppPaths(
                    rootDirectory: environment.applicationSupportRoot()
                )
                : AppPaths()
            keychain = KeychainStore(
                service: environment.keychainService,
                legacyService: environment.legacyKeychainService
            )
        }
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
                ManagerStartupProbe.signalReadyIfRequested()
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
        }
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
