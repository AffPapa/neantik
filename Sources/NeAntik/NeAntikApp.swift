import Darwin
import Foundation
import SwiftUI

@main
struct NeAntikApp: App {
    @StateObject private var store: ProfileStore
    @StateObject private var processes: BrowserProcessManager
    @StateObject private var runtimePreferences: RuntimePreferenceStore
    @StateObject private var telemetry: TelemetryController

    private let keychain: KeychainStore
    private let credentialCleanup: DeletedProfileCredentialCleanup
    private let runtimeLocator = BrowserRuntimeLocator()
    private let launchIntent: NeAntikLaunchIntent
    private let fingerprintEvidenceReleaseContext:
        FingerprintEvidenceReleaseContext?

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
                    switch try FingerprintEvidenceReleaseContext.load(
                            request: request,
                            executableURL: URL(
                                fileURLWithPath:
                                    CommandLine.arguments[0]
                            )
                        ) {
                    case let .audit(context):
                        fingerprintEvidenceReleaseContext = context
                    case .recovered:
                        Darwin.exit(EXIT_SUCCESS)
                    }
                } catch {
                    Self.writeControlErrorAndExit(
                        "Не удалось подготовить защищённую проверку выпуска.\n",
                        code: EX_DATAERR
                    )
                }
            } else {
                fingerprintEvidenceReleaseContext = nil
            }
        }

        let paths = AppPaths()
        let keychain = KeychainStore()
        self.keychain = keychain
        credentialCleanup = DeletedProfileCredentialCleanup(
            paths: paths,
            keychain: keychain
        )
        _store = StateObject(wrappedValue: ProfileStore(paths: paths))
        _processes = StateObject(wrappedValue: BrowserProcessManager(paths: paths))
        _runtimePreferences = StateObject(
            wrappedValue: RuntimePreferenceStore(paths: paths)
        )
        _telemetry = StateObject(
            wrappedValue: TelemetryController(edition: .direct)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: store,
                processes: processes,
                runtimePreferences: runtimePreferences,
                telemetry: telemetry,
                keychain: keychain,
                credentialCleanup: credentialCleanup,
                runtimeLocator: runtimeLocator,
                launchIntent: launchIntent,
                fingerprintEvidenceReleaseContext:
                    fingerprintEvidenceReleaseContext
            )
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый профиль") {
                    NotificationCenter.default.post(
                        name: .neAntikCreateProfile,
                        object: nil
                    )
                }
                .keyboardShortcut("n")
            }
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

extension Notification.Name {
    static let neAntikCreateProfile = Notification.Name("NeAntikCreateProfile")
}
