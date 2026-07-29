import AppKit
import SwiftUI

private struct EditorRequest: Identifiable {
    let id = UUID()
    let profile: BrowserProfile?
}

private struct ClipboardNotice: Equatable {
    let profileID: UUID
    let message: String
}

struct ClipboardLeaseState: Equatable {
    private(set) var changeCount: Int?

    mutating func cancel() {
        changeCount = nil
    }

    mutating func begin(changeCount: Int) {
        self.changeCount = changeCount
    }

    mutating func consumeIfOwned(
        currentChangeCount: Int,
        expectedChangeCount: Int? = nil
    ) -> Bool {
        guard let activeChangeCount = changeCount,
              expectedChangeCount == nil ||
                expectedChangeCount == activeChangeCount
        else {
            return false
        }
        changeCount = nil
        return currentChangeCount == activeChangeCount
    }
}

struct ContentView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var processes: BrowserProcessManager
    @ObservedObject var runtimePreferences: RuntimePreferenceStore
    @ObservedObject var telemetry: TelemetryController

    let keychain: KeychainStore
    let runtimeLocator: BrowserRuntimeLocator
    let launchIntent: NeAntikLaunchIntent
    private let updateChannel = UpdateChannelConfiguration.fromBundle()

    @State private var selection: UUID?
    @State private var editorRequest: EditorRequest?
    @State private var showingDeleteConfirmation = false
    @State private var showingFingerprintAudit = false
    @State private var localError: String?
    @State private var resolvedRuntime: BrowserRuntime?
    @State private var isResolvingRuntime = true
    @State private var clipboardLease = ClipboardLeaseState()
    @State private var clipboardNotice: ClipboardNotice?
    @State private var clipboardClearTask: Task<Void, Never>?
    @State private var clipboardNoticeTask: Task<Void, Never>?
    @State private var handledReleaseAuditIntent = false

    private var selectedProfile: BrowserProfile? {
        store.profile(withID: selection)
    }

    private var runtime: BrowserRuntime? {
        resolvedRuntime
    }

    private var runtimePreflight: BrowserRuntimePreflight? {
        runtime.map(BrowserRuntimePreflightValidator.validate)
    }

    private var telemetrySnapshot: TelemetrySnapshot {
        TelemetrySnapshot(
            profileCount: store.profiles.count,
            proxyProfileCount: store.profiles.filter {
                $0.proxy != nil
            }.count
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .tint(Color(hex: "#FF3B4D"))
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $editorRequest) { request in
            ProfileEditorView(
                original: request.profile,
                keychain: keychain
            ) { profile, passwordUpdate in
                let saved = try store.upsert(profile) { saved in
                    switch passwordUpdate {
                    case .keepExisting:
                        break
                    case let .replace(password):
                        try keychain.saveProxyPassword(
                            password,
                            profileID: saved.id
                        )
                    case .delete:
                        try keychain.deleteProxyPassword(
                            profileID: saved.id
                        )
                    }
                }
                selection = saved.id
                if request.profile == nil {
                    telemetry.record(
                        .profileCreated,
                        snapshot: telemetrySnapshot
                    )
                }
                let hadProxy = request.profile?.proxy != nil
                let hasProxy = saved.proxy != nil
                if hasProxy && !hadProxy {
                    telemetry.record(
                        .proxyEnabled,
                        snapshot: telemetrySnapshot
                    )
                } else if hadProxy && !hasProxy {
                    telemetry.record(
                        .proxyDisabled,
                        snapshot: telemetrySnapshot
                    )
                }
            }
        }
        .sheet(isPresented: $showingFingerprintAudit) {
            if let runtime, store.profiles.count >= 2 {
                FingerprintAuditView(
                    profiles: store.profiles,
                    initialFirstID: selection,
                    runtime: runtime,
                    processes: processes,
                    paths: store.paths
                )
            } else {
                ContentUnavailableView(
                    "Проверка отпечатка недоступна",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "Создай минимум два профиля и выбери совместимый браузер."
                    )
                )
                .frame(width: 520, height: 360)
            }
        }
        .alert(
            "Удалить профиль?",
            isPresented: $showingDeleteConfirmation,
            presenting: selectedProfile
        ) { profile in
            Button("Переместить в Корзину", role: .destructive) {
                do {
                    try store.delete(profile) { deletedProfile in
                        try keychain.deleteProxyPassword(
                            profileID: deletedProfile.id
                        )
                    }
                    selection = store.profiles.first?.id
                    telemetry.record(
                        .profileDeleted,
                        snapshot: telemetrySnapshot
                    )
                    if profile.proxy != nil {
                        telemetry.record(
                            .proxyDisabled,
                            snapshot: telemetrySnapshot
                        )
                    }
                } catch {
                    localError = error.localizedDescription
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { profile in
            Text("Профиль «\(profile.name)» и его данные браузера будут перемещены в Корзину macOS.")
        }
        .alert(
            "NeAntik",
            isPresented: Binding(
                get: {
                    localError != nil ||
                        processes.lastError != nil ||
                        store.lastError != nil ||
                        runtimePreferences.lastError != nil
                },
                set: { presented in
                    if !presented {
                        localError = nil
                        processes.lastError = nil
                        store.lastError = nil
                        runtimePreferences.lastError = nil
                    }
                }
            )
        ) {
            Button("OK") {
                localError = nil
                processes.lastError = nil
                store.lastError = nil
                runtimePreferences.lastError = nil
            }
        } message: {
            Text(
                localError ??
                    processes.lastError ??
                    store.lastError ??
                    runtimePreferences.lastError ??
                    "Неизвестная ошибка"
            )
        }
        .onAppear {
            if selection == nil {
                selection = store.profiles.first?.id
            }
            processes.reconcile(profiles: store.profiles)
            telemetry.record(.snapshot, snapshot: telemetrySnapshot)
            presentReleaseFingerprintAuditIfNeeded()
        }
        .onChange(of: isResolvingRuntime) { _, _ in
            presentReleaseFingerprintAuditIfNeeded()
        }
        .onChange(of: telemetrySnapshot) { _, value in
            telemetry.record(.snapshot, snapshot: value)
        }
        .onReceive(NotificationCenter.default.publisher(for: .neAntikCreateProfile)) { _ in
            editorRequest = EditorRequest(profile: nil)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            cancelClipboardTasks()
            clearClipboardIfLeaseIsActive()
        }
        .task(id: runtimePreferences.preference) {
            await resolveRuntime()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            if store.profiles.isEmpty {
                ContentUnavailableView {
                    Label("Нет профилей", systemImage: "person.crop.rectangle.stack")
                } description: {
                    Text("Создай отдельный браузерный профиль за пару секунд.")
                } actions: {
                    Button("Создать профиль") {
                        editorRequest = EditorRequest(profile: nil)
                    }
                }
            } else {
                List(selection: $selection) {
                    ForEach(store.profiles) { profile in
                        let processState = processes.processState(
                            for: profile.id
                        )
                        ProfileRow(
                            profile: profile,
                            processState: processState
                        )
                        .tag(profile.id)
                        .contextMenu {
                            Button {
                                editorRequest = EditorRequest(profile: profile)
                            } label: {
                                Label("Изменить", systemImage: "slider.horizontal.3")
                            }
                            .disabled(processState.isRunning)
                            if processState.isRunning &&
                                processState.canRequestStop {
                                Button {
                                    processes.stop(profileID: profile.id)
                                } label: {
                                    Label("Остановить", systemImage: "stop.fill")
                                }
                            } else if processState.isRunning {
                                Button {} label: {
                                    Label(
                                        "Закрой браузер вручную",
                                        systemImage: "hand.raised.fill"
                                    )
                                }
                                .disabled(true)
                            } else {
                                Button {
                                    launch(profile)
                                } label: {
                                    Label("Запустить", systemImage: "play.fill")
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            runtimeStatus
            Divider()
            updateStatus
            if telemetry.isConfigured {
                Divider()
                telemetryStatus
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Профили")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Button {
                    editorRequest = EditorRequest(profile: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .help("Создать профиль")
                .accessibilityLabel("Создать профиль")
            }

            if let profile = selectedProfile {
                let processState = processes.processState(for: profile.id)
                Button {
                    if processState.isRunning {
                        processes.stop(profileID: profile.id)
                    } else {
                        launch(profile)
                    }
                } label: {
                    Label(
                        processState.isRunning
                            ? (
                                processState.canRequestStop
                                    ? "Остановить выбранный"
                                    : "Закрой браузер вручную"
                            )
                            : "Запустить выбранный",
                        systemImage:
                            processState.isRunning
                                ? (
                                    processState.canRequestStop
                                        ? "stop.fill"
                                        : "hand.raised.fill"
                                )
                                : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    (!processState.isRunning && isResolvingRuntime) ||
                        (processState.isRunning &&
                            !processState.canRequestStop)
                )
                .help(
                    processState.guidance ??
                        (
                            processState.isRunning
                                ? "Остановить профиль"
                                : "Запустить профиль"
                        )
                )
            }
        }
        .padding(.top, 46)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            ProfileDetailView(
                profile: profile,
                processState: processes.processState(for: profile.id),
                isResolvingRuntime: isResolvingRuntime,
                browserDataPath: store.paths.browserDataDirectory(for: profile.id).path,
                runtimeSupportsFingerprint: runtime?.supportsFingerprintIdentity == true,
                canRunFingerprintAudit:
                    runtime?.supportsFingerprintIdentity == true &&
                    runtimePreflight?.isReady == true &&
                    store.profiles.count >= 2,
                clipboardNotice:
                    clipboardNotice?.profileID == profile.id
                        ? clipboardNotice?.message
                        : nil,
                onStart: { launch(profile) },
                onStop: { processes.stop(profileID: profile.id) },
                onEdit: {
                    guard !processes.runningProfileIDs.contains(profile.id)
                    else {
                        localError =
                            "Сначала останови профиль. Изменения сети и браузера применяются только при следующем запуске."
                        return
                    }
                    editorRequest = EditorRequest(profile: profile)
                },
                onFingerprintAudit: {
                    showingFingerprintAudit = true
                },
                onDelete: {
                    guard !processes.runningProfileIDs.contains(profile.id) else {
                        localError = "Сначала останови профиль, потом удаляй."
                        return
                    }
                    showingDeleteConfirmation = true
                },
                onReveal: {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        store.paths.profileDirectory(for: profile.id)
                    ])
                },
                onCopyProxyUsername: {
                    guard let username = profile.proxy?.username,
                          !username.isEmpty
                    else {
                        localError = "Для этого профиля не указан логин прокси."
                        return
                    }
                    copyToClipboard(
                        username,
                        profileID: profile.id,
                        successMessage:
                            "Логин прокси скопирован. Буфер очистится через 60 секунд."
                    )
                },
                onCopyProxyPassword: {
                    do {
                        guard let password = try keychain.proxyPassword(profileID: profile.id),
                              !password.isEmpty
                        else {
                            localError = "Для этого профиля не сохранён пароль прокси."
                            return
                        }
                        copyToClipboard(
                            password,
                            profileID: profile.id,
                            successMessage:
                                "Пароль прокси скопирован. Буфер очистится через 60 секунд."
                        )
                    } catch {
                        localError = error.localizedDescription
                    }
                }
            )
            .id(profile.id)
        } else {
            ContentUnavailableView(
                "Выбери профиль",
                systemImage: "rectangle.stack.person.crop",
                description: Text("Профили разделяют сессии, cookies, настройки сети и локальные данные.")
            )
        }
    }

    private var runtimeStatus: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: runtimeStatusIcon)
                    .foregroundStyle(runtimeStatusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        isResolvingRuntime
                            ? "Проверяем браузер…"
                            : runtime?.name ?? "Браузер не найден"
                    )
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(
                        isResolvingRuntime
                            ? "Проверяем встроенный движок"
                            : runtime?.privacySummary ?? "Выбери Chromium"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let runtime {
                        Text(runtime.runtimeSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let message = runtimePreflight?.primaryMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(
                                runtimePreflight?.isReady == true
                                    ? Color.orange
                                    : Color.red
                            )
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button {
                    chooseBrowser()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Выбрать Chromium")
                .accessibilityLabel("Выбрать браузерный движок")
            }

            if runtimePreferences.preference != nil {
                Divider()
                Picker("Тип движка", selection: runtimeFlavorBinding) {
                    ForEach(BrowserRuntimeFlavor.allCases) { flavor in
                        Text(flavor.title).tag(flavor)
                    }
                }
                .font(.caption2)
                .controlSize(.mini)
                .help(
                    "Выбери протокол, который поддерживает эта сборка браузера."
                )
            }
        }
        .padding(12)
    }

    private var runtimeStatusIcon: String {
        guard let runtime else { return "exclamationmark.triangle.fill" }
        return runtime.supportsFingerprintIdentity
            ? "shield.lefthalf.filled"
            : "externaldrive.fill"
    }

    private var telemetryStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(
                "Отправлять обезличенную статистику",
                isOn: Binding(
                    get: { telemetry.isEnabled },
                    set: {
                        telemetry.setEnabled(
                            $0,
                            snapshot: telemetrySnapshot
                        )
                    }
                )
            )
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!telemetry.isConfigured)

            Text(
                telemetry.isConfigured
                    ? "Только версия приложения и общие счётчики профилей, прокси и запусков. Без сайтов и данных прокси."
                    : "Сервер статистики не настроен в этой сборке."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let url = telemetry.publicStatsURL {
                Link("Открыть публичную статистику", destination: url)
                    .font(.caption2)
            }
        }
        .padding(12)
    }

    private var updateStatus: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(updateChannel.isEnabled ? .orange : .secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    updateChannel.isEnabled
                        ? "Подписанный канал обновлений"
                        : "Обновления вручную"
                )
                .font(.caption)
                .fontWeight(.medium)

                Text(
                    updateChannel.isEnabled
                        ? "Принимаются только Ed25519-подписанные Direct-манифесты. Автозагрузка и автоустановка выключены."
                        : "Канал ещё не настроен. NeAntik ничего не проверяет и не скачивает в фоне."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private var runtimeStatusColor: Color {
        guard let runtime else { return .orange }
        if runtimePreflight?.isReady == false {
            return .red
        }
        return runtime.supportsFingerprintIdentity ? .orange : .secondary
    }

    private var runtimeFlavorBinding: Binding<BrowserRuntimeFlavor> {
        Binding(
            get: {
                runtimePreferences.preference?.flavor ?? .standard
            },
            set: { flavor in
                do {
                    try runtimePreferences.updateFlavor(flavor)
                } catch {
                    localError = error.localizedDescription
                }
            }
        )
    }

    private func launch(_ profile: BrowserProfile) {
        do {
            guard let runtime else {
                throw NeAntikError.browserNotFound
            }
            let preflight = BrowserRuntimePreflightValidator.validate(runtime)
            guard preflight.isReady else {
                throw NeAntikError.runtimeValidationFailed(
                    preflight.errors.joined(separator: " ")
                )
            }
            try processes.launch(profile: profile, runtime: runtime)
            store.markLaunched(profile.id)
            telemetry.record(
                .browserLaunched,
                snapshot: telemetrySnapshot
            )
        } catch {
            localError = error.localizedDescription
        }
    }

    private func chooseBrowser() {
        let panel = NSOpenPanel()
        panel.title = "Выбери Chromium или Google Chrome"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try runtimePreferences.select(
                    path: url.path,
                    flavor: runtimeLocator.recommendedFlavor(for: url)
                )
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func resolveRuntime() async {
        isResolvingRuntime = true
        let locator = runtimeLocator
        let preference = runtimePreferences.preference
        let value = await Task.detached(priority: .userInitiated) {
            locator.preferredRuntime(preference: preference)
        }.value
        guard !Task.isCancelled else {
            return
        }
        resolvedRuntime = value
        isResolvingRuntime = false
    }

    private func presentReleaseFingerprintAuditIfNeeded() {
        guard launchIntent.opensFingerprintAudit,
              !handledReleaseAuditIntent,
              !isResolvingRuntime
        else {
            return
        }
        handledReleaseAuditIntent = true

        guard store.profiles.count >= 2 else {
            localError =
                "Для проверки релиза нужны минимум два профиля. Создай второй профиль и запусти подготовленную команду ещё раз."
            return
        }
        guard runtime?.supportsFingerprintIdentity == true,
              runtimePreflight?.isReady == true
        else {
            localError =
                runtimePreflight?.primaryMessage ??
                "Встроенный браузер не готов к проверке отпечатка."
            return
        }

        if selection == nil {
            selection = store.profiles.first?.id
        }
        showingFingerprintAudit = true
    }

    private func clearClipboardLater(changeCount: Int) {
        clipboardClearTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            clearClipboardIfLeaseIsActive(changeCount: changeCount)
        }
    }

    private func copyToClipboard(
        _ value: String,
        profileID: UUID,
        successMessage: String
    ) {
        cancelClipboardTasks()
        clipboardLease.cancel()
        clipboardNotice = nil

        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string) else {
            localError = "Не удалось подготовить данные прокси для копирования."
            return
        }
        item.setString(
            "",
            forType: NSPasteboard.PasteboardType(
                "org.nspasteboard.TransientType"
            )
        )
        item.setString(
            "",
            forType: NSPasteboard.PasteboardType(
                "org.nspasteboard.ConcealedType"
            )
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            localError = "Не удалось скопировать данные прокси."
            return
        }
        let changeCount = pasteboard.changeCount
        clipboardLease.begin(changeCount: changeCount)
        let notice = ClipboardNotice(
            profileID: profileID,
            message: successMessage
        )
        clipboardNotice = notice
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: successMessage,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
        clearClipboardLater(changeCount: changeCount)
        clipboardNoticeTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            if clipboardNotice == notice {
                clipboardNotice = nil
            }
        }
    }

    private func cancelClipboardTasks() {
        clipboardClearTask?.cancel()
        clipboardClearTask = nil
        clipboardNoticeTask?.cancel()
        clipboardNoticeTask = nil
    }

    private func clearClipboardIfLeaseIsActive(changeCount: Int? = nil) {
        let pasteboard = NSPasteboard.general
        if clipboardLease.consumeIfOwned(
            currentChangeCount: pasteboard.changeCount,
            expectedChangeCount: changeCount
        ) {
            pasteboard.clearContents()
        }
    }
}

private struct ProfileRow: View {
    let profile: BrowserProfile
    let processState: BrowserProfileProcessState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: profile.colorHex))
                .frame(width: 11, height: 11)
                .overlay {
                    if processState.isRunning {
                        Circle()
                            .stroke(
                                processState == .externalUnverified
                                    ? Color.orange
                                    : Color.green,
                                lineWidth: 2
                            )
                            .padding(-3)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .lineLimit(1)
                Text(profile.proxy?.displayName ?? "Без прокси")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(processState.title)
    }
}

private struct ProfileDetailView: View {
    let profile: BrowserProfile
    let processState: BrowserProfileProcessState
    let isResolvingRuntime: Bool
    let browserDataPath: String
    let runtimeSupportsFingerprint: Bool
    let canRunFingerprintAudit: Bool
    let clipboardNotice: String?
    let onStart: () -> Void
    let onStop: () -> Void
    let onEdit: () -> Void
    let onFingerprintAudit: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void
    let onCopyProxyUsername: () -> Void
    let onCopyProxyPassword: () -> Void

    private var actionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 118), spacing: 10, alignment: .leading)]
    }

    private var isRunning: Bool {
        processState.isRunning
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        profileIcon
                        profileTitle
                        Spacer(minLength: 12)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        profileIcon
                        profileTitle
                    }
                }

                LazyVGrid(columns: actionColumns, alignment: .leading, spacing: 10) {
                    Button {
                        isRunning ? onStop() : onStart()
                    } label: {
                        Label(
                            isRunning
                                ? (
                                    processState.canRequestStop
                                        ? "Остановить"
                                        : "Закрыть вручную"
                                )
                                : "Запустить",
                            systemImage:
                                isRunning
                                    ? (
                                        processState.canRequestStop
                                            ? "stop.fill"
                                            : "hand.raised.fill"
                                    )
                                    : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        (!isRunning && isResolvingRuntime) ||
                            (isRunning && !processState.canRequestStop)
                    )
                    .help(
                        processState.guidance ??
                            (
                                !isRunning && isResolvingRuntime
                                    ? "NeAntik проверяет локальный браузер"
                                    : ""
                            )
                    )

                    Button(action: onEdit) {
                        Label("Изменить", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isRunning)
                    .help(
                        isRunning
                            ? "Сначала останови профиль"
                            : "Изменить профиль"
                    )
                    Button(action: onReveal) {
                        Label("Данные", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    Button(action: onFingerprintAudit) {
                        Label(
                            "Отпечаток",
                            systemImage: "waveform.path.ecg.rectangle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!canRunFingerprintAudit)
                    .help(
                        canRunFingerprintAudit
                            ? "Сравнить два профиля в проверке A → B → A"
                            : "Нужны два профиля и готовый совместимый движок"
                    )
                    if let proxy = profile.proxy, !proxy.username.isEmpty {
                        Button(action: onCopyProxyUsername) {
                            Label(
                                "Копировать логин",
                                systemImage: "person.text.rectangle"
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                        }
                        .help(
                            "Скопировать логин прокси на 60 секунд"
                        )
                        .accessibilityHint(
                            "Буфер обмена очистится через 60 секунд, если его содержимое не изменится."
                        )
                        Button(action: onCopyProxyPassword) {
                            Label(
                                "Копировать пароль",
                                systemImage: "key"
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                        }
                        .help(
                            "Скопировать пароль из Связки ключей на 60 секунд"
                        )
                        .accessibilityHint(
                            "Буфер обмена очистится через 60 секунд, если его содержимое не изменится."
                        )
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Удалить", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                if let clipboardNotice {
                    Label(
                        clipboardNotice,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(clipboardNotice)
                }

                GroupBox("Стартовая страница") {
                    LabeledContent("URL", value: profile.startURL)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                GroupBox("Отпечаток профиля") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent(
                            "Идентификатор",
                            value: profile.identity.displayCode
                        )
                        if let timezone = profile.identity.timezoneIdentifier {
                            LabeledContent("Часовой пояс", value: timezone)
                        }
                        if let locale = profile.identity.localeIdentifier {
                            LabeledContent("Язык", value: locale)
                        }
                        if let evidence =
                            profile.identity.proxyContextEvidence {
                            LabeledContent(
                                "Контекст сети",
                                value:
                                    "\(evidence.source) · \(evidence.observedAt.formatted(date: .abbreviated, time: .omitted))"
                            )
                            if !evidence.isFresh() {
                                Text(
                                    "Данные старше 30 дней. Перепроверь прокси перед важной сессией; при запуске NeAntik сам не обращается к сервису геолокации."
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        } else if profile.identity.timezoneIdentifier != nil ||
                                    profile.identity.localeIdentifier != nil {
                            Text(
                                "Часовой пояс сохранён старой версией без даты проверки. NeAntik не обновляет его через сеть автоматически."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Text(
                            runtimeSupportsFingerprint
                                ? "NeAntik передаёт этот стабильный идентификатор встроенному Chromium. Запусти проверку отпечатка, чтобы увидеть результат глазами сайта."
                                : "Идентификатор сохранён, но выбранный браузер изолирует только локальные данные. Выбери совместимый движок, чтобы применить отпечаток."
                        )
                        .font(.caption)
                        .foregroundStyle(
                            runtimeSupportsFingerprint
                                ? Color.secondary
                                : Color.orange
                        )
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Сеть") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let proxy = profile.proxy {
                            LabeledContent("Тип", value: proxy.kind.title)
                            LabeledContent("Сервер", value: "\(proxy.host):\(proxy.port)")
                            LabeledContent(
                                "Авторизация",
                                value: proxy.username.isEmpty ? "Нет" : proxy.username
                            )
                        } else {
                            LabeledContent("Подключение", value: "Без прокси")
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Локальные данные") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Папка браузера")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(browserDataPath)
                            .textSelection(.enabled)
                            .font(.callout.monospaced())
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 4)
                }

                if let lastLaunchedAt = profile.lastLaunchedAt {
                    Text("Последний запуск: \(lastLaunchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(28)
        }
    }

    private var profileIcon: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(hex: profile.colorHex).gradient)
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: "globe")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
            }
    }

    private var profileTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name)
                .font(.largeTitle)
                .fontWeight(.semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Label(
                processState.title,
                systemImage: isRunning ? "circle.fill" : "circle"
            )
            .font(.subheadline)
            .foregroundStyle(
                processState == .externalUnverified
                    ? Color.orange
                    : (isRunning ? Color.green : Color.secondary)
            )
            if let guidance = processState.guidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(
                        processState == .externalUnverified
                            ? Color.orange
                            : Color.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
