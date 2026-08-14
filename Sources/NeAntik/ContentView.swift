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
    @ObservedObject var telemetry: TelemetryController

    let keychain: KeychainStore
    let credentialCleanup: DeletedProfileCredentialCleanup
    let runtimeLocator: BrowserRuntimeLocator
    let launchIntent: NeAntikLaunchIntent
    let fingerprintEvidenceReleaseContext:
        FingerprintEvidenceReleaseContext?
    private let updateChannel = UpdateChannelConfiguration.fromBundle()

    @State private var selection: UUID?
    @State private var editorRequest: EditorRequest?
    @State private var showingDeleteConfirmation = false
    @State private var showingReleaseFingerprintAudit = false
    @State private var showingBulkProxyImport = false
    @State private var localError: String?
    @State private var resolvedRuntime: BrowserRuntime?
    @State private var isResolvingRuntime = true
    @State private var clipboardLease = ClipboardLeaseState()
    @State private var clipboardNotice: ClipboardNotice?
    @State private var clipboardClearTask: Task<Void, Never>?
    @State private var clipboardNoticeTask: Task<Void, Never>?
    @State private var handledReleaseAuditIntent = false
    @State private var releaseAuditTerminationScheduled = false
    @State private var releaseAuditProfiles: [BrowserProfile] = []
    @State private var profileSearchText = ""
    @State private var selectedProfileTag: String?
    @State private var profileListScope: ProfileListScope = .active
    @State private var isSidebarVisible = true

    private var selectedProfile: BrowserProfile? {
        store.profile(withID: selection)
    }

    private var visibleProfiles: [BrowserProfile] {
        ProfileListProjection.filtered(
            store.profiles,
            searchText: profileSearchText,
            tag: selectedProfileTag,
            scope: profileListScope
        )
    }

    private var availableProfileTags: [String] {
        ProfileListProjection.allTags(
            in: store.profiles.filter {
                $0.isArchived == (profileListScope == .archived)
            }
        )
    }

    private var hasArchivedProfiles: Bool {
        store.profiles.contains(where: \.isArchived)
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
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if isSidebarVisible {
                    sidebar
                        .frame(
                            width: WorkspaceLayout.sidebarWidth(
                                for: proxy.size.width
                            )
                        )
                    Divider()
                }

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(Color(hex: "#FF3B4D"))
        .frame(
            minWidth: WorkspaceLayout.minimumWindowWidth,
            minHeight: WorkspaceLayout.minimumWindowHeight
        )
        .animation(
            .easeInOut(duration: 0.16),
            value: isSidebarVisible
        )
        .sheet(item: $editorRequest) { request in
            ProfileEditorView(
                original: request.profile,
                keychain: keychain
            ) { profile, passwordUpdate in
                let saved: BrowserProfile
                switch passwordUpdate {
                case .delete:
                    saved = try store.upsert(profile)
                    try keychain.deleteProxyPassword(
                        profileID: saved.id
                    )
                case .keepExisting:
                    saved = try store.upsert(profile)
                case let .replace(password):
                    saved = try store.upsert(profile) { saved in
                        try keychain.saveProxyPassword(
                            password,
                            profileID: saved.id
                        )
                    }
                }
                normalizeSelection(preferred: saved.id)
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
        .sheet(isPresented: $showingBulkProxyImport) {
            BulkProxyImportView { drafts, baseName in
                try createProfiles(
                    from: drafts,
                    baseName: baseName
                )
            }
        }
        .sheet(isPresented: $showingReleaseFingerprintAudit) {
            if let runtime,
               let fingerprintEvidenceReleaseContext,
               releaseAuditProfiles.count >= 2
            {
                FingerprintAuditView(
                    profiles: releaseAuditProfiles,
                    initialFirstID: releaseAuditProfiles.first?.id,
                    runtime: runtime,
                    processes: processes,
                    paths: store.paths,
                    releaseContext: fingerprintEvidenceReleaseContext
                )
            } else {
                ContentUnavailableView(
                    "Служебная проверка выпуска недоступна",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "Встроенный браузер не готов к автоматической проверке выпуска."
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
                    try store.delete(
                        profile,
                        processManager: processes
                    ) { deletedProfile in
                        try keychain.deleteProxyPassword(
                            profileID: deletedProfile.id
                        )
                    }
                    normalizeSelection()
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
                    fingerprintEvidenceReleaseContext == nil &&
                        (
                            localError != nil ||
                                processes.lastError != nil ||
                                store.lastError != nil
                        )
                },
                set: { presented in
                    if !presented {
                        localError = nil
                        processes.lastError = nil
                        store.lastError = nil
                    }
                }
            )
        ) {
            Button("OK") {
                localError = nil
                processes.lastError = nil
                store.lastError = nil
            }
        } message: {
            Text(
                localError ??
                    processes.lastError ??
                    store.lastError ??
                    "Неизвестная ошибка"
            )
        }
        .onAppear {
            normalizeSelection(preferred: selection)
            processes.reconcile(profiles: store.profiles)
            telemetry.record(.snapshot, snapshot: telemetrySnapshot)
            presentReleaseFingerprintAuditIfNeeded()
        }
        .onChange(of: profileSearchText) { _, _ in
            normalizeSelection(preferred: selection)
        }
        .onChange(of: selectedProfileTag) { _, _ in
            normalizeSelection(preferred: selection)
        }
        .onChange(of: profileListScope) { _, _ in
            selectedProfileTag = nil
            normalizeSelection(preferred: selection)
        }
        .onChange(of: visibleProfiles.map(\.id)) { _, _ in
            normalizeSelection(preferred: selection)
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
                for: NSApplication.willResignActiveNotification
            )
        ) { _ in
            processes.suspendPassiveObservations()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            processes.reconcile(profiles: store.profiles)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didWakeNotification
            )
        ) { _ in
            if NSApplication.shared.isActive {
                processes.reconcile(profiles: store.profiles)
            } else {
                processes.suspendPassiveObservations()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            cancelClipboardTasks()
            clearClipboardIfLeaseIsActive()
        }
        .task {
            await resolveRuntime()
        }
        .task {
            await recoverDeletedProfileCredentials()
        }
    }

    private func recoverDeletedProfileCredentials() async {
        let summary = await credentialCleanup.runOnce(
            metadataIsTrusted: store.hasTrustedMetadata,
            excluding: Set(store.profiles.map(\.id))
        )
        guard !Task.isCancelled,
              summary.failedCount > 0 || summary.inspectionFailed
        else {
            return
        }
        if localError == nil {
            localError =
                "Не удалось завершить очистку некоторых ранее удалённых паролей прокси. NeAntik безопасно повторит попытку при следующем запуске."
        }
    }

    private func normalizeSelection(preferred: UUID? = nil) {
        selection = ProfileListProjection.normalizedSelection(
            preferred ?? selection,
            in: visibleProfiles
        )
    }

    private func togglePinned(_ profile: BrowserProfile) {
        do {
            var updated = profile
            updated.isPinned.toggle()
            let saved = try store.upsert(updated)
            normalizeSelection(preferred: saved.id)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func toggleArchived(_ profile: BrowserProfile) {
        guard !processes.runningProfileIDs.contains(profile.id) else {
            localError = "Сначала останови профиль, потом перемещай его в архив."
            return
        }
        do {
            var updated = profile
            updated.isArchived.toggle()
            let saved = try store.upsert(updated)
            if !saved.isArchived {
                profileListScope = .active
                normalizeSelection(preferred: saved.id)
            } else {
                normalizeSelection()
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func duplicate(_ profile: BrowserProfile) {
        do {
            let copy = profile.duplicated()
            let password = try keychain.proxyPassword(
                profileID: profile.id
            )
            let saved = try store.upsert(copy) { saved in
                if let password, !password.isEmpty {
                    try keychain.saveProxyPassword(
                        password,
                        profileID: saved.id
                    )
                }
            }
            profileListScope = .active
            normalizeSelection(preferred: saved.id)
            telemetry.record(
                .profileCreated,
                snapshot: telemetrySnapshot
            )
            if saved.proxy != nil {
                telemetry.record(
                    .proxyEnabled,
                    snapshot: telemetrySnapshot
                )
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func createProfiles(
        from drafts: [ProxyImportDraft],
        baseName: String
    ) throws {
        let created = try BulkProfileImporter.create(
            drafts: drafts,
            baseName: baseName,
            store: store,
            keychain: keychain
        )

        profileListScope = .active
        profileSearchText = ""
        selectedProfileTag = nil
        normalizeSelection(preferred: created.last?.id)
        for profile in created {
            telemetry.record(
                .profileCreated,
                snapshot: telemetrySnapshot
            )
            if profile.proxy != nil {
                telemetry.record(
                    .proxyEnabled,
                    snapshot: telemetrySnapshot
                )
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            if hasArchivedProfiles ||
                !availableProfileTags.isEmpty ||
                selectedProfile != nil
            {
                sidebarControls
                Divider()
            }

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleProfiles.isEmpty {
                ContentUnavailableView {
                    Label(
                        profileSearchText.isEmpty && selectedProfileTag == nil
                            ? (
                                profileListScope == .archived
                                    ? "Архив пуст"
                                    : "Нет активных профилей"
                            )
                            : "Ничего не найдено",
                        systemImage:
                            profileListScope == .archived
                                ? "archivebox"
                                : "magnifyingglass"
                    )
                } description: {
                    Text(
                        profileSearchText.isEmpty && selectedProfileTag == nil
                            ? "Профили можно вернуть из архива в любой момент."
                            : "Измени поиск или выбери другой тег."
                    )
                } actions: {
                    if !profileSearchText.isEmpty || selectedProfileTag != nil {
                        Button("Сбросить фильтры") {
                            profileSearchText = ""
                            selectedProfileTag = nil
                        }
                    } else if hasArchivedProfiles {
                        Button(
                            profileListScope == .archived
                                ? "Показать профили"
                                : "Показать архив"
                        ) {
                            profileListScope =
                                profileListScope == .archived
                                    ? .active
                                    : .archived
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(visibleProfiles) { profile in
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
                                togglePinned(profile)
                            } label: {
                                Label(
                                    profile.isPinned
                                        ? "Открепить"
                                        : "Закрепить",
                                    systemImage:
                                        profile.isPinned
                                            ? "pin.slash"
                                            : "pin"
                                )
                            }

                            Button {
                                duplicate(profile)
                            } label: {
                                Label("Дублировать", systemImage: "plus.square.on.square")
                            }

                            Button {
                                toggleArchived(profile)
                            } label: {
                                Label(
                                    profile.isArchived
                                        ? "Вернуть из архива"
                                        : "В архив",
                                    systemImage:
                                        profile.isArchived
                                            ? "arrow.uturn.backward"
                                            : "archivebox"
                                )
                            }
                            .disabled(processState.isRunning)

                            Divider()

                            Button {
                                editorRequest = EditorRequest(profile: profile)
                            } label: {
                                Label("Изменить", systemImage: "slider.horizontal.3")
                            }
                            .disabled(processState.isRunning)
                            if processState == .checking {
                                Button {} label: {
                                    Label(
                                        "Подготовка…",
                                        systemImage: "hourglass"
                                    )
                                }
                                .disabled(true)
                            } else if processState.isRunning &&
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
            sidebarStatus
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Профили")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    isSidebarVisible = false
                } label: {
                    sidebarHeaderActionIcon("sidebar.left")
                }
                .buttonStyle(.plain)
                .background(.quaternary, in: Circle())
                .help("Скрыть список профилей")
                .accessibilityLabel("Скрыть список профилей")

                Menu {
                    Button {
                        editorRequest = EditorRequest(profile: nil)
                    } label: {
                        Label("Новый профиль", systemImage: "plus")
                    }
                    Button {
                        showingBulkProxyImport = true
                    } label: {
                        Label(
                            "Профили из списка прокси",
                            systemImage: "list.bullet.clipboard"
                        )
                    }
                } label: {
                    sidebarHeaderActionIcon("plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 32, height: 32)
                .background(.quaternary, in: Circle())
                .help("Создать профили")
                .accessibilityLabel("Создать профили")
            }

            TextField(
                "Поиск по имени и тегам",
                text: $profileSearchText
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Поиск профилей")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func sidebarHeaderActionIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 32)
            .contentShape(Circle())
    }

    private var sidebarControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasArchivedProfiles {
                Picker("Раздел", selection: $profileListScope) {
                    ForEach(ProfileListScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Раздел профилей")
            }

            if !availableProfileTags.isEmpty {
                Picker("Тег", selection: $selectedProfileTag) {
                    Text("Все теги").tag(nil as String?)
                    ForEach(availableProfileTags, id: \.self) { tag in
                        Text(tag).tag(Optional(tag))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Фильтр профилей по тегу")
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
                                processState == .checking
                                    ? "Подготовка…"
                                    : processState.canRequestStop
                                    ? "Остановить выбранный"
                                    : "Закрой браузер вручную"
                            )
                            : "Запустить выбранный",
                        systemImage:
                            processState.isRunning
                                ? (
                                    processState == .checking
                                        ? "hourglass"
                                        : processState.canRequestStop
                                        ? "stop.fill"
                                        : "hand.raised.fill"
                                )
                                : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    profile.isArchived ||
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            ProfileDetailView(
                profile: profile,
                processState: processes.processState(for: profile.id),
                isResolvingRuntime: isResolvingRuntime,
                browserDataPath: store.paths.browserDataDirectory(for: profile.id).path,
                clipboardNotice:
                    clipboardNotice?.profileID == profile.id
                        ? clipboardNotice?.message
                        : nil,
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: {
                    isSidebarVisible.toggle()
                },
                onCreate: {
                    editorRequest = EditorRequest(profile: nil)
                },
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
                onDuplicate: {
                    duplicate(profile)
                },
                onTogglePinned: {
                    togglePinned(profile)
                },
                onToggleArchived: {
                    toggleArchived(profile)
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
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    isSidebarVisible.toggle()
                } label: {
                    Image(
                        systemName:
                            isSidebarVisible
                            ? "sidebar.left"
                            : "sidebar.right"
                    )
                }
                .buttonStyle(.bordered)
                .help(
                    isSidebarVisible
                        ? "Скрыть список профилей"
                        : "Показать список профилей"
                )
                .accessibilityLabel(
                    isSidebarVisible
                        ? "Скрыть список профилей"
                        : "Показать список профилей"
                )

                Text("NeAntik")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if !isSidebarVisible {
                    Button {
                        editorRequest = EditorRequest(profile: nil)
                    } label: {
                        Label("Новый профиль", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ContentUnavailableView {
                Label(
                    store.profiles.isEmpty
                        ? "Создай первый профиль"
                        : "Выбери профиль",
                    systemImage: "rectangle.stack.person.crop"
                )
            } description: {
                Text(
                    "Каждый профиль хранит свои cookies, настройки сети и локальные данные."
                )
            } actions: {
                if store.profiles.isEmpty {
                    Button("Создать профиль") {
                        editorRequest = EditorRequest(profile: nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sidebarStatus: some View {
        if isResolvingRuntime || runtimePreflight?.isReady == false ||
            updateChannel.isEnabled || telemetry.isConfigured
        {
            VStack(alignment: .leading, spacing: 7) {
                Label {
                    Text(
                        isResolvingRuntime
                            ? "Подготавливаем браузер…"
                            : runtimePreflight?.isReady == true
                            ? "Браузер готов"
                            : "Браузер требует внимания"
                    )
                    .fontWeight(.medium)
                } icon: {
                    Image(systemName: runtimeStatusIcon)
                        .foregroundStyle(runtimeStatusColor)
                }

                if isResolvingRuntime || runtimePreflight?.isReady == false {
                    Text(
                        isResolvingRuntime
                            ? "Встроенный браузер"
                            : runtimePreflight?.primaryMessage ??
                                "Встроенный браузер недоступен"
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }

                if updateChannel.isEnabled {
                    Label(
                        "Подписанные обновления",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .foregroundStyle(.secondary)
                }

                if telemetry.isConfigured {
                    Toggle(
                        "Обезличенная статистика",
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
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .font(.caption)
            .padding(12)
            .accessibilityElement(children: .contain)
        }
    }

    private var runtimeStatusIcon: String {
        guard let runtime else { return "exclamationmark.triangle.fill" }
        return runtime.supportsFingerprintIdentity
            ? "shield.lefthalf.filled"
            : "externaldrive.fill"
    }

    private var runtimeStatusColor: Color {
        guard let runtime else { return .orange }
        if runtimePreflight?.isReady == false {
            return .red
        }
        return runtime.supportsFingerprintIdentity ? .orange : .secondary
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

    private func resolveRuntime() async {
        isResolvingRuntime = true
        let locator = runtimeLocator
        let value = await Task.detached(priority: .userInitiated) {
            locator.preferredRuntime()
        }.value
        guard !Task.isCancelled else {
            return
        }
        resolvedRuntime = value
        isResolvingRuntime = false
        presentReleaseFingerprintAuditIfNeeded()
    }

    private func presentReleaseFingerprintAuditIfNeeded() {
        guard launchIntent.opensFingerprintAudit,
              !handledReleaseAuditIntent,
              !isResolvingRuntime
        else {
            return
        }
        handledReleaseAuditIntent = true

        guard runtime?.supportsFingerprintIdentity == true,
              runtimePreflight?.isReady == true
        else {
            failFingerprintReleaseBeforePresentation(
                runtimePreflight?.primaryMessage ??
                    "Встроенный браузер не готов к проверке отпечатка."
            )
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        if releaseAuditProfiles.count < 2 {
            releaseAuditProfiles = Self.makeReleaseAuditProfiles()
        }
        selection = releaseAuditProfiles.first?.id
        showingReleaseFingerprintAudit = true
    }

    private func failFingerprintReleaseBeforePresentation(
        _ message: String
    ) {
        guard fingerprintEvidenceReleaseContext != nil else {
            localError = message
            return
        }
        guard !releaseAuditTerminationScheduled else {
            return
        }
        releaseAuditTerminationScheduled = true
        let line = FingerprintAuditAutomationPolicy.sanitizedLogLine(
            prefix: "Автоматическая проверка отпечатка не запущена: ",
            message: message
        )
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
        Task { @MainActor in
            await Task.yield()
            NSApplication.shared.terminate(nil)
        }
    }

    private static func makeReleaseAuditProfiles() -> [BrowserProfile] {
        [
            BrowserProfile(
                id: UUID(
                    uuidString:
                        "E4D67C71-6F7F-4B63-8F64-82B4F5734B01"
                )!,
                name: "Проверка A",
                colorHex: "#5E7CE2",
                startURL: "http://neantik.local",
                identity: BrowserIdentity()
            ),
            BrowserProfile(
                id: UUID(
                    uuidString:
                        "F43E42A6-97F4-4B70-A191-70501BC95D02"
                )!,
                name: "Проверка B",
                colorHex: "#30D158",
                startURL: "http://neantik.local",
                identity: BrowserIdentity()
            )
        ]
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
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: profile.colorHex))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: profile.displaySymbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            ProfileAppearance.usesDarkForeground(
                                for: profile.colorHex
                            )
                                ? Color.black
                                : Color.white
                        )
                    if processState.isRunning {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                processState == .externalUnverified
                                    || processState == .checking
                                    ? Color.orange
                                    : Color.green,
                                lineWidth: 2
                            )
                            .padding(-2)
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(profile.name)
                        .lineLimit(1)
                    if profile.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Закреплён")
                    }
                }
                HStack(spacing: 5) {
                    Text(
                        profile.isArchived
                            ? "В архиве"
                            : profile.proxy?.displayName ?? "Без прокси"
                    )
                        .lineLimit(1)
                    if let tag = profile.tags.first {
                        Text(tag)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                    if profile.tags.count > 1 {
                        Text("+\(profile.tags.count - 1)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(processState.title)
    }
}

struct ProfileDetailView: View {
    @State private var technicalDetailsExpanded = false

    let profile: BrowserProfile
    let processState: BrowserProfileProcessState
    let isResolvingRuntime: Bool
    let browserDataPath: String
    let clipboardNotice: String?
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void
    let onCreate: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onTogglePinned: () -> Void
    let onToggleArchived: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void
    let onCopyProxyUsername: () -> Void
    let onCopyProxyPassword: () -> Void

    private var actionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 148), spacing: 10, alignment: .leading)]
    }

    private var isRunning: Bool {
        processState.isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            pinnedHeader
            Divider()

            ScrollView {
                detailContent
                    .frame(maxWidth: 1_160, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var pinnedHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onToggleSidebar) {
                Image(
                    systemName:
                        isSidebarVisible
                        ? "sidebar.left"
                        : "sidebar.right"
                )
            }
            .buttonStyle(.bordered)
            .help(
                isSidebarVisible
                    ? "Скрыть список профилей"
                    : "Показать список профилей"
            )
            .accessibilityLabel(
                isSidebarVisible
                    ? "Скрыть список профилей"
                    : "Показать список профилей"
            )

            if !isSidebarVisible {
                Button(action: onCreate) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Создать профиль")
                .accessibilityLabel("Создать профиль")
            }

            profileIcon
            profileTitle

            Spacer(minLength: 12)

            primaryActions
                .frame(maxWidth: 820, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 22) {
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

            GroupBox("Профиль") {
                Label(
                    "Cookies, настройки и данные сайтов хранятся отдельно",
                    systemImage: "person.crop.rectangle.stack"
                )
                .padding(.vertical, 4)
            }

            GroupBox("Сеть") {
                networkSummary
                    .padding(.vertical, 4)
            }

            DisclosureGroup(
                "Технические сведения",
                isExpanded: $technicalDetailsExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Папка данных браузера")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(browserDataPath)
                        .textSelection(.enabled)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.top, 10)
            }
            .accessibilityHint(
                "Показывает локальный путь данных профиля"
            )

            if let lastLaunchedAt = profile.lastLaunchedAt {
                Text(
                    "Последний запуск: \(lastLaunchedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var networkSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let proxy = profile.proxy {
                LabeledContent("Тип", value: proxy.kind.title)
                LabeledContent("Сервер", value: proxy.displayEndpoint)
                LabeledContent(
                    "Авторизация",
                    value: proxy.username.isEmpty ? "Нет" : proxy.username
                )
                if !proxy.username.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            credentialButtons
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            credentialButtons
                        }
                    }
                }
            } else {
                LabeledContent("Подключение", value: "Без прокси")
            }
        }
    }

    private var primaryActions: some View {
        LazyVGrid(
            columns: actionColumns,
            alignment: .leading,
            spacing: 10
        ) {
            Button {
                isRunning ? onStop() : onStart()
            } label: {
                compactActionLabel(
                    profile.isArchived
                        ? "В архиве"
                        : isRunning
                        ? (
                            processState == .checking
                                ? "Подготовка…"
                                : processState.canRequestStop
                                ? "Остановить"
                                : "Закрыть вручную"
                        )
                        : "Запустить",
                    systemImage:
                        profile.isArchived
                            ? "archivebox"
                            : isRunning
                            ? (
                                processState == .checking
                                    ? "hourglass"
                                    : processState.canRequestStop
                                    ? "stop.fill"
                                    : "hand.raised.fill"
                            )
                            : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                profile.isArchived ||
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
            .accessibilityHint(processState.guidance ?? "")

            Button(action: onEdit) {
                compactActionLabel(
                    "Изменить",
                    systemImage: "slider.horizontal.3"
                )
            }
            .disabled(isRunning)
            .help(
                isRunning
                    ? "Сначала останови профиль"
                    : "Изменить профиль"
            )

            Menu {
                Button(action: onTogglePinned) {
                    Label(
                        profile.isPinned ? "Открепить" : "Закрепить",
                        systemImage: profile.isPinned ? "pin.slash" : "pin"
                    )
                }
                Button(action: onDuplicate) {
                    Label("Дублировать", systemImage: "plus.square.on.square")
                }
                Button(action: onToggleArchived) {
                    Label(
                        profile.isArchived
                            ? "Вернуть из архива"
                            : "В архив",
                        systemImage:
                            profile.isArchived
                                ? "arrow.uturn.backward"
                                : "archivebox"
                    )
                }
                .disabled(isRunning)
                Divider()
                Button(action: onReveal) {
                    Label("Показать данные", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Удалить профиль", systemImage: "trash")
                }
                .disabled(isRunning)
            } label: {
                compactActionLabel("Ещё", systemImage: "ellipsis.circle")
            }
            .help(
                isRunning
                    ? "Данные доступны; удаление — после остановки профиля"
                    : "Данные и удаление профиля"
            )
        }
        .buttonStyle(.bordered)
    }

    private func compactActionLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var credentialButtons: some View {
        Button(action: onCopyProxyUsername) {
            Label(
                "Копировать логин",
                systemImage: "person.text.rectangle"
            )
        }
        .help("Скопировать логин прокси на 60 секунд")
        .accessibilityHint(
            "Буфер обмена очистится через 60 секунд, если его содержимое не изменится."
        )

        Button(action: onCopyProxyPassword) {
            Label("Копировать пароль", systemImage: "key")
        }
        .help("Скопировать пароль из Связки ключей на 60 секунд")
        .accessibilityHint(
            "Буфер обмена очистится через 60 секунд, если его содержимое не изменится."
        )
    }

    private var profileIcon: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(hex: profile.colorHex).gradient)
            .frame(width: 52, height: 52)
            .overlay {
                Image(systemName: profile.displaySymbolName)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(
                        ProfileAppearance.usesDarkForeground(
                            for: profile.colorHex
                        )
                            ? Color.black
                            : Color.white
                    )
            }
            .accessibilityLabel(
                "Иконка профиля: \(ProfileAppearance.title(for: profile.displaySymbolName))"
            )
    }

    private var profileTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name)
                .font(.title2)
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
            if !profile.tags.isEmpty {
                Text(profile.tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if profile.isArchived {
                Label("В архиве", systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
