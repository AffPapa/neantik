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
                isResolvingRuntime: false,
                browserDataPath:
                    "/Users/example/Library/Application Support/NeAntik Development/Profiles/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/BrowserData",
                clipboardNotice: nil,
                isSidebarVisible: true,
                onToggleSidebar: {},
                onCreate: {},
                onStart: {},
                onStop: {},
                onEdit: {},
                onDuplicate: {},
                onTogglePinned: {},
                onToggleArchived: {},
                onDelete: {},
                onReveal: {},
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

        try render(
            BulkProxyImportView { _, _ in },
            name: "bulk-proxy-import-minimum",
            size: CGSize(width: 500, height: 500)
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
            tags: ["Работа", "Клиент"]
        )
        for (name, size, sidebarVisible) in [
            (
                "profile-detail-sidebar-hidden",
                CGSize(width: 820, height: 560),
                false
            ),
            (
                "profile-detail-ordinary",
                CGSize(width: 900, height: 600),
                true
            ),
            (
                "profile-detail-wide",
                CGSize(width: 1_600, height: 1_000),
                true
            ),
        ] {
            try render(
                ProfileDetailView(
                    profile: profile,
                    processState: .stopped,
                    isResolvingRuntime: false,
                    browserDataPath:
                        "/Users/example/Library/Application Support/NeAntik Development/Profiles/PROFILE/BrowserData",
                    clipboardNotice: nil,
                    isSidebarVisible: sidebarVisible,
                    onToggleSidebar: {},
                    onCreate: {},
                    onStart: {},
                    onStop: {},
                    onEdit: {},
                    onDuplicate: {},
                    onTogglePinned: {},
                    onToggleArchived: {},
                    onDelete: {},
                    onReveal: {},
                    onCopyProxyUsername: {},
                    onCopyProxyPassword: {}
                ),
                name: name,
                size: size
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
                proxy: ProxyConfiguration(
                    kind: .https,
                    host: "2001:db8::1",
                    port: 8_080,
                    username: "operator"
                )
            )
        )

        for (name, size) in [
            (
                "actual-content-minimum",
                CGSize(
                    width: WorkspaceLayout.minimumWindowWidth,
                    height: WorkspaceLayout.minimumWindowHeight
                )
            ),
            (
                "actual-content-wide",
                CGSize(width: 1_600, height: 1_000)
            ),
        ] {
            try render(
                ContentView(
                    store: store,
                    processes: processes,
                    telemetry: telemetry,
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
    }

    @Test func workspaceKeepsFixedControlsVisibleAtMinimumWindowSize() throws {
        let profile = BrowserProfile(
            name: "Рабочий профиль",
            tags: ["Работа", "Клиент"]
        )
        try render(
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Профили")
                                .font(.title2.bold())
                            Spacer()
                            Button("", systemImage: "plus") {}
                        }
                        .padding(14)
                        TextField(
                            "Поиск по имени и тегам",
                            text: .constant("")
                        )
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        Divider()
                        List {
                            Label(
                                profile.name,
                                systemImage: profile.displaySymbolName
                            )
                        }
                        .listStyle(.sidebar)
                    }
                    .frame(
                        width: WorkspaceLayout.sidebarWidth(
                            for: proxy.size.width
                        )
                    )
                    Divider()

                    ProfileDetailView(
                        profile: profile,
                        processState: .stopped,
                        isResolvingRuntime: false,
                        browserDataPath:
                            "/Users/example/Library/Application Support/NeAntik Development/Profiles/PROFILE/BrowserData",
                        clipboardNotice: nil,
                        isSidebarVisible: true,
                        onToggleSidebar: {},
                        onCreate: {},
                        onStart: {},
                        onStop: {},
                        onEdit: {},
                        onDuplicate: {},
                        onTogglePinned: {},
                        onToggleArchived: {},
                        onDelete: {},
                        onReveal: {},
                        onCopyProxyUsername: {},
                        onCopyProxyPassword: {}
                    )
                }
            }
            .frame(
                minWidth: WorkspaceLayout.minimumWindowWidth,
                minHeight: WorkspaceLayout.minimumWindowHeight
            ),
            name: "workspace-window-minimum",
            size: CGSize(
                width: WorkspaceLayout.minimumWindowWidth,
                height: WorkspaceLayout.minimumWindowHeight
            ),
            styleMask: [
                .titled,
                .closable,
                .resizable,
            ]
        )

        try render(
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Профили")
                            .font(.title2.bold())
                        TextField(
                            "Поиск по имени и тегам",
                            text: .constant("")
                        )
                        List {
                            Label(
                                profile.name,
                                systemImage: profile.displaySymbolName
                            )
                        }
                        .listStyle(.sidebar)
                    }
                    .padding(14)
                    .frame(
                        width: WorkspaceLayout.sidebarWidth(
                            for: proxy.size.width
                        )
                    )
                    Divider()

                    ProfileDetailView(
                        profile: profile,
                        processState: .stopped,
                        isResolvingRuntime: false,
                        browserDataPath:
                            "/Users/example/Library/Application Support/NeAntik Development/Profiles/PROFILE/BrowserData",
                        clipboardNotice: nil,
                        isSidebarVisible: true,
                        onToggleSidebar: {},
                        onCreate: {},
                        onStart: {},
                        onStop: {},
                        onEdit: {},
                        onDuplicate: {},
                        onTogglePinned: {},
                        onToggleArchived: {},
                        onDelete: {},
                        onReveal: {},
                        onCopyProxyUsername: {},
                        onCopyProxyPassword: {}
                    )
                }
            },
            name: "workspace-window-wide",
            size: CGSize(width: 1_600, height: 1_000)
        )
    }

    private func render<V: View>(
        _ view: V,
        name: String,
        size: CGSize,
        styleMask: NSWindow.StyleMask = [.borderless]
    ) throws {
        let hostingView = NSHostingView(
            rootView:
                view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        let appearance = NSAppearance(named: .darkAqua)
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
