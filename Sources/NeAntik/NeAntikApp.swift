import SwiftUI

@main
struct NeAntikApp: App {
    @StateObject private var store: ProfileStore
    @StateObject private var processes: BrowserProcessManager
    @StateObject private var runtimePreferences: RuntimePreferenceStore
    @StateObject private var telemetry: TelemetryController

    private let keychain = KeychainStore()
    private let runtimeLocator = BrowserRuntimeLocator()

    init() {
        let paths = AppPaths()
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
                runtimeLocator: runtimeLocator,
                launchIntent: .parse(arguments: CommandLine.arguments)
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
}

extension Notification.Name {
    static let neAntikCreateProfile = Notification.Name("NeAntikCreateProfile")
}
