import AppKit
import SwiftUI
import Testing
@testable import NeAntik

@MainActor
struct ResponsiveLayoutRenderTests {
    @Test func primaryScreensRenderAtTheirMinimumSizes() throws {
        let profileA = BrowserProfile(
            name:
                "Очень длинное Unicode-название профиля для проверки переноса",
            tags: ["Работа", "Магазин"],
            note:
                "Клиент предпочитает утренний запуск. Перед работой проверь заказ и не меняй сохранённый маршрут без согласования.\nСледующий шаг: открыть кабинет и сверить статус.",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "2001:db8::1",
                port: 8_080,
                username: "operator"
            )
        )
        let profileB = BrowserProfile(
            name: "Второй профиль",
            tags: ["Личный"]
        )

        try render(
            ProfileDetailView(
                profile: profileA,
                processState: .stopped,
                browserDataPath:
                    "/Users/example/Library/Application Support/NeAntik Development/Profiles/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/BrowserData",
                environmentSnapshot: ProfileEnvironmentInspector.snapshot(
                    profile: profileA,
                    runtime: nil,
                    proxyHealth: nil
                ),
                clipboardNotice: nil,
                onCopyProxyUsername: {},
                onCopyProxyPassword: {}
            ),
            name: "profile-detail-minimum",
            size: CGSize(width: 550, height: 520)
        )

        try render(
            ProfileEditorView(
                original: profileA,
                keychain: KeychainStore(
                    backend: LayoutRenderKeychainBackend(),
                    service: "layout.render.proxy",
                    legacyService: nil
                ),
                showsAdvancedOptionsInitially: true
            ) { _, _ in },
            name: "profile-editor-minimum",
            size: CGSize(width: 460, height: 380)
        )

        for (appearanceName, colorScheme) in [
            ("light", ColorScheme.light),
            ("dark", ColorScheme.dark),
        ] {
            try render(
                ProfileEditorView(
                    original: nil,
                    keychain: KeychainStore(
                        backend: LayoutRenderKeychainBackend(),
                        service: "layout.render.new-note.\(appearanceName)",
                        legacyService: nil
                    ),
                    folders: [],
                    initialFolderID: nil,
                    suggestedTags: []
                ) { _, _, _ in },
                name: "profile-editor-new-note-visible-\(appearanceName)",
                size: CGSize(width: 460, height: 430),
                colorScheme: colorScheme
            )

            try render(
                ProfileEditorView(
                    original: profileA,
                    keychain: KeychainStore(
                        backend: LayoutRenderKeychainBackend(),
                        service: "layout.render.note.\(appearanceName)",
                        legacyService: nil
                    ),
                    folders: [],
                    initialFolderID: nil,
                    suggestedTags: profileA.tags,
                    initialFocus: .note
                ) { _, _, _ in },
                name: "profile-editor-note-expanded-\(appearanceName)",
                size: CGSize(width: 540, height: 540),
                colorScheme: colorScheme
            )
        }

        try render(
            ProfileFolderPickerSheet(
                profileName: profileA.name,
                folders: (0..<24).map {
                    ProfileFolder(name: "Папка \($0 + 1)")
                },
                selectedFolderID: nil,
                onSelect: { _ in }
            ),
            name: "profile-folder-picker",
            size: CGSize(width: 460, height: 500)
        )

        let manyFolders = (0..<24).map {
            ProfileFolder(name: "Папка \($0 + 1)")
        }
        try render(
            ProfileEditorView(
                original: profileA,
                keychain: KeychainStore(
                    backend: LayoutRenderKeychainBackend(),
                    service: "layout.render.folders",
                    legacyService: nil
                ),
                folders: manyFolders,
                initialFolderID: manyFolders.last?.id,
                suggestedTags: profileA.tags
            ) { _, _, _ in },
            name: "profile-editor-many-folders",
            size: CGSize(width: 540, height: 540)
        )

        try render(
            BulkProxyImportView { _, _ in },
            name: "bulk-proxy-import-empty",
            size: CGSize(width: 560, height: 600)
        )

        try render(
            BulkProxyImportView(
                targetFolderName: "QA Workspace",
                initialText:
                    "one.example:8080\nuser:secret@two.example:8443"
            ) { _, _ in },
            name: "bulk-proxy-import-valid",
            size: CGSize(width: 560, height: 640)
        )

        try render(
            BulkProxyImportView(
                targetFolderName: "QA Workspace",
                initialText:
                    "one.example:8080\ninvalid row\ntwo.example:8443"
            ) { _, _ in },
            name: "bulk-proxy-import-mixed-error",
            size: CGSize(width: 560, height: 660)
        )

        try render(
            BulkProxyImportView(
                targetFolderName: "QA Workspace",
                initialText: [
                    "one.example:8001",
                    "two.example:8002",
                    "three.example:8003",
                    "four.example:8004",
                    "five.example:8005",
                    "six.example:8006",
                    "invalid row after preview limit",
                ].joined(separator: "\n")
            ) { _, _ in },
            name: "bulk-proxy-import-late-error",
            size: CGSize(width: 560, height: 720)
        )

        try render(
            BulkProxyImportView(
                targetFolderName: "QA Workspace",
                initialText: "one.example:8080",
                showsOptionsInitially: true
            ) { _, _ in },
            name: "bulk-proxy-import-options-expanded",
            size: CGSize(width: 560, height: 760)
        )

        try render(
            FirstProfileOnboardingView(
                runtimeAvailability: .ready,
                isCreatingProfile: false,
                onCreateAndOpen: {},
                onRetryRuntimeCheck: {},
                onConfigure: {}
            ),
            name: "first-profile-onboarding-ready-narrow",
            size: CGSize(width: 360, height: 480)
        )

        try render(
            FirstProfileOnboardingView(
                runtimeAvailability: .resolving,
                isCreatingProfile: false,
                onCreateAndOpen: {},
                onRetryRuntimeCheck: {},
                onConfigure: {}
            ),
            name: "first-profile-onboarding-resolving-narrow",
            size: CGSize(width: 360, height: 480)
        )

        try render(
            FirstProfileOnboardingView(
                runtimeAvailability: .missing,
                isCreatingProfile: false,
                onCreateAndOpen: {},
                onRetryRuntimeCheck: {},
                onConfigure: {}
            ),
            name: "first-profile-onboarding-missing-narrow",
            size: CGSize(width: 360, height: 480)
        )

        try render(
            ProfileFolderPickerUnavailableSheet(),
            name: "profile-folder-picker-unavailable",
            size: CGSize(width: 460, height: 280)
        )

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "neantik-layout-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let paths = AppPaths(rootDirectory: temporaryRoot)
        try paths.prepareBaseDirectories()
        let runtimeExecutable = temporaryRoot.appendingPathComponent(
            "NeAntik Browser"
        )
        FileManager.default.createFile(
            atPath: runtimeExecutable.path,
            contents: Data()
        )
        let runtime = BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: runtimeExecutable,
            source: "Встроен",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "150.0.7871.186",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )
        try render(
            ProfileEnvironmentView(
                snapshot: ProfileEnvironmentInspector.snapshot(
                    profile: profileB,
                    runtime: runtime,
                    proxyHealth: nil
                ),
                hasProxy: false,
                isTestingProxy: false,
                canTestProxy: false,
                canCancelProxyTest: false,
                canRunFingerprintAudit: false,
                onTestProxy: {},
                onRunFingerprintAudit: {}
            ),
            name: "profile-environment-direct-ready",
            size: CGSize(width: 900, height: 360)
        )
        try render(
            ProfileEnvironmentView(
                snapshot: ProfileEnvironmentInspector.snapshot(
                    profile: profileB,
                    runtime: runtime,
                    proxyHealth: nil
                ),
                hasProxy: false,
                isTestingProxy: false,
                canTestProxy: false,
                canCancelProxyTest: false,
                canRunFingerprintAudit: false,
                onTestProxy: {},
                onRunFingerprintAudit: {}
            ),
            name: "profile-environment-direct-ready-light",
            size: CGSize(width: 900, height: 360),
            colorScheme: .light
        )
        try render(
            ProfileEnvironmentView(
                snapshot: ProfileEnvironmentInspector.snapshot(
                    profile: profileA,
                    runtime: runtime,
                    proxyHealth: nil
                ),
                hasProxy: true,
                isTestingProxy: false,
                canTestProxy: true,
                canCancelProxyTest: false,
                canRunFingerprintAudit: false,
                onTestProxy: {},
                onRunFingerprintAudit: {}
            ),
            name: "profile-environment-proxy-auto-light",
            size: CGSize(width: 900, height: 360),
            colorScheme: .light
        )
        try render(
            FingerprintAuditView(
                profiles: [profileA, profileB],
                initialFirstID: profileA.id,
                runtime: runtime,
                processes: BrowserProcessManager(paths: paths),
                paths: paths
            ),
            name: "profile-audit-minimum",
            size: CGSize(width: 540, height: 480)
        )
    }

    @Test func profileDetailRendersAtOrdinaryAndWideSizes() throws {
        let profile = BrowserProfile(
            name: "Рабочий профиль",
            tags: ["Работа", "Клиент"],
            note:
                "Это длинная заметка профиля для проверки трёхстрочного превью. Она содержит рабочий контекст, следующий шаг и напоминание о том, что полный текст остаётся доступным по отдельной кнопке без перегрузки основного экрана."
        )
        for (name, size) in [
            (
                "profile-detail-compact",
                CGSize(width: 820, height: 560)
            ),
            (
                "profile-detail-ordinary",
                CGSize(width: 900, height: 600)
            ),
            (
                "profile-detail-wide",
                CGSize(width: 1_600, height: 1_000)
            ),
        ] {
            try render(
                ProfileDetailView(
                    profile: profile,
                    processState: .stopped,
                    browserDataPath:
                        "/Users/example/Library/Application Support/NeAntik Development/Profiles/PROFILE/BrowserData",
                    clipboardNotice: nil,
                    onCopyProxyUsername: {},
                    onCopyProxyPassword: {}
                ),
                name: name,
                size: size
            )
        }

        for (appearanceName, colorScheme) in [
            ("light", ColorScheme.light),
            ("dark", ColorScheme.dark),
        ] {
            try render(
                ProfileDetailView(
                    profile: BrowserProfile(name: "Профиль без заметки"),
                    processState: .stopped,
                    browserDataPath:
                        "/Users/example/Library/Application Support/NeAntik Development/Profiles/EMPTY/BrowserData",
                    clipboardNotice: nil,
                    onCopyProxyUsername: {},
                    onCopyProxyPassword: {},
                    onChangeNote: {}
                ),
                name: "profile-detail-empty-note-minimum-\(appearanceName)",
                size: CGSize(width: 550, height: 520),
                colorScheme: colorScheme
            )

            try render(
                ProfileDetailView(
                    profile: profile,
                    processState: .stopped,
                    browserDataPath:
                        "/Users/example/Library/Application Support/NeAntik Development/Profiles/PROFILE/BrowserData",
                    clipboardNotice: nil,
                    onCopyProxyUsername: {},
                    onCopyProxyPassword: {}
                ),
                name: "profile-detail-note-minimum-\(appearanceName)",
                size: CGSize(width: 550, height: 520),
                colorScheme: colorScheme
            )
        }
    }

    @Test func actualContentViewRendersAtMinimumAndWideSizes() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "neantik-content-layout-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let paths = AppPaths(rootDirectory: temporaryRoot)
        let store = ProfileStore(paths: paths)
        let runtimeExecutable = temporaryRoot.appendingPathComponent(
            "NeAntik Browser"
        )
        #expect(
            FileManager.default.createFile(
                atPath: runtimeExecutable.path,
                contents: Data("runtime".utf8),
                attributes: [.posixPermissions: 0o700]
            )
        )
        let runtimeLocator = BrowserRuntimeLocator(
            runtimeInspector: { _ in
                BrowserRuntimeInspection(
                    version: "151.0.7922.75",
                    architectures: ["arm64"],
                    codeSignatureValid: true
                )
            },
            candidates: [
                BrowserRuntimeLocator.Candidate(
                    name: "NeAntik Browser",
                    url: runtimeExecutable,
                    source: "Встроен",
                    flavor: .fingerprintChromium
                )
            ]
        )
        let keychain = KeychainStore(
            backend: LayoutRenderKeychainBackend(),
            service: "layout.content.proxy",
            legacyService: nil
        )
        let defaultsName = "NeAntik.Layout.\(UUID().uuidString)"
        let defaults = try #require(
            UserDefaults(suiteName: defaultsName)
        )
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let telemetry = TelemetryController(
            edition: .direct,
            configuration: TelemetryConfiguration(
                endpoint: nil,
                publicStatsURL: nil
            ),
            defaults: defaults
        )
        let processes = BrowserProcessManager(paths: paths)
        let intent = NeAntikLaunchIntent.parse(
            arguments: [
                "/Applications/NeAntik.app/Contents/MacOS/NeAntik"
            ]
        )

        for (name, size) in [
            (
                "actual-empty-content-minimum",
                CGSize(
                    width: WorkspaceLayout.minimumWindowWidth,
                    height: WorkspaceLayout.minimumWindowHeight
                )
            ),
            (
                "actual-empty-content-wide",
                CGSize(width: 1_600, height: 1_000)
            ),
        ] {
            try render(
                ContentView(
                    store: store,
                    processes: processes,
                    telemetry: telemetry,
                    fingerprintObservationStore:
                        FingerprintObservationStore(),
                    proxyHealthCoordinator: ProxyHealthCoordinator(
                        fileURL: paths.proxyHealthFile
                    ),
                    keychain: keychain,
                    credentialCleanup:
                        DeletedProfileCredentialCleanup(
                            paths: paths,
                            keychain: keychain
                        ),
                    runtimeLocator: runtimeLocator,
                    launchIntent: intent,
                    fingerprintEvidenceReleaseContext: nil
                ),
                name: name,
                size: size,
                styleMask: [
                    .titled,
                    .closable,
                    .resizable,
                ]
            )
        }

        _ = try store.upsert(
            BrowserProfile(
                name:
                    "Очень длинное Unicode-название рабочего профиля",
                tags: ["Работа", "Проверка"],
                note:
                    "Клиент: утренний запуск. Сначала проверь заказ и статус кабинета.",
                proxy: ProxyConfiguration(
                    kind: .https,
                    host: "2001:db8::1",
                    port: 8_080,
                    username: "operator"
                )
            )
        )
        for profile in [
            BrowserProfile(
                name: "TikTok · FR · UGC 02",
                tags: ["TikTok", "Фарм"],
                note: "Прогрев: день 3. Следующий вход после 18:00."
            ),
            BrowserProfile(
                name: "Facebook Ads · DE · BM 04",
                tags: ["Facebook", "Работа"],
                proxy: ProxyConfiguration(
                    kind: .socks5,
                    host: "proxy.example",
                    port: 10_804,
                    username: ""
                )
            ),
            BrowserProfile(
                name: "Native · RU · Teaser 07",
                tags: ["Тизерки"],
                note: "Креативы проверены. Не менять гео без согласования."
            ),
        ] {
            _ = try store.upsert(profile)
        }

        let reviewedSizes: [(String, CGSize)] = [
            (
                "minimum",
                CGSize(
                    width: WorkspaceLayout.minimumWindowWidth,
                    height: WorkspaceLayout.minimumWindowHeight
                )
            ),
            ("ordinary", CGSize(width: 1_100, height: 720)),
            ("wide", CGSize(width: 1_600, height: 1_000)),
        ]
        let reviewedAppearances: [(String, ColorScheme)] = [
            ("light", .light),
            ("dark", .dark),
        ]
        for (sizeName, size) in reviewedSizes {
            for (appearanceName, colorScheme) in reviewedAppearances {
                try render(
                    ContentView(
                        store: store,
                        processes: processes,
                        telemetry: telemetry,
                        fingerprintObservationStore:
                            FingerprintObservationStore(),
                        proxyHealthCoordinator: ProxyHealthCoordinator(
                            fileURL: paths.proxyHealthFile
                        ),
                        keychain: keychain,
                        credentialCleanup:
                            DeletedProfileCredentialCleanup(
                                paths: paths,
                                keychain: keychain
                            ),
                        runtimeLocator: runtimeLocator,
                        launchIntent: intent,
                        fingerprintEvidenceReleaseContext: nil
                    ),
                    name: "actual-content-\(sizeName)-\(appearanceName)",
                    size: size,
                    styleMask: [
                        .titled,
                        .closable,
                        .resizable,
                    ],
                    colorScheme: colorScheme
                )
            }
        }
    }

    private func render<V: View>(
        _ view: V,
        name: String,
        size: CGSize,
        styleMask: NSWindow.StyleMask = [.borderless],
        colorScheme: ColorScheme = .dark
    ) throws {
        let hostingView = NSHostingView(
            rootView:
                view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, colorScheme)
        )
        let appearance = NSAppearance(
            named: colorScheme == .dark ? .darkAqua : .aqua
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        window.setFrameOrigin(
            NSPoint(
                x: -size.width - 100,
                y: -size.height - 100
            )
        )
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        hostingView.appearance = appearance
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(
            until: Date(timeIntervalSinceNow: 0.05)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let representation = hostingView
            .bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        else {
            throw LayoutRenderError.imageUnavailable(name)
        }
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: representation
        )
        guard representation.pixelsWide >= Int(size.width),
              representation.pixelsHigh >= Int(size.height),
              let data = representation.representation(
                  using: .png,
                  properties: [:]
              ),
              data.count > 10_000
        else {
            throw LayoutRenderError.invalidImage(name)
        }

        if let output = ProcessInfo.processInfo.environment[
            "NEANTIK_UI_RENDER_DIR"
        ] {
            let directory = URL(
                fileURLWithPath: output,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(
                to: directory.appendingPathComponent("\(name).png"),
                options: .atomic
            )
        }
    }
}

private struct LayoutRenderKeychainBackend: KeychainBackend {
    func data(service: String, profileID: UUID) throws -> Data? {
        nil
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {}

    func delete(service: String, profileID: UUID) throws {}
}

private enum LayoutRenderError: LocalizedError {
    case imageUnavailable(String)
    case invalidImage(String)

    var errorDescription: String? {
        switch self {
        case .imageUnavailable(let name):
            "Не удалось создать off-screen изображение \(name)."
        case .invalidImage(let name):
            "Off-screen изображение \(name) пустое или повреждено."
        }
    }
}
