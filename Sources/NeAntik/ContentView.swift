import AppKit
import SwiftUI

enum ProfileSearchSyntaxHelp {
    static let examples = [
        "тег:tiktok",
        "папка:\"Paid Social\"",
        "прокси:есть",
        "статус:закреплен",
    ]
}

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings

    @ObservedObject var store: ProfileStore
    @ObservedObject var processes: BrowserProcessManager
    @ObservedObject var fingerprintObservationStore:
        FingerprintObservationStore
    @ObservedObject var proxyHealthCoordinator:
        ProxyHealthCoordinator
    @ObservedObject var workspacePreferences:
        WorkspacePreferenceStore

    let keychain: KeychainStore
    let credentialCleanup: DeletedProfileCredentialCleanup
    let runtimeLocator: BrowserRuntimeLocator
    let launchIntent: NeAntikLaunchIntent
    let fingerprintEvidenceReleaseContext:
        FingerprintEvidenceReleaseContext?

    @State private var selection: UUID?
    @State private var batchSelectedProfileIDs = Set<UUID>()
    @State private var workspaceBatchUndo: WorkspaceBatchUndo?
    @State private var profileBatchTagRequest: ProfileBatchTagRequest?
    @State private var editorRequest: EditorRequest?
    @State private var profileNoteRequest: ProfileNoteRequest?
    @State private var showingDeleteConfirmation = false
    @State private var showingReleaseFingerprintAudit = false
    @State private var fingerprintAuditRequest: FingerprintAuditRequest?
    @State private var bulkProxyImportRequest: BulkProxyImportRequest?
    @State private var localError: String?
    @State private var launchPreparationFailure: LaunchPreparationFailure?
    @State private var forceStopRequest: BrowserProfile?
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
    @State private var showsProfileSearchHelp = false
    @State private var selectedProfileTag: ProfileTagID?
    @State private var profileListScope: ProfileListScope = .active
    @State private var selectedFolderFilter: ProfileFolderFilter = .all
    @State private var profileRouteFilter: ProfileRouteFilter = .all
    @State private var profileListOrdering: ProfileListOrdering =
        .pinnedThenName
    @State private var profileOperationalFilter: ProfileOperationalFilter =
        .all
    @State private var folderNameRequest: FolderNameRequest?
    @State private var profileFolderPickerRequest:
        ProfileFolderPickerRequest?
    @State private var folderPendingDelete: ProfileFolder?
    @State private var proxyTestOperations = ProxyTestOperationRegistry()
    @State private var proxyTestingProfileIDs = Set<UUID>()
    @State private var proxyTestTasks: [UUID: Task<Void, Never>] = [:]
    @State private var launchPreparingProfileIDs = Set<UUID>()
    @State private var launchPreparationTasks:
        [UUID: Task<Void, Never>] = [:]
    @State private var launchPreparationTokens: [UUID: UUID] = [:]
    @State private var bulkProxyTestTask: Task<Void, Never>?
    @State private var bulkProxyTestID: UUID?
    @State private var bulkProxyProgress: BulkProxyRunProgress?
    @State private var bulkProxyStatusMessage: String?
    @State private var bulkProxyFailedProfileIDs: [UUID] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsProfileInspector = false
    @State private var showingWorkspaceReadiness = false
    @State private var isRefreshingWorkspaceReadiness = false
    @State private var workspaceReadinessNotice: UserNotice?
    @State private var readinessSystemInspection:
        WorkspaceReadinessSystemInspection
    @State private var preferredProfileSelection: UUID?
    @FocusState private var profileSearchIsFocused: Bool
    @FocusState private var focusedWorkspaceSource: WorkspaceSourceFocus?
    @State private var foldersSourceExpanded = true
    @State private var tagsSourceExpanded = true
    @State private var showsAllFolders = false
    @State private var showsAllTags = false
    @State private var isCreatingProfileQuickly = false
    @State private var profileListResolver = ProfileListStateResolver()
    @State private var workspaceAnnouncementGate =
        AccessibilityAnnouncementGate<String>()

    init(
        store: ProfileStore,
        processes: BrowserProcessManager,
        fingerprintObservationStore: FingerprintObservationStore,
        proxyHealthCoordinator: ProxyHealthCoordinator,
        workspacePreferences: WorkspacePreferenceStore,
        keychain: KeychainStore,
        credentialCleanup: DeletedProfileCredentialCleanup,
        runtimeLocator: BrowserRuntimeLocator,
        launchIntent: NeAntikLaunchIntent,
        fingerprintEvidenceReleaseContext: FingerprintEvidenceReleaseContext?,
        initialRuntime: BrowserRuntime? = nil,
        initialOperationalFilter: ProfileOperationalFilter = .all
    ) {
        self.store = store
        self.processes = processes
        self.fingerprintObservationStore = fingerprintObservationStore
        self.proxyHealthCoordinator = proxyHealthCoordinator
        self.workspacePreferences = workspacePreferences
        self.keychain = keychain
        self.credentialCleanup = credentialCleanup
        self.runtimeLocator = runtimeLocator
        self.launchIntent = launchIntent
        self.fingerprintEvidenceReleaseContext =
            fingerprintEvidenceReleaseContext
        _resolvedRuntime = State(initialValue: initialRuntime)
        _isResolvingRuntime = State(initialValue: initialRuntime == nil)
        _profileOperationalFilter = State(
            initialValue: initialOperationalFilter
        )
        _readinessSystemInspection = State(
            initialValue: WorkspaceReadinessSystemInspection.checking(
                application: WorkspaceApplicationIdentity.current()
            )
        )
    }

    private var selectedProfile: BrowserProfile? {
        store.profile(withID: selection)
    }

    private var selectedProfileCommandSet: ProfileCommandSet {
        guard !isWorkspaceModalPresented,
              let selectedProfile
        else {
            return .unavailable
        }
        return profileCommandSet(for: selectedProfile)
    }

    private var isWorkspaceModalPresented: Bool {
        editorRequest != nil ||
            profileNoteRequest != nil ||
            folderNameRequest != nil ||
            profileFolderPickerRequest != nil ||
            profileBatchTagRequest != nil ||
            bulkProxyImportRequest != nil ||
            forceStopRequest != nil ||
            showingReleaseFingerprintAudit ||
            fingerprintAuditRequest != nil ||
            showingWorkspaceReadiness ||
            showingDeleteConfirmation ||
            folderPendingDelete != nil ||
            launchPreparationFailure != nil ||
            workspaceAlert != nil
    }

    private var workspaceCommandSet: WorkspaceCommandSet {
        guard !isWorkspaceModalPresented else { return .unavailable }
        return WorkspaceCommandSet(
            isEnabled: true,
            selectedFolderName: selectedFolder?.name,
            canToggleInspector: selectedProfile != nil,
            showsInspector: showsProfileInspector,
            createProfile: beginCreatingProfile,
            createFolder: beginCreatingFolder,
            focusProfileSearch: { profileSearchIsFocused = true },
            showShortcutReference: { openSettings() },
            toggleInspector: toggleProfileInspector,
            renameSelectedFolder: {
                guard let selectedFolder else { return }
                folderNameRequest = FolderNameRequest(
                    folder: selectedFolder
                )
            },
            deleteSelectedFolder: {
                guard let selectedFolder else { return }
                folderPendingDelete = selectedFolder
            }
        )
    }

    private func presentedProcessState(
        for profile: BrowserProfile
    ) -> BrowserProfileProcessState {
        let state = processes.processState(for: profile.id)
        guard state == .stopped,
              launchPreparingProfileIDs.contains(profile.id)
        else {
            return state
        }
        return .checking
    }

    private func isProxyTestInFlight(profileID: UUID) -> Bool {
        proxyTestingProfileIDs.contains(profileID) ||
            proxyHealthCoordinator.isTesting(profileID: profileID)
    }

    private var visibleProfiles: [BrowserProfile] {
        currentOperationalProjection.profiles(
            for: profileOperationalFilter
        )
    }

    private var currentOperationalProjection: ProfileOperationalProjection {
        ProfileOperationalProjection.resolve(
            profiles: currentProfileListViewState.visibleProfiles,
            processState: { processes.processState(for: $0) },
            proxyHealth: { proxyHealthCoordinator.state(for: $0) }
        )
    }

    private var selectedProfileTagName: String? {
        currentProfileListViewState.selectedTagDisplayName
    }

    private var currentProfileListIndex: ProfileListIndex {
        profileListResolver.resolveIndex(
            revision: store.profileListRevision,
            profiles: store.profiles,
            organization: store.organization
        )
    }

    private var currentProfileListViewState: ProfileListViewState {
        profileListResolver.resolve(
            revision: store.profileListRevision,
            profiles: store.profiles,
            organization: store.organization,
            query: workspaceQuery,
            searchText: profileSearchText,
            routeFilter: profileRouteFilter,
            ordering: profileListOrdering
        )
    }

    private var workspaceQuery: WorkspaceQueryState {
        WorkspaceQueryState(
            scope: profileListScope,
            folderFilter: selectedFolderFilter,
            tag: selectedProfileTag
        )
    }

    private var selectedFolderID: UUID? {
        guard case let .folder(id) = selectedFolderFilter else {
            return nil
        }
        return id
    }

    private var selectedFolder: ProfileFolder? {
        store.folder(withID: selectedFolderID)
    }

    private var bulkProxyActionProjection: BulkProxyActionProjection {
        BulkProxyActionProjection.resolve(
            visibleProfiles: visibleProfiles,
            processState: { processes.processState(for: $0) },
            isPreparing: { launchPreparingProfileIDs.contains($0) },
            isTesting: { isProxyTestInFlight(profileID: $0) }
        )
    }

    private var fingerprintAuditProfiles: [BrowserProfile] {
        store.profiles.filter { !$0.isArchived }
    }

    private var runtime: BrowserRuntime? {
        resolvedRuntime
    }

    private var runtimePreflight: BrowserRuntimePreflight? {
        runtime.map(BrowserRuntimePreflightValidator.validate)
    }

    private var runtimeAvailability: BrowserRuntimeAvailability {
        if isResolvingRuntime { return .resolving }
        guard runtime != nil else { return .missing }
        guard let runtimePreflight else {
            return .invalid(
                message: "Не удалось проверить браузерный движок."
            )
        }
        return runtimePreflight.isReady
            ? .ready
            : .invalid(
                message: runtimePreflight.primaryMessage ??
                    "Не удалось проверить браузерный движок."
            )
    }

    private var selectedEnvironmentSnapshot: ProfileEnvironmentSnapshot? {
        guard let selectedProfile else { return nil }
        return WorkspaceDomain.environmentSnapshot(
            profile: selectedProfile,
            runtime: runtime,
            proxyHealth: proxyHealthCoordinator.state(
                for: selectedProfile
            ),
            fingerprintObservation:
                fingerprintObservationStore.observation(
                    for: selectedProfile.id
                )
        )
    }

    private var workspaceReadinessSnapshot: WorkspaceReadinessSnapshot {
        var runningCount = 0
        var processAttentionCount = 0
        var directRouteCount = 0
        var proxiedRouteCount = 0
        var proxyAttentionCount = 0
        let activeProfiles = store.profiles.filter { !$0.isArchived }
        for profile in activeProfiles {
            let state = presentedProcessState(for: profile)
            if state.isConfirmedRunning {
                runningCount += 1
            }
            if state.statusTone == .attention {
                processAttentionCount += 1
            }
            if profile.proxy == nil {
                directRouteCount += 1
            } else {
                proxiedRouteCount += 1
                if let health = proxyHealthCoordinator.state(for: profile),
                   !health.hasCompleteRouteContext
                {
                    proxyAttentionCount += 1
                }
            }
        }
        return WorkspaceReadinessSnapshot.resolve(
            WorkspaceReadinessInput(
                system: readinessSystemInspection,
                runtimeAvailability: runtimeAvailability,
                runtimeVersion: runtime?.inspection.version,
                runtimeArchitectures: runtime?.inspection.architectures ?? [],
                profileCount: activeProfiles.count,
                runningCount: runningCount,
                processAttentionCount: processAttentionCount,
                directRouteCount: directRouteCount,
                proxiedRouteCount: proxiedRouteCount,
                proxyAttentionCount: proxyAttentionCount,
                recoveredInterruptedManagerSession:
                    processes.recoveredInterruptedManagerSession
            )
        )
    }

    private var workspaceAlert: WorkspaceAlertPresentation? {
        guard fingerprintEvidenceReleaseContext == nil else { return nil }
        if let localError {
            return WorkspaceAlertPresentation(
                source: .local,
                title: "Не удалось выполнить действие",
                message: localError
            )
        }
        if let processError = processes.lastError {
            return WorkspaceAlertPresentation(
                source: .process,
                title: "Не удалось управлять браузером",
                message: processError
            )
        }
        if let storeError = store.lastError {
            return WorkspaceAlertPresentation(
                source: .storage,
                title: "Не удалось сохранить данные",
                message: storeError
            )
        }
        return nil
    }

    private var workspaceAlertBinding:
        Binding<WorkspaceAlertPresentation?>
    {
        Binding(
            get: { workspaceAlert },
            set: { value in
                guard value == nil, let source = workspaceAlert?.source else {
                    return
                }
                clearWorkspaceAlert(source)
            }
        )
    }

    var body: some View {
        workspaceLifecycle
    }

    private var workspaceBase: some View { workspaceNavigation }

    private var workspaceNavigation: some View {
        let listState = currentProfileListViewState
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            workspaceSources(listState)
                .workspaceKeyboardRegion(.sidebar)
                .navigationSplitViewColumnWidth(
                    min: WorkspaceLayout.minimumSourceColumnWidth,
                    ideal: WorkspaceLayout.idealSourceColumnWidth,
                    max: WorkspaceLayout.maximumSourceColumnWidth
                )
        } detail: {
            profileListPane(listState)
                .workspaceKeyboardRegion(.profileList)
                .navigationSplitViewColumnWidth(
                    min: WorkspaceLayout.minimumProfileColumnWidth,
                    ideal: WorkspaceLayout.idealProfileColumnWidth,
                    max: WorkspaceLayout.maximumProfileColumnWidth
                )
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showsProfileInspector) {
            detail
                .workspaceKeyboardRegion(.inspector)
                .inspectorColumnWidth(
                    min: WorkspaceLayout.minimumInspectorWidth,
                    ideal: WorkspaceLayout.idealInspectorWidth,
                    max: WorkspaceLayout.maximumInspectorWidth
                )
        }
        .frame(
            minWidth: WorkspaceLayout.minimumWindowWidth,
            minHeight: WorkspaceLayout.minimumWindowHeight
        )
        .toolbar { workspaceToolbar }
        .focusedSceneValue(
            \.neAntikProfileCommands,
            selectedProfileCommandSet
        )
        .focusedSceneValue(
            \.neAntikWorkspaceCommands,
            workspaceCommandSet
        )
    }

    private var workspaceSheets: some View {
        workspaceBase
        .sheet(item: $editorRequest) { request in
            profileEditorSheet(for: request)
        }
        .sheet(item: $profileNoteRequest) { request in
            ProfileNoteEditorView(
                profileName: request.profile.name,
                initialNote: request.profile.note
            ) { note in
                try saveProfileNote(
                    note,
                    profileID: request.profile.id
                )
            }
        }
        .sheet(item: $folderNameRequest) { request in
            ProfileFolderNameSheet(
                title: request.folder == nil
                    ? "Новая папка"
                    : "Переименовать папку",
                initialName: request.folder?.name ?? "",
                existingNames: store.organization.folders.map(\.name)
            ) { name in
                if let folder = request.folder {
                    _ = try store.renameFolder(
                        withID: folder.id,
                        to: name
                    )
                } else {
                    let folder = try store.createFolder(named: name)
                    selectedFolderFilter = .folder(folder.id)
                    selectedProfileTag = nil
                    normalizeSelection()
                }
            }
        }
        .sheet(item: $profileFolderPickerRequest) { request in
            let profiles = store.profiles.filter {
                request.profileIDs.contains($0.id)
            }
            if profiles.count == request.profileIDs.count,
               !profiles.isEmpty {
                let firstFolderID = store.folderID(
                    forProfileID: profiles[0].id
                )
                let sharesFolder = profiles.allSatisfy {
                    store.folderID(forProfileID: $0.id) == firstFolderID
                }
                ProfileFolderPickerSheet(
                    selectionDescription:
                        profiles.count == 1
                            ? "Профиль «\(profiles[0].name)»"
                            : "Выбрано \(profiles.count) \(profileCountWord(profiles.count))",
                    folders: store.organization.folders,
                    selectedFolderID: sharesFolder ? firstFolderID : nil,
                    hasMixedSelection: !sharesFolder
                ) { folderID in
                    if profiles.count == 1 {
                        moveProfile(profiles[0], toFolderID: folderID)
                    } else {
                        moveProfiles(
                            request.profileIDs,
                            toFolderID: folderID
                        )
                    }
                }
            } else {
                ProfileFolderPickerUnavailableSheet {
                        profileFolderPickerRequest = nil
                }
            }
        }
        .sheet(item: $profileBatchTagRequest) { request in
            ProfileBatchTagSheet(
                profileCount: request.profileIDs.count,
                suggestedTags: currentProfileListIndex.tagSummaries(
                    scope: profileListScope,
                    in: selectedFolderFilter
                ).map(\.name)
            ) { action in
                applyBatchMetadata(action, to: request.profileIDs)
            }
        }
        .sheet(item: $bulkProxyImportRequest) { request in
            BulkProxyImportView(
                targetFolderName: request.targetFolderID.flatMap {
                    store.folder(withID: $0)?.name
                }
            ) { drafts, baseName in
                try await createProfiles(
                    from: drafts,
                    baseName: baseName,
                    targetFolderID: request.targetFolderID
                )
            }
        }
        .sheet(isPresented: $showingWorkspaceReadiness) {
            WorkspaceReadinessView(
                snapshot: workspaceReadinessSnapshot,
                applicationPath:
                    readinessSystemInspection.application.displayPath,
                isRefreshing: isRefreshingWorkspaceReadiness,
                notice: workspaceReadinessNotice,
                onRecheck: {
                    Task { await refreshWorkspaceReadiness() }
                },
                onCopyDiagnostics: copyWorkspaceReadinessDiagnostics,
                onCopyApplicationPath: copyWorkspaceApplicationPath,
                onRevealApplication: revealWorkspaceApplication,
                onOpenSystemSettings: openWorkspaceSystemSettings
            )
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
        .sheet(item: $fingerprintAuditRequest) { request in
            FingerprintAuditView(
                profiles: request.auditedProfiles,
                initialFirstID: request.initialFirstID,
                runtime: request.runtime,
                processes: processes,
                paths: store.paths,
                onReport: { report in
                    for observation in
                        report.revisionBoundFingerprintObservations(
                            auditedProfiles: request.auditedProfiles,
                            currentProfiles: store.profiles,
                            runtime: request.runtime
                        )
                    {
                        fingerprintObservationStore.record(observation)
                    }
                }
            )
        }
    }

    private var workspaceAlerts: some View {
        workspaceSheets
        .alert(
            "Удалить профиль?",
            isPresented: $showingDeleteConfirmation,
            presenting: selectedProfile
        ) { profile in
            Button("Переместить в Корзину", role: .destructive) {
                do {
                    let outcome = try store.delete(
                        profile,
                        processManager: processes
                    ) { deletedProfile in
                        try keychain.deleteProxyPassword(
                            profileID: deletedProfile.id
                        )
                    }
                    finishDeletedProfile(profile)
                    if let warning = outcome.warningDescription {
                        localError = warning
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
            "Удалить папку?",
            isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { visible in
                    if !visible {
                        folderPendingDelete = nil
                    }
                }
            ),
            presenting: folderPendingDelete
        ) { folder in
            Button("Удалить папку", role: .destructive) {
                deleteFolder(folder)
            }
            Button("Отмена", role: .cancel) {}
        } message: { folder in
            let count = store.organization.profileIDs(
                inFolderID: folder.id
            ).count
            Text(
                "Папка «\(folder.name)» будет удалена. \(count) \(profileCountWord(count)) останутся и перейдут в «Без папки»."
            )
        }
        .alert(
            launchPreparationFailure?.title ?? "Не удалось запустить",
            isPresented: Binding(
                get: { launchPreparationFailure != nil },
                set: { visible in
                    if !visible {
                        launchPreparationFailure = nil
                    }
                }
            ),
            presenting: launchPreparationFailure
        ) { failure in
            Button("Повторить") {
                launchPreparationFailure = nil
                if let profile = store.profile(withID: failure.profileID) {
                    launch(profile)
                }
            }
            if failure.offersProxyEdit {
                Button("Изменить прокси…") {
                    launchPreparationFailure = nil
                    if let profile = store.profile(withID: failure.profileID) {
                        beginEditing(profile)
                    }
                }
            }
            Button("Отмена", role: .cancel) {
                launchPreparationFailure = nil
            }
        } message: { failure in
            Text(failure.message)
        }
        .alert(
            "Принудительно остановить?",
            isPresented: Binding(
                get: { forceStopRequest != nil },
                set: { visible in
                    if !visible { forceStopRequest = nil }
                }
            ),
            presenting: forceStopRequest
        ) { profile in
            Button("Оставить работающим", role: .cancel) {
                forceStopRequest = nil
            }
            Button("Принудительно остановить", role: .destructive) {
                _ = processes.forceStop(profileID: profile.id)
                forceStopRequest = nil
            }
        } message: { profile in
            Text(
                "Chromium профиля «\(profile.name)» не ответил на обычную остановку. Принудительное завершение может потерять незаписанные вкладки или данные сессии."
            )
        }
        .alert(item: workspaceAlertBinding) { presentation in
            workspaceAlert(for: presentation)
        }
    }

    private func workspaceAlert(
        for presentation: WorkspaceAlertPresentation
    ) -> Alert {
        if presentation.offersReadinessRecovery {
            return Alert(
                title: Text(presentation.title),
                message: Text(presentation.message),
                primaryButton: .default(Text("Открыть готовность")) {
                    clearWorkspaceAlert(presentation.source)
                    presentWorkspaceReadiness()
                },
                secondaryButton: .cancel(Text("Закрыть")) {
                    clearWorkspaceAlert(presentation.source)
                }
            )
        }
        return Alert(
            title: Text(presentation.title),
            message: Text(presentation.message),
            dismissButton: .default(Text("Закрыть")) {
                clearWorkspaceAlert(presentation.source)
            }
        )
    }

    private var workspaceStateObservers: some View {
        workspaceAlerts
        .onAppear {
            normalizeSelection(preferred: selection)
            Task { @MainActor in
                await Task.yield()
                normalizeSelection(
                    preferred: preferredProfileSelection ?? selection
                )
            }
            processes.reconcile(profiles: store.profiles)
            presentReleaseFingerprintAuditIfNeeded()
        }
        .onChange(of: profileSearchText) { _, _ in
            batchSelectedProfileIDs.removeAll()
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: selection) { _, selectedProfileID in
            if selectedProfileID == nil, store.profiles.isEmpty {
                showsProfileInspector = false
            }
        }
        .onChange(of: selectedProfileTag) { _, _ in
            batchSelectedProfileIDs.removeAll()
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: profileListScope) { _, _ in
            batchSelectedProfileIDs.removeAll()
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: profileOperationalFilter) { _, _ in
            batchSelectedProfileIDs.removeAll()
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: processes.runningProfileIDs) { _, _ in
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: processes.processStateRevision) { _, _ in
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: proxyHealthCoordinator.healthByProfileID) { _, _ in
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: selectedFolderFilter) { _, _ in
            batchSelectedProfileIDs.removeAll()
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: store.profileListRevision) { _, _ in
            batchSelectedProfileIDs.formIntersection(
                store.profiles.map(\.id)
            )
            if let selectedProfileTag,
               currentProfileListIndex.displayName(for: selectedProfileTag)
                    == nil
            {
                self.selectedProfileTag = nil
            }
            guard case let .folder(folderID) = selectedFolderFilter,
                  store.organization.folder(withID: folderID) == nil
            else {
                normalizeSelection(preferred: preferredProfileSelection)
                return
            }
            selectedFolderFilter = .unfiled
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: runtimeAvailability) { _, availability in
            presentReleaseFingerprintAuditIfNeeded()
            announceRuntimeAvailability(availability)
        }
    }

    private var workspaceNotifications: some View {
        workspaceStateObservers
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
            if showingWorkspaceReadiness {
                Task { await refreshWorkspaceReadiness() }
            }
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
            processes.markManagerShutdownClean()
        }
    }

    private var workspaceLifecycle: some View {
        workspaceNotifications
        .task {
            if resolvedRuntime == nil {
                await resolveRuntime()
            }
        }
        .task {
            await recoverDeletedProfileCredentials()
        }
        .task {
            await loadProxyHealth()
        }
        .onDisappear {
            cancelProxyTests()
        }
    }

    private func profileEditorSheet(
        for request: EditorRequest
    ) -> some View {
        let initialFolderID = request.profile.flatMap {
            store.folderID(forProfileID: $0.id)
        } ?? request.targetFolderID
        let suggestedTags = ProfileListProjection.allTags(
            in: store.profiles
        )
        return ProfileEditorView(
            original: request.profile,
            keychain: keychain,
            folders: store.organization.folders,
            initialFolderID: initialFolderID,
            suggestedTags: suggestedTags,
            appliesOnNextLaunch:
                request.openedProcessState?.isConfirmedRunning == true
        ) { profile, passwordUpdate, folderID in
            try saveProfileEditorDraft(
                profile,
                passwordUpdate: passwordUpdate,
                folderID: folderID,
                original: request.profile,
                openedProcessState: request.openedProcessState
            )
        }
    }

    private func saveProfileEditorDraft(
        _ profile: BrowserProfile,
        passwordUpdate: ProxyPasswordUpdate,
        folderID: UUID?,
        original: BrowserProfile?,
        openedProcessState: BrowserProfileProcessState?
    ) throws {
        if let original {
            try ProfileEditorProcessPolicy.validateSave(
                openedState: openedProcessState ?? .checking,
                currentState: presentedProcessState(for: original)
            )
        }
        var profile = profile
        if passwordUpdate != .keepExisting {
            profile.identity = profile.identity.replacingProxyContext(
                timezoneIdentifier: nil,
                localeIdentifier: nil,
                evidence: nil
            )
        }
        let saved = try store.upsert(
            profile,
            toFolderID: folderID
        ) { saved in
            guard passwordUpdate.requiresCredentialMutation(
                originalHadUsername:
                    original?.proxy?.username.isEmpty == false
            ) else {
                return
            }
            switch passwordUpdate {
            case .delete:
                try keychain.updateProxyPasswordForProfileEdit(
                    nil,
                    profileID: saved.id
                )
            case .keepExisting:
                break
            case let .replace(password):
                try keychain.updateProxyPasswordForProfileEdit(
                    password,
                    profileID: saved.id
                )
            }
        }
        if let original,
           original.identity != saved.identity || original.proxy != saved.proxy
        {
            fingerprintObservationStore.remove(profileID: saved.id)
        }
        revealSavedProfile(saved)
        if original?.proxy != saved.proxy ||
            passwordUpdate != .keepExisting
        {
            clearProxyHealth(for: saved.id)
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: presentWorkspaceReadiness) {
                Label("Готовность", systemImage: "checkmark.shield")
            }
            .help("Проверить приложение, движок, данные и процессы")
            .accessibilityLabel("Открыть центр готовности NeAntik")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: toggleProfileInspector) {
                Label(
                    showsProfileInspector ? "Скрыть сведения" : "Сведения",
                    systemImage: "sidebar.right"
                )
            }
            .disabled(selectedProfile == nil)
            .help(
                showsProfileInspector
                    ? "Скрыть сведения о профиле"
                    : "Показать сведения о профиле"
            )
            .accessibilityLabel(
                showsProfileInspector
                    ? "Скрыть сведения о выбранном профиле"
                    : "Показать сведения о выбранном профиле"
            )
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

    private func finishDeletedProfile(_ profile: BrowserProfile) {
        batchSelectedProfileIDs.remove(profile.id)
        if store.profiles.isEmpty {
            profileSearchText = ""
            selectedProfileTag = nil
            profileListScope = .active
            profileOperationalFilter = .all
        }
        normalizeSelection()
        fingerprintObservationStore.remove(profileID: profile.id)
        clearProxyHealth(for: profile.id)
    }

    private func normalizeSelection(preferred: UUID? = nil) {
        selection = ProfileListProjection.normalizedSelection(
            preferred ?? preferredProfileSelection ?? selection,
            in: visibleProfiles
        )
    }

    private func revealSavedProfile(_ profile: BrowserProfile) {
        let decision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: workspaceQuery,
            currentSearchText: profileSearchText,
            currentRouteFilter: profileRouteFilter,
            organization: store.organization
        )
        profileSearchText = decision.searchText
        profileRouteFilter = decision.routeFilter
        profileOperationalFilter = .all
        applyWorkspaceQuery(decision.query, normalize: false)
        preferredProfileSelection = decision.selectedProfileID
        selection = decision.selectedProfileID
        normalizeSelection(preferred: decision.selectedProfileID)
    }

    private func clearWorkspaceAlert(
        _ source: WorkspaceAlertPresentation.Source
    ) {
        switch source {
        case .local:
            localError = nil
        case .process:
            processes.lastError = nil
        case .storage:
            store.lastError = nil
        }
    }

    private var profileSelectionBinding: Binding<UUID?> {
        Binding(
            get: { selection },
            set: { value in
                if value == nil, !visibleProfiles.isEmpty {
                    return
                }
                selection = value
                if let value {
                    preferredProfileSelection = value
                }
            }
        )
    }

    private func beginEditing(_ profile: BrowserProfile) {
        let state = presentedProcessState(for: profile)
        guard state == .stopped || state.isConfirmedRunning else {
            localError = "Состояние профиля пока не подтверждено. Повтори после проверки процесса."
            return
        }
        editorRequest = EditorRequest(
            profile: profile,
            openedProcessState: state
        )
    }

    private func beginEditingNote(_ profile: BrowserProfile) {
        guard store.profile(withID: profile.id) != nil else {
            localError = "Профиль больше не существует."
            return
        }
        profileNoteRequest = ProfileNoteRequest(profile: profile)
    }

    private func saveProfileNote(
        _ note: String,
        profileID: UUID
    ) throws {
        let saved = try store.mutateProfile(withID: profileID) {
            $0.note = note
        }
        revealSavedProfile(saved)
    }

    private func revealProfile(_ profile: BrowserProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([
            store.paths.profileDirectory(for: profile.id)
        ])
    }

    private func requestProfileDeletion(_ profile: BrowserProfile) {
        guard !processes.runningProfileIDs.contains(profile.id) else {
            localError = "Сначала останови профиль, потом удаляй."
            return
        }
        selection = profile.id
        showingDeleteConfirmation = true
    }

    private func resetProfileFilters() {
        batchSelectedProfileIDs.removeAll()
        profileSearchText = ""
        profileRouteFilter = .all
        profileOperationalFilter = .all
        applyWorkspaceQuery(workspaceQuery.reset(), normalize: false)
        normalizeSelection(preferred: preferredProfileSelection)
    }

    private func resetProfileView() {
        profileListOrdering = .pinnedThenName
        workspacePreferences.resetInterface()
        resetProfileFilters()
    }

    private func toggleProfileInspector() {
        guard selectedProfile != nil else { return }
        showsProfileInspector.toggle()
    }

    private func applyWorkspaceQuery(
        _ query: WorkspaceQueryState,
        normalize: Bool = true
    ) {
        batchSelectedProfileIDs.removeAll()
        profileListScope = query.scope
        selectedFolderFilter = query.folderFilter
        selectedProfileTag = query.tag
        if normalize {
            normalizeSelection(preferred: preferredProfileSelection)
        }
    }

    private func beginCreatingProfile() {
        guard !isWorkspaceModalPresented else { return }
        editorRequest = EditorRequest(
            profile: nil,
            targetFolderID: selectedFolderID
        )
    }

    private func beginCreatingFolder() {
        guard !isWorkspaceModalPresented else { return }
        folderNameRequest = FolderNameRequest(folder: nil)
    }

    private func createAndOpenProfileQuickly() {
        guard runtimeAvailability == .ready else {
            if !isResolvingRuntime {
                Task { await resolveRuntime() }
            }
            return
        }
        guard !isCreatingProfileQuickly,
              !isWorkspaceModalPresented
        else { return }

        let profile = FirstProfileBootstrap.makeProfile(
            existingProfiles: store.profiles
        ) ?? QuickProfileBootstrap.makeProfile(
            existingProfiles: store.profiles
        )

        isCreatingProfileQuickly = true
        defer { isCreatingProfileQuickly = false }

        do {
            let saved = try store.upsert(
                profile,
                toFolderID: selectedFolderID
            )
            revealSavedProfile(saved)
            launch(saved)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func moveProfile(
        _ profile: BrowserProfile,
        toFolderID folderID: UUID?
    ) {
        do {
            try store.assignProfile(profile.id, toFolderID: folderID)
            normalizeSelection(preferred: profile.id)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func moveProfiles(
        _ profileIDs: Set<UUID>,
        toFolderID folderID: UUID?
    ) {
        do {
            let receipt = try store.assignProfilesRecordingUndo(
                profileIDs,
                toFolderID: folderID
            )
            if receipt.canUndo {
                workspaceBatchUndo = .folder(receipt)
                announceWorkspaceStatus(
                    "Перемещено \(receipt.affectedCount) \(profileCountWord(receipt.affectedCount))."
                )
            }
            normalizeSelection(preferred: selection)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func applyBatchMetadata(
        _ action: ProfileMetadataBatchAction,
        to profileIDs: Set<UUID>? = nil
    ) {
        let selectedIDs = profileIDs ?? batchSelectedProfileIDs
        do {
            let receipt = try store.applyBatch(action, to: selectedIDs)
            if receipt.canUndo {
                workspaceBatchUndo = .metadata(receipt)
                announceWorkspaceStatus(
                    "Изменено \(receipt.affectedCount) \(profileCountWord(receipt.affectedCount))."
                )
            }
            if case .setArchived(true) = action {
                batchSelectedProfileIDs.subtract(
                    receipt.affectedProfileIDs
                )
            }
            normalizeSelection(preferred: selection)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func undoLastBatchAction() {
        guard let workspaceBatchUndo else { return }
        do {
            switch workspaceBatchUndo {
            case let .metadata(receipt):
                try store.undoBatch(receipt)
            case let .folder(receipt):
                try store.undoFolderAssignments(receipt)
            }
            self.workspaceBatchUndo = nil
            announceWorkspaceStatus(
                "Действие для \(workspaceBatchUndo.affectedCount) \(profileCountWord(workspaceBatchUndo.affectedCount)) отменено."
            )
            normalizeSelection(preferred: selection)
        } catch {
            self.workspaceBatchUndo = nil
            localError = error.localizedDescription
        }
    }

    private func deleteFolder(_ folder: ProfileFolder) {
        do {
            _ = try store.deleteFolder(withID: folder.id)
            if selectedFolderID == folder.id {
                selectedFolderFilter = .unfiled
            }
            folderPendingDelete = nil
            normalizeSelection()
        } catch {
            folderPendingDelete = nil
            localError = error.localizedDescription
        }
    }

    private func profileCountWord(_ count: Int) -> String {
        let lastTwo = count % 100
        if (11...14).contains(lastTwo) {
            return "профилей"
        }
        switch count % 10 {
        case 1: return "профиль"
        case 2...4: return "профиля"
        default: return "профилей"
        }
    }

    private func togglePinned(_ profile: BrowserProfile) {
        do {
            let saved = try store.mutateProfile(withID: profile.id) {
                $0.isPinned.toggle()
            }
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
            let saved = try store.mutateProfile(withID: profile.id) {
                $0.isArchived.toggle()
            }
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
            let saved = try store.upsert(
                copy,
                toFolderID: store.folderID(forProfileID: profile.id)
            ) { saved in
                if let password, !password.isEmpty {
                    try keychain.saveProxyPassword(
                        password,
                        profileID: saved.id
                    )
                }
            }
            revealSavedProfile(saved)
            bulkProxyStatusMessage =
                "Создан похожий профиль «\(saved.name)»: отдельная сессия и новая цифровая идентичность"
            if let bulkProxyStatusMessage {
                announceWorkspaceStatus(bulkProxyStatusMessage)
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func createProfiles(
        from drafts: [ProxyImportDraft],
        baseName: String,
        targetFolderID: UUID?
    ) async throws {
        let created = try await BulkProfileImporter.create(
            drafts: drafts,
            baseName: baseName,
            store: store,
            keychain: keychain,
            targetFolderID: targetFolderID
        )

        if let last = created.last {
            revealSavedProfile(last)
        }
    }

    private func workspaceSources(
        _ listState: ProfileListViewState
    ) -> some View {
        let sourceIndex = listState.index
        let tagSummaries = listState.tagSummaries
        let folderPreview = ProfileListProjection.folderPreview(
            store.organization.folders,
            selectedID: selectedFolderID,
            limit: showsAllFolders
                ? .max
                : ProfileListProjection.defaultPreviewLimit
        )
        let tagPreview = ProfileListProjection.tagPreview(
            tagSummaries,
            selectedID: selectedProfileTag,
            limit: showsAllTags
                ? .max
                : ProfileListProjection.defaultPreviewLimit
        )
        return List {
            Section {
                sourceButton(
                    title: "Все профили",
                    systemImage: "rectangle.stack.person.crop",
                    count: sourceIndex.count(
                        scope: .active,
                        in: selectedFolderFilter,
                        tagID: selectedProfileTag
                    ),
                    focusID: .allProfiles,
                    isSelected: profileListScope == .active
                ) {
                    applyWorkspaceQuery(
                        workspaceQuery.selecting(scope: .active)
                    )
                }

                sourceButton(
                    title: "Закреплённые",
                    systemImage: "pin.fill",
                    count: sourceIndex.count(
                        scope: .pinned,
                        in: selectedFolderFilter,
                        tagID: selectedProfileTag
                    ),
                    focusID: .pinned,
                    isSelected: profileListScope == .pinned
                ) {
                    applyWorkspaceQuery(
                        workspaceQuery.selecting(scope: .pinned)
                    )
                }

                if sourceIndex.archivedCount > 0 {
                    sourceButton(
                        title: "Архив",
                        systemImage: "archivebox",
                        count: sourceIndex.count(
                            scope: .archived,
                            in: selectedFolderFilter,
                            tagID: selectedProfileTag
                        ),
                        focusID: .archive,
                        isSelected: profileListScope == .archived
                    ) {
                        applyWorkspaceQuery(
                            workspaceQuery.selecting(scope: .archived)
                        )
                    }
                }
            } header: {
                Text("Профили")
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            Section {
                HStack {
                    sourceDisclosureButton(
                        title: "Папки",
                        isExpanded: $foldersSourceExpanded
                    )
                    Spacer()
                    Button {
                        beginCreatingFolder()
                    } label: {
                        Label("Новая папка…", systemImage: "plus")
                            .labelStyle(.iconOnly)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .help("Новая папка…")
                    .accessibilityLabel("Новая папка…")

                    if let selectedFolder {
                        Button {
                            folderNameRequest = FolderNameRequest(
                                folder: selectedFolder
                            )
                        } label: {
                            Label(
                                "Переименовать папку",
                                systemImage: "pencil"
                            )
                            .labelStyle(.iconOnly)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 32, height: 32)
                        .help("Переименовать «\(selectedFolder.name)»")
                        .accessibilityLabel(
                            "Переименовать папку \(selectedFolder.name)"
                        )
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .listRowBackground(Color.clear)

                if foldersSourceExpanded {
                    sourceButton(
                        title: "Без папки",
                        systemImage: "tray",
                        count: sourceIndex.count(
                            scope: profileListScope,
                            in: .unfiled,
                            tagID: selectedProfileTag
                        ),
                        focusID: .unfiled,
                        isSelected: selectedFolderFilter == .unfiled
                    ) {
                        applyWorkspaceQuery(
                            workspaceQuery.selecting(
                                folderFilter: .unfiled
                            )
                        )
                    }

                    ForEach(folderPreview.visibleItems) { folder in
                        sourceButton(
                            title: folder.name,
                            systemImage: "folder",
                            count: sourceIndex.count(
                                scope: profileListScope,
                                in: .folder(folder.id),
                                tagID: selectedProfileTag
                            ),
                            focusID: .folder(folder.id),
                            isSelected:
                                selectedFolderFilter == .folder(folder.id)
                        ) {
                            applyWorkspaceQuery(
                                workspaceQuery.selecting(
                                    folderFilter: .folder(folder.id)
                                )
                            )
                        }
                        .contextMenu {
                            Button("Переименовать…", systemImage: "pencil") {
                                folderNameRequest = FolderNameRequest(folder: folder)
                            }
                            Button(
                                "Удалить папку",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                folderPendingDelete = folder
                            }
                        }
                    }

                    if folderPreview.hasHiddenItems || showsAllFolders {
                        previewToggleButton(
                            isExpanded: showsAllFolders,
                            hiddenCount: folderPreview.hiddenCount,
                            noun: "папок"
                        ) {
                            showsAllFolders.toggle()
                        }
                    }
                }
            }

            if !tagSummaries.isEmpty || selectedProfileTag != nil {
                Section {
                    if tagsSourceExpanded {
                        ForEach(tagPreview.visibleItems) { summary in
                            sourceButton(
                                title: summary.name,
                                systemImage: "tag",
                                tagTone: ProfileTagAppearance.tone(
                                    for: summary.id
                                ),
                                count: summary.count,
                                focusID: .tag(summary.id),
                                isSelected: selectedProfileTag == summary.id
                            ) {
                                applyWorkspaceQuery(
                                    workspaceQuery.selecting(
                                        tag: selectedProfileTag == summary.id
                                            ? nil
                                            : summary.id
                                    )
                                )
                            }
                        }
                        if tagPreview.hasHiddenItems || showsAllTags {
                            previewToggleButton(
                                isExpanded: showsAllTags,
                                hiddenCount: tagPreview.hiddenCount,
                                noun: "тегов"
                            ) {
                                showsAllTags.toggle()
                            }
                        }
                    }
                } header: {
                    sourceDisclosureButton(
                        title: "Теги",
                        isExpanded: $tagsSourceExpanded
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Разделы профилей")
        .onKeyPress(.upArrow) {
            moveWorkspaceSourceFocus(
                from: focusedWorkspaceSource ?? selectedWorkspaceSourceFocus,
                offset: -1
            )
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveWorkspaceSourceFocus(
                from: focusedWorkspaceSource ?? selectedWorkspaceSourceFocus,
                offset: 1
            )
            return .handled
        }
        .navigationTitle("NeAntik")
    }

    private func profileListPane(
        _ listState: ProfileListViewState
    ) -> some View {
        let operationalProjection = ProfileOperationalProjection.resolve(
            profiles: listState.visibleProfiles,
            processState: { processes.processState(for: $0) },
            proxyHealth: { proxyHealthCoordinator.state(for: $0) }
        )
        let operationalProfiles = operationalProjection.profiles(
            for: profileOperationalFilter
        )
        let batchPresentation = ProfileBatchSelectionPresentation.resolve(
            visibleProfiles: operationalProfiles,
            selectedProfileIDs: batchSelectedProfileIDs,
            runningProfileIDs: processes.runningProfileIDs
        )
        return GeometryReader { proxy in
            let usesWideLayout =
                proxy.size.width >= ProfileRowLayout.minimumWideWidth
            VStack(spacing: 0) {
                profileListHeader(
                    operationalProjection: operationalProjection
                )
                Divider()
                runtimeReadinessBanner
                activeFiltersBar
                runningProfilesStrip

                if store.profiles.isEmpty {
                    FirstProfileOnboardingView(
                        runtimeAvailability: runtimeAvailability,
                        isCreatingProfile: isCreatingProfileQuickly,
                        onCreateAndOpen: createAndOpenProfileQuickly,
                        onRetryRuntimeCheck: {
                            Task { await resolveRuntime() }
                        },
                        onConfigure: beginCreatingProfile
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if listState.visibleProfiles.isEmpty {
                    ContentUnavailableView {
                        Label(
                            "Ничего не найдено",
                            systemImage: "magnifyingglass"
                        )
                    } description: {
                        Text("Измени поиск или фильтры.")
                    } actions: {
                        Button("Сбросить все фильтры") {
                            resetProfileFilters()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if operationalProfiles.isEmpty {
                    ContentUnavailableView {
                        Label(
                            profileOperationalFilter.emptyTitle,
                            systemImage: profileOperationalFilter.systemImage
                        )
                    } description: {
                        Text(profileOperationalFilter.emptyMessage)
                    } actions: {
                        Button("Показать все") {
                            profileOperationalFilter = .all
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        profileTableHeader(usesWideLayout: usesWideLayout)
                        if batchPresentation.hasSelection ||
                            workspaceBatchUndo != nil {
                            ProfileBatchActionBar(
                                presentation: batchPresentation,
                                canUndo: workspaceBatchUndo != nil,
                                onToggleAllVisible: {
                                    if batchPresentation.allVisibleSelected {
                                        batchSelectedProfileIDs.subtract(
                                            batchPresentation.visibleProfileIDs
                                        )
                                    } else {
                                        batchSelectedProfileIDs.formUnion(
                                            batchPresentation.visibleProfileIDs
                                        )
                                    }
                                },
                                onClear: {
                                    batchSelectedProfileIDs.removeAll()
                                },
                                onTogglePinned: {
                                    applyBatchMetadata(
                                        .setPinned(
                                            !batchPresentation.allSelectedPinned
                                        ),
                                        to: batchPresentation.selectedProfileIDs
                                    )
                                },
                                onChooseFolder: {
                                    profileFolderPickerRequest =
                                        ProfileFolderPickerRequest(
                                            profileIDs: batchPresentation
                                                .selectedProfileIDs
                                        )
                                },
                                onEditTag: {
                                    profileBatchTagRequest =
                                        ProfileBatchTagRequest(
                                            profileIDs: batchPresentation
                                                .selectedProfileIDs
                                        )
                                },
                                onToggleArchived: {
                                    applyBatchMetadata(
                                        .setArchived(
                                            !batchPresentation
                                                .allSelectedArchived
                                        ),
                                        to: batchPresentation.selectedProfileIDs
                                    )
                                },
                                onUndo: undoLastBatchAction
                            )
                        }
                        List(selection: profileSelectionBinding) {
                            ForEach(operationalProfiles) { profile in
                                let processState = presentedProcessState(
                                    for: profile
                                )
                                let launchAction = BrowserLaunchActionPresentation.resolve(
                                    processState: processState,
                                    isArchived: profile.isArchived,
                                    runtimeAvailability: runtimeAvailability,
                                    isProxyTesting: isProxyTestInFlight(
                                        profileID: profile.id
                                    ),
                                    isLaunchPreparation:
                                        launchPreparingProfileIDs.contains(profile.id)
                                )
                                ProfileRow(
                                    profile: profile,
                                    processState: processState,
                                    launchAction: launchAction,
                                    proxyHealth: proxyHealthCoordinator.state(
                                        for: profile
                                    ),
                                    isTestingProxy:
                                        isProxyTestInFlight(profileID: profile.id),
                                    folderName: store.folderID(forProfileID: profile.id)
                                        .flatMap { listState.index.folderNameByID[$0] },
                                    usesWideLayout: usesWideLayout,
                                    density: workspacePreferences.rowDensity,
                                    isBatchSelected:
                                        batchSelectedProfileIDs.contains(
                                            profile.id
                                        ),
                                    onToggleBatchSelection: {
                                        if !batchSelectedProfileIDs.insert(
                                            profile.id
                                        ).inserted {
                                            batchSelectedProfileIDs.remove(
                                                profile.id
                                            )
                                        }
                                    },
                                    onEditNote: {
                                        beginEditingNote(profile)
                                    },
                                    onToggleRunning: {
                                        if launchPreparingProfileIDs.contains(
                                            profile.id
                                        ) {
                                            cancelLaunchPreparation(
                                                profileID: profile.id
                                            )
                                        } else if processState.isRunning {
                                            processes.stop(profileID: profile.id)
                                        } else {
                                            launch(profile)
                                        }
                                    }
                                ) {
                                    profileContextMenu(
                                        profile,
                                        processState: processState
                                    )
                                }
                                .tag(profile.id)
                                .contextMenu {
                                    profileContextMenu(
                                        profile,
                                        processState: processState
                                    )
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle(workspaceHeaderTitle)
    }

    @ViewBuilder
    private func profileTableHeader(
        usesWideLayout: Bool
    ) -> some View {
        if usesWideLayout {
            VStack(spacing: 0) {
                HStack(spacing: ProfileRowLayout.spacing) {
                    Text("Выбор / запуск")
                        .frame(width: ProfileRowLayout.actionWidth)
                    Text("Профиль")
                        .frame(
                            minWidth: ProfileRowLayout.minimumIdentityWidth,
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    Text("Статус")
                        .frame(
                            width: ProfileRowLayout.statusWidth,
                            alignment: .leading
                        )
                    Text("Подключение")
                        .frame(
                            minWidth: ProfileRowLayout.minimumRouteWidth,
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    Text("Заметка / активность")
                        .frame(
                            minWidth: ProfileRowLayout.minimumContextWidth,
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    Color.clear
                        .frame(
                            width: ProfileRowLayout.menuWidth,
                            height: 1
                        )
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, ProfileRowLayout.horizontalPadding)
                .padding(.vertical, 7)
                Divider()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    private var runningProfilesStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            RunningProfilesStrip(
                items: BrowserProcessLifecycleProjection.resolve(
                    profiles: store.profiles,
                    processState: { processes.processState(for: $0) },
                    stopPhase: { processes.stopPhase(for: $0) },
                    startedAt: { processes.startedAt(for: $0) },
                    now: context.date
                ),
                onSelect: { profileID in
                    selection = profileID
                    preferredProfileSelection = profileID
                    showsProfileInspector = true
                },
                onFocus: { profileID in
                    _ = processes.focus(profileID: profileID)
                },
                onStop: { profileID in
                    processes.stop(profileID: profileID)
                },
                onForceStop: { profileID in
                    forceStopRequest = store.profile(withID: profileID)
                }
            )
        }
    }

    private func profileListHeader(
        operationalProjection: ProfileOperationalProjection
    ) -> some View {
        let bulkProxyAction = BulkProxyActionProjection.resolve(
            visibleProfiles: operationalProjection.profiles(
                for: profileOperationalFilter
            ),
            processState: { processes.processState(for: $0) },
            isPreparing: { launchPreparingProfileIDs.contains($0) },
            isTesting: { isProxyTestInFlight(profileID: $0) }
        )
        let summary = operationalProjection.summary
        let commandRow = HStack(spacing: 8) {
            profileSearchField

            Menu {
                Button {
                    bulkProxyImportRequest = BulkProxyImportRequest(
                        targetFolderID: selectedFolderID
                    )
                } label: {
                    Label(
                        "Создать из списка прокси…",
                        systemImage: "list.bullet.clipboard"
                    )
                }
                if bulkProxyTestTask == nil,
                   bulkProxyAction.isVisible
                {
                    Divider()
                    Button {
                        toggleBulkProxyTests()
                    } label: {
                        Label(
                            "Проверить прокси (\(bulkProxyAction.count))",
                            systemImage: "checkmark.shield"
                        )
                    }
                }
            } label: {
                Label("Действия", systemImage: "ellipsis.circle")
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Дополнительные действия со списком профилей")
            .accessibilityLabel(
                "Дополнительные действия со списком профилей"
            )

            profileListViewMenu

            Menu {
                Button {
                    createAndOpenProfileQuickly()
                } label: {
                    Label(
                        "Быстро: создать и открыть без прокси",
                        systemImage: "bolt.fill"
                    )
                }
                .disabled(
                    runtimeAvailability != .ready ||
                        isCreatingProfileQuickly
                )

                Divider()

                Button {
                    beginCreatingProfile()
                } label: {
                    Label(
                        "Настроить профиль…",
                        systemImage: "slider.horizontal.3"
                    )
                }
            } label: {
                Label("Создать профиль", systemImage: "plus")
                    .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 28)
            } primaryAction: {
                beginCreatingProfile()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .help(
                "Создать профиль (⌘N); стрелка открывает быстрый Direct-вариант"
            )
            .accessibilityLabel(
                "Создать профиль; доступны дополнительные варианты"
            )
        }
        return VStack(alignment: .leading, spacing: 10) {
            if !store.profiles.isEmpty {
                commandRow
                operationalFilterBar(summary)
            }

            if bulkProxyTestTask != nil {
                Button {
                    toggleBulkProxyTests()
                } label: {
                    Label(
                        "Остановить проверку",
                        systemImage: "stop.circle"
                    )
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .help("Остановить массовую проверку прокси")
                .accessibilityLabel("Остановить массовую проверку прокси")
                if let bulkProxyProgress {
                    BulkProxyProgressView(progress: bulkProxyProgress)
                }
            } else if let bulkProxyStatusMessage {
                HStack(spacing: 8) {
                    Label(bulkProxyStatusMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if !bulkProxyFailedProfileIDs.isEmpty {
                        Button("Повторить ошибки") {
                            retryFailedBulkProxyTests()
                        }
                        .controlSize(.small)
                        .help("Повторить только неуспешные проверки")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, WorkspaceLayout.titlebarContentInset)
    }

    private var workspaceHeaderTitle: String {
        if let selectedFolder {
            return selectedFolder.name
        }
        if selectedFolderFilter == .unfiled {
            return "Без папки"
        }
        return profileListScope.title
    }

    private func operationalFilterBar(
        _ summary: ProfileOperationalSummary
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProfileOperationalFilter.allCases) { filter in
                    let isSelected = profileOperationalFilter == filter
                    Button {
                        profileOperationalFilter = filter
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: filter.systemImage)
                                .accessibilityHidden(true)
                            Text(filter.title)
                            Text("\(summary.count(for: filter))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(
                                    isSelected ? Color.primary : .secondary
                                )
                        }
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .frame(minHeight: 28)
                        .background(
                            operationalFilterTint(filter).opacity(
                                isSelected ? 0.18 : 0.07
                            ),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    isSelected
                                        ? operationalFilterTint(filter).opacity(0.55)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(filter.title): \(summary.count(for: filter))"
                    )
                    .accessibilityValue(
                        isSelected ? "Выбрано" : "Не выбрано"
                    )
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .accessibilityLabel("Быстрые представления профилей")
    }

    private func operationalFilterTint(
        _ filter: ProfileOperationalFilter
    ) -> Color {
        switch filter {
        case .running:
            .green
        case .attention:
            .orange
        case .all, .neverLaunched:
            .accentColor
        }
    }

    private var profileSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                "Профиль или заметка",
                text: $profileSearchText
            )
            .textFieldStyle(.plain)
            .focused($profileSearchIsFocused)
            .accessibilityLabel(
                "Поиск профилей, маршрутов, заметок, тегов и папок"
            )
            .accessibilityHint(
                "Можно уточнить запрос: тег, папка, прокси или статус. Название с пробелами заключи в кавычки."
            )
            if !profileSearchText.isEmpty {
                Button {
                    profileSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Очистить поиск")
                .accessibilityLabel("Очистить поиск профилей")
            }
            Button {
                showsProfileSearchHelp.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Синтаксис поиска")
            .accessibilityLabel("Показать синтаксис поиска")
            .popover(isPresented: $showsProfileSearchHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Поиск по полям")
                        .font(.headline)
                        .accessibilityHeading(.h2)
                    Text(
                        "Обычный текст ищет по профилю и заметке. " +
                            "Для точного поиска используй:"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(ProfileSearchSyntaxHelp.examples, id: \.self) {
                        Text($0)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("Название с пробелами заключи в кавычки.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 320, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 180, minHeight: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .help(
            "Примеры: тег:tiktok, папка:\"Paid Social\", прокси:есть, статус:закреплен"
        )
        .onExitCommand(perform: exitProfileSearch)
    }

    private func exitProfileSearch() {
        if !profileSearchText.isEmpty {
            profileSearchText = ""
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Поиск профилей очищен",
                    .priority:
                        NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        } else {
            profileSearchIsFocused = false
        }
    }

    private var profileListViewMenu: some View {
        Menu {
            Picker("Сортировка", selection: $profileListOrdering) {
                ForEach(ProfileListOrdering.allCases) { ordering in
                    Text(ordering.title).tag(ordering)
                }
            }
            Divider()
            Picker("Подключение", selection: profileRouteFilterBinding) {
                ForEach(ProfileRouteFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            Divider()
            Picker(
                "Плотность",
                selection: $workspacePreferences.rowDensity
            ) {
                ForEach(ProfileRowDensity.allCases) { density in
                    Label(density.title, systemImage: density.systemImage)
                        .tag(density)
                }
            }
            Divider()
            Button("Сбросить вид", systemImage: "arrow.counterclockwise") {
                resetProfileView()
            }
        } label: {
            Label("Фильтры", systemImage: "line.3.horizontal.decrease")
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 28)
        }
        .menuStyle(.borderlessButton)
        .help("Сортировка и фильтр подключения")
        .accessibilityLabel("Фильтры и сортировка профилей")
        .accessibilityValue(
            "\(profileListOrdering.title), \(profileRouteFilter.title), " +
                workspacePreferences.rowDensity.title
        )
    }

    private var profileRouteFilterBinding: Binding<ProfileRouteFilter> {
        Binding(
            get: { profileRouteFilter },
            set: { filter in
                profileRouteFilter = filter
                normalizeSelection(preferred: preferredProfileSelection)
            }
        )
    }

    @ViewBuilder
    private var runtimeReadinessBanner: some View {
        if runtimeAvailability != .ready {
            HStack(alignment: .top, spacing: 8) {
                if isResolvingRuntime {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: runtimeStatusIcon)
                        .foregroundStyle(runtimeStatusColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtimeReadinessTitle)
                    .font(.subheadline.weight(.medium))
                    Text(runtimeReadinessMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !isResolvingRuntime {
                    Button("Подробнее") {
                        presentWorkspaceReadiness()
                    }
                    .controlSize(.small)
                    .help("Открыть центр готовности и повторить проверку")
                    .accessibilityLabel(
                        "Открыть центр готовности NeAntik"
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.10))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var activeFiltersBar: some View {
        if selectedProfileTag != nil || selectedFolderFilter != .all ||
            profileListScope != .active || profileRouteFilter != .all
        {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let selectedFolder {
                        filterChip(selectedFolder.name, systemImage: "folder") {
                            applyWorkspaceQuery(
                                workspaceQuery.removing(.folder)
                            )
                        }
                    } else if selectedFolderFilter == .unfiled {
                        filterChip("Без папки", systemImage: "tray") {
                            applyWorkspaceQuery(
                                workspaceQuery.removing(.folder)
                            )
                        }
                    }
                    if let selectedProfileTagName {
                        filterChip(
                            selectedProfileTagName,
                            systemImage: "tag",
                            tagTone: ProfileTagAppearance.tone(
                                for: selectedProfileTagName
                            )
                        ) {
                            applyWorkspaceQuery(
                                workspaceQuery.removing(.tag)
                            )
                        }
                    }
                    if profileListScope != .active {
                        filterChip(profileListScope.title, systemImage: "line.3.horizontal.decrease.circle") {
                            applyWorkspaceQuery(
                                workspaceQuery.removing(.scope)
                            )
                        }
                    }
                    if profileRouteFilter != .all {
                        filterChip(
                            profileRouteFilter.title,
                            systemImage: "point.3.connected.trianglepath.dotted"
                        ) {
                            profileRouteFilter = .all
                            normalizeSelection(
                                preferred: preferredProfileSelection
                            )
                        }
                    }
                    Button("Сбросить") { resetProfileFilters() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Сбросить все фильтры")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            Divider()
        }
    }

    private func filterChip(
        _ title: String,
        systemImage: String,
        tagTone: ProfileTagTone? = nil,
        onRemove: @escaping () -> Void
    ) -> some View {
        let background = tagTone.map {
            Color(profileTagTone: $0).opacity(0.14)
        } ?? Color.secondary.opacity(0.10)
        return Button(action: onRemove) {
            HStack(spacing: 4) {
                if tagTone != nil {
                    ProfileTagMarker(tag: title)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title).lineLimit(1)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(background, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Убрать фильтр «\(title)»")
        .accessibilityLabel("Убрать фильтр \(title)")
    }

    private func sourceButton(
        title: String,
        systemImage: String,
        tagTone: ProfileTagTone? = nil,
        count: Int,
        focusID: WorkspaceSourceFocus,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label {
                    Text(title)
                        .foregroundStyle(Color(nsColor: .labelColor))
                } icon: {
                    if let tagTone {
                        Image(systemName: systemImage)
                            .foregroundStyle(
                                Color(profileTagTone: tagTone)
                            )
                    } else {
                        Image(systemName: systemImage)
                            .foregroundStyle(Color(nsColor: .labelColor))
                    }
                }
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .foregroundStyle(Color(nsColor: .labelColor))
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(Color(nsColor: .labelColor))
        .focusable()
        .focused($focusedWorkspaceSource, equals: focusID)
        .onKeyPress(.upArrow) {
            moveWorkspaceSourceFocus(from: focusID, offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveWorkspaceSourceFocus(from: focusID, offset: 1)
            return .handled
        }
        .onKeyPress(.space) {
            action()
            return .handled
        }
        .onKeyPress(.return) {
            action()
            return .handled
        }
        .listRowBackground(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear
        )
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isSelected ? "Выбрано" : "Не выбрано")
        .accessibilityHint("Показывает соответствующие профили")
    }

    private func sourceDisclosureButton(
        title: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(
                    systemName: isExpanded.wrappedValue
                        ? "chevron.down"
                        : "chevron.right"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                Text(title)
                    .foregroundStyle(Color(nsColor: .labelColor))
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(Color(nsColor: .labelColor))
        .foregroundStyle(Color(nsColor: .labelColor))
        .accessibilityLabel(title)
        .accessibilityValue(
            isExpanded.wrappedValue ? "Развёрнуто" : "Свёрнуто"
        )
        .accessibilityHint(
            isExpanded.wrappedValue
                ? "Сворачивает раздел"
                : "Разворачивает раздел"
        )
    }

    private func previewToggleButton(
        isExpanded: Bool,
        hiddenCount: Int,
        noun: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(
                isExpanded
                    ? "Показать меньше"
                    : "Ещё \(hiddenCount) \(noun)",
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func moveWorkspaceSourceFocus(
        from current: WorkspaceSourceFocus,
        offset: Int
    ) {
        let index = currentProfileListIndex
        let order = WorkspaceQueryFocusProjection.visibleOrder(
            query: workspaceQuery,
            index: index,
            folders: store.organization.folders,
            foldersExpanded: foldersSourceExpanded,
            tagsExpanded: tagsSourceExpanded,
            folderPreviewLimit: showsAllFolders
                ? .max
                : ProfileListProjection.defaultPreviewLimit,
            tagPreviewLimit: showsAllTags
                ? .max
                : ProfileListProjection.defaultPreviewLimit
        )
        guard let position = order.firstIndex(of: current),
              !order.isEmpty
        else {
            return
        }
        let next = min(max(position + offset, 0), order.count - 1)
        focusedWorkspaceSource = order[next]
    }

    private var selectedWorkspaceSourceFocus: WorkspaceSourceFocus {
        if let selectedProfileTag {
            return .tag(selectedProfileTag)
        }
        switch selectedFolderFilter {
        case .unfiled:
            return .unfiled
        case let .folder(folderID):
            return .folder(folderID)
        case .all:
            break
        }
        switch profileListScope {
        case .pinned:
            return .pinned
        case .archived:
            return .archive
        case .active:
            return .allProfiles
        }
    }

    @ViewBuilder
    private func profileContextMenu(
        _ profile: BrowserProfile,
        processState: BrowserProfileProcessState
    ) -> some View {
        let commands = profileCommandSet(
            for: profile,
            processState: processState
        )
        profileOrganizationActions(commands)
        Divider()
        Button {
            selection = profile.id
            preferredProfileSelection = profile.id
            showsProfileInspector = true
        } label: {
            Label("Открыть сведения", systemImage: "sidebar.right")
        }
        Button(
            "Показать окно браузера",
            systemImage: "macwindow.on.rectangle",
            action: commands.focusRunning
        )
        .disabled(!commands.presentation.focusIsEnabled)
        Button(
            "Изменить…",
            systemImage: "pencil",
            action: commands.edit
        )
        .disabled(!commands.presentation.editIsEnabled)
        Button {
            beginEditingNote(profile)
        } label: {
            Label(
                profile.note.isEmpty
                    ? "Добавить заметку…"
                    : "Изменить заметку…",
                systemImage: "note.text"
            )
        }
        .disabled(!commands.presentation.noteIsEnabled)
        Button(
            commands.presentation.launchTitle,
            systemImage: commands.presentation.launchSystemImage,
            action: commands.toggleRunning
        )
        .disabled(!commands.presentation.launchIsEnabled)
        if processState == .forceStopAvailable {
            Button(role: .destructive) {
                forceStopRequest = profile
            } label: {
                Label(
                    "Принудительно остановить…",
                    systemImage: "bolt.trianglebadge.exclamationmark.fill"
                )
            }
        }
        Divider()
        Button(
            "Удалить профиль",
            systemImage: "trash",
            role: .destructive,
            action: commands.delete
        )
        .disabled(!commands.presentation.deleteIsEnabled)
    }

    @ViewBuilder
    private func profileOrganizationActions(
        _ commands: ProfileCommandSet
    ) -> some View {
        Button(
            commands.presentation.pinTitle,
            systemImage: commands.presentation.pinSystemImage,
            action: commands.togglePinned
        )
        Button(
            "Создать похожий",
            systemImage: "plus.square.on.square",
            action: commands.duplicate
        )
        moveToFolderMenu(commands)
        Button(
            commands.presentation.archiveTitle,
            systemImage: commands.presentation.archiveSystemImage,
            action: commands.toggleArchived
        )
        .disabled(!commands.presentation.archiveIsEnabled)
    }

    @ViewBuilder
    private func moveToFolderMenu(
        _ commands: ProfileCommandSet
    ) -> some View {
        Menu {
            ForEach(commands.folderOptions) { option in
                Button {
                    commands.moveToFolder(option.folderID)
                } label: {
                    Label(
                        option.title,
                        systemImage:
                            option.isSelected
                                ? "checkmark"
                                : (option.folderID == nil
                                    ? "tray"
                                    : "folder")
                    )
                }
            }

            if commands.hasMoreFolderOptions {
                Divider()
                Button(
                    "Выбрать другую папку…",
                    systemImage: "magnifyingglass",
                    action: commands.chooseFolder
                )
            }
        } label: {
            Label("Переместить в папку", systemImage: "folder")
        }
    }

    private func profileCommandSet(
        for profile: BrowserProfile,
        processState requestedProcessState: BrowserProfileProcessState? = nil
    ) -> ProfileCommandSet {
        let processState = requestedProcessState ?? presentedProcessState(
            for: profile
        )
        let launchAction = BrowserLaunchActionPresentation.resolve(
            processState: processState,
            isArchived: profile.isArchived,
            runtimeAvailability: runtimeAvailability,
            isProxyTesting: isProxyTestInFlight(profileID: profile.id),
            isLaunchPreparation:
                launchPreparingProfileIDs.contains(profile.id)
        )
        let currentFolderID = store.folderID(forProfileID: profile.id)
        let folderProjection = ProfileFolderCommandProjection.resolve(
            folders: store.organization.folders,
            currentFolderID: currentFolderID
        )
        return ProfileCommandSet(
            presentation: ProfileCommandPresentation.resolve(
                profile: profile,
                processState: processState,
                launchAction: launchAction
            ),
            folderOptions: folderProjection.options,
            hasMoreFolderOptions: folderProjection.hasMore,
            toggleRunning: {
                if launchPreparingProfileIDs.contains(profile.id) {
                    cancelLaunchPreparation(profileID: profile.id)
                } else if processState.isRunning {
                    processes.stop(profileID: profile.id)
                } else {
                    launch(profile)
                }
            },
            focusRunning: {
                _ = processes.focus(profileID: profile.id)
            },
            edit: { beginEditing(profile) },
            editNote: { beginEditingNote(profile) },
            togglePinned: { togglePinned(profile) },
            duplicate: { duplicate(profile) },
            moveToFolder: { moveProfile(profile, toFolderID: $0) },
            chooseFolder: {
                profileFolderPickerRequest = ProfileFolderPickerRequest(
                    profileIDs: [profile.id]
                )
            },
            toggleArchived: { toggleArchived(profile) },
            revealInFinder: { revealProfile(profile) },
            delete: { requestProfileDeletion(profile) }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            ProfileDetailView(
                profile: profile,
                processState: presentedProcessState(for: profile),
                browserDataPath: store.paths.browserDataDirectory(for: profile.id).path,
                folderName: store.folderID(forProfileID: profile.id).flatMap {
                    store.folder(withID: $0)?.name
                },
                environmentSnapshot: selectedEnvironmentSnapshot,
                isTestingProxy: isProxyTestInFlight(profileID: profile.id),
                canCancelProxyTest:
                    proxyTestingProfileIDs.contains(profile.id) ||
                    launchPreparingProfileIDs.contains(profile.id),
                canRunFingerprintAudit:
                    runtimePreflight?.isReady == true &&
                    runtime?.supportsFingerprintIdentity == true &&
                    fingerprintAuditProfiles.count >= 2 &&
                    processes.runningProfileIDs.isEmpty,
                clipboardNotice:
                    clipboardNotice?.profileID == profile.id
                        ? clipboardNotice?.message
                        : nil,
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
                },
                onTestProxy: {
                    startProxyTest(profile)
                },
                onCancelProxyTest: {
                    cancelProxyTest(profileID: profile.id)
                },
                onEditProxy: {
                    beginEditing(profile)
                },
                onChangeNote: {
                    beginEditingNote(profile)
                },
                onRunFingerprintAudit: {
                    beginFingerprintAudit()
                }
            )
            .id(profile.id)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        Group {
            if store.profiles.isEmpty {
                FirstProfileOnboardingView(
                    runtimeAvailability: runtimeAvailability,
                    isCreatingProfile: isCreatingProfileQuickly,
                    onCreateAndOpen: createAndOpenProfileQuickly,
                    onRetryRuntimeCheck: {
                        Task { await resolveRuntime() }
                    },
                    onConfigure: beginCreatingProfile
                )
            } else {
                ContentUnavailableView {
                    Label(
                        "Выбери профиль",
                        systemImage: "rectangle.stack.person.crop"
                    )
                } description: {
                    Text(
                        "Каждый профиль хранит свои файлы cookie, " +
                            "настройки сети и локальные данные."
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runtimeStatusIcon: String {
        guard let runtime else { return "exclamationmark.triangle.fill" }
        return runtime.supportsFingerprintIdentity
            ? "shield.lefthalf.filled"
            : "externaldrive.fill"
    }

    private var runtimeStatusColor: Color {
        switch runtimeAvailability {
        case .missing, .invalid:
            return .red
        case .resolving:
            return .orange
        case .ready:
            return .secondary
        }
    }

    private var runtimeReadinessTitle: String {
        switch runtimeAvailability {
        case .resolving:
            "Проверяем браузерный движок…"
        case .ready:
            "Браузерный движок готов"
        case .missing, .invalid:
            "Встроенный браузер недоступен"
        }
    }

    private var runtimeReadinessMessage: String {
        switch runtimeAvailability {
        case .resolving:
            "Это займёт несколько секунд."
        case .ready:
            "Можно запускать профили."
        case .missing:
            "NeAntik не нашёл встроенный браузерный движок. " +
                "Переустанови приложение из официального DMG или ZIP."
        case let .invalid(message):
            message
        }
    }

    private func launch(_ profile: BrowserProfile) {
        do {
            let runtime = try launchReadyRuntime()
            try validateLaunchPreflight(profile, runtime: runtime)
            switch BrowserLaunchPreparationPolicy.resolveForUserStart(
                profile: profile
            ) {
            case .launchImmediately:
                try launchPreparedProfile(
                    profile,
                    runtime: runtime,
                    preparationReceipt: nil
                )
            case .prepareProxyContext:
                // Every browser session gets its own route observation.
                // A manual health check is useful feedback, not authority to
                // reuse a potentially rotating endpoint at Start time.
                startAutomaticLaunchPreparation(
                    profile,
                    runtime: runtime
                )
            }
        } catch {
            launchPreparationFailure = LaunchPreparationFailure(
                profileID: profile.id,
                message: error.localizedDescription,
                title: "Браузер не запустился",
                offersProxyEdit: false
            )
        }
    }

    private func launchReadyRuntime() throws -> BrowserRuntime {
        guard let runtime else {
            throw NeAntikError.browserNotFound
        }
        let preflight = BrowserRuntimePreflightValidator.validate(runtime)
        guard preflight.isReady else {
            throw NeAntikError.runtimeValidationFailed(
                preflight.errors.joined(separator: " ")
            )
        }
        return runtime
    }

    private func launchPreparedProfile(
        _ profile: BrowserProfile,
        runtime: BrowserRuntime,
        preparationReceipt: BrowserLaunchPreparationReceipt?
    ) throws {
        try validateLaunchPreflight(profile, runtime: runtime)
        try processes.launch(
            profile: profile,
            runtime: runtime,
            preparationReceipt: preparationReceipt
        )
        guard store.markLaunched(profile.id) else {
            processes.stop(profileID: profile.id)
            throw NeAntikError.profileLaunchStateNotPersisted
        }
    }

    private func validateLaunchPreflight(
        _ profile: BrowserProfile,
        runtime: BrowserRuntime
    ) throws {
        let inspection = WorkspaceReadinessSystemInspector.inspect(
            application: WorkspaceApplicationIdentity.current(),
            dataRootURL: store.paths.rootDirectory
        )
        try BrowserLaunchStagedPreflight.validate(
            BrowserLaunchPreflightInput(
                profile: profile,
                // Presentation can synthesize `.checking` while proxy launch
                // preparation is in flight. Safety must inspect the actual
                // process state so a successful preparation can launch.
                processState: processes.processState(for: profile.id),
                runtimePreflight: BrowserRuntimePreflightValidator.validate(
                    runtime
                ),
                storage: inspection.storage
            )
        )
    }

    @MainActor
    private func startAutomaticLaunchPreparation(
        _ profile: BrowserProfile,
        runtime: BrowserRuntime
    ) {
        guard launchPreparationTasks[profile.id] == nil else { return }
        guard !isProxyTestInFlight(profileID: profile.id) else {
            launchPreparationFailure = LaunchPreparationFailure(
                profileID: profile.id,
                message:
                    "Прокси уже проверяется в другом окне. Дождись завершения или отмени проверку там."
            )
            return
        }

        let launchToken = UUID()
        launchPreparationTokens[profile.id] = launchToken
        launchPreparingProfileIDs.insert(profile.id)
        launchPreparationTasks[profile.id] = Task { @MainActor in
            defer {
                if launchPreparationTokens[profile.id] == launchToken {
                    launchPreparationTokens[profile.id] = nil
                    launchPreparingProfileIDs.remove(profile.id)
                    launchPreparationTasks[profile.id] = nil
                }
            }
            guard let token = beginProxyTest(for: profile) else {
                launchPreparationFailure = LaunchPreparationFailure(
                    profileID: profile.id,
                    message:
                        "Не удалось начать подготовку прокси. Повтори запуск."
                )
                return
            }
            let state = await executeProxyTest(
                profile,
                token: token,
                clearsDedicatedTask: false
            )
            guard !Task.isCancelled else {
                return
            }
            guard let state else {
                let message = localError ??
                    "Подготовка прокси уже выполняется в другом окне."
                localError = nil
                launchPreparationFailure = LaunchPreparationFailure(
                    profileID: profile.id,
                    message: message
                )
                return
            }
            guard state.latestAttempt.outcome == .succeeded else {
                launchPreparationFailure = LaunchPreparationFailure(
                    profileID: profile.id,
                    message: NeAntikError.proxyTestFailed(
                        state.latestAttempt.outcome.userSummary
                    ).localizedDescription
                )
                return
            }
            guard let currentProfile = store.profile(withID: profile.id),
                  currentProfile.proxy == profile.proxy
            else {
                launchPreparationFailure = LaunchPreparationFailure(
                    profileID: profile.id,
                    message:
                        "Профиль изменился во время подготовки. Проверь прокси и повтори запуск."
                )
                return
            }
            let currentHealth = proxyHealthCoordinator.state(
                for: currentProfile
            )
            guard BrowserLaunchPreparationPolicy.resolve(
                profile: currentProfile,
                proxyHealth: currentHealth
            ) == .launchImmediately
            else {
                launchPreparationFailure = LaunchPreparationFailure(
                    profileID: profile.id,
                    message:
                        "Прокси отвечает, но его часовой пояс и язык не удалось безопасно согласовать с профилем."
                )
                return
            }
            do {
                try launchPreparedProfile(
                    currentProfile,
                    runtime: runtime,
                    preparationReceipt:
                        BrowserLaunchPreparationPolicy.receipt(
                            profile: currentProfile,
                            proxyHealth: currentHealth
                        )
                )
            } catch {
                launchPreparationFailure = LaunchPreparationFailure(
                    profileID: currentProfile.id,
                    message:
                        "Прокси подготовлен, но браузер не запустился. " +
                        error.localizedDescription,
                    title: "Браузер не запустился",
                    offersProxyEdit: false
                )
            }
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

    private func presentWorkspaceReadiness() {
        guard !showingWorkspaceReadiness else { return }
        workspaceReadinessNotice = nil
        showingWorkspaceReadiness = true
        Task { await refreshWorkspaceReadiness() }
    }

    private func refreshWorkspaceReadiness() async {
        guard !isRefreshingWorkspaceReadiness else { return }
        isRefreshingWorkspaceReadiness = true
        workspaceReadinessNotice = nil
        readinessSystemInspection = .checking(
            application: WorkspaceApplicationIdentity.current()
        )
        let application = readinessSystemInspection.application
        let dataRootURL = store.paths.rootDirectory
        let inspectionTask = Task.detached(priority: .userInitiated) {
            WorkspaceReadinessSystemInspector.inspect(
                application: application,
                dataRootURL: dataRootURL
            )
        }
        await resolveRuntime()
        let inspection = await inspectionTask.value
        guard !Task.isCancelled else {
            isRefreshingWorkspaceReadiness = false
            return
        }
        readinessSystemInspection = inspection
        processes.reconcile(profiles: store.profiles)
        isRefreshingWorkspaceReadiness = false
        announceWorkspaceStatus(workspaceReadinessSnapshot.title)
    }

    private func copyWorkspaceReadinessDiagnostics() {
        writeWorkspaceReadinessClipboard(
            workspaceReadinessSnapshot.diagnosticText,
            notice: "Диагностика скопирована без секретов"
        )
    }

    private func copyWorkspaceApplicationPath() {
        writeWorkspaceReadinessClipboard(
            readinessSystemInspection.application.bundlePath,
            notice: "Путь к NeAntik.app скопирован"
        )
    }

    private func writeWorkspaceReadinessClipboard(
        _ value: String,
        notice: String
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            presentWorkspaceReadinessNotice(UserNotice(
                "Не удалось скопировать",
                level: .failure
            ))
            return
        }
        presentWorkspaceReadinessNotice(
            UserNotice(notice, level: .success)
        )
    }

    private func revealWorkspaceApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(
                fileURLWithPath:
                    readinessSystemInspection.application.bundlePath
            )
        ])
    }

    private func openWorkspaceSystemSettings() {
        guard let settingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) else {
            presentWorkspaceReadinessNotice(UserNotice(
                "Системные настройки не найдены",
                level: .failure
            ))
            return
        }
        NSWorkspace.shared.open(settingsURL)
        presentWorkspaceReadinessNotice(
            UserNotice(
                "NeAntik не читает статус разрешений macOS. Проверь нужный переключатель вручную.",
                level: .information
            )
        )
    }

    private func presentWorkspaceReadinessNotice(_ notice: UserNotice) {
        workspaceReadinessNotice = notice
        announceWorkspaceStatus(notice.accessibilitySummary)
    }

    private func announceRuntimeAvailability(
        _ availability: BrowserRuntimeAvailability
    ) {
        guard !store.profiles.isEmpty else { return }
        let message: String
        switch availability {
        case .resolving:
            return
        case .ready:
            message = "Браузерный движок готов. Профили можно запускать."
        case .missing, .invalid:
            message =
                "Встроенный браузер недоступен. Доступно повторить проверку."
        }
        announceWorkspaceStatus(message)
    }

    private func announceWorkspaceStatus(_ message: String) {
        guard workspaceAnnouncementGate.shouldAnnounce(message) else {
            return
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func beginFingerprintAudit() {
        guard let runtime,
              runtimePreflight?.isReady == true,
              fingerprintAuditProfiles.count >= 2
        else {
            localError =
                "Нужны два активных профиля и готовый встроенный браузерный движок."
            return
        }
        fingerprintAuditRequest = FingerprintAuditRequest(
            auditedProfiles: fingerprintAuditProfiles,
            initialFirstID: selectedProfile?.id,
            runtime: runtime
        )
    }

    @MainActor
    private func loadProxyHealth() async {
        await proxyHealthCoordinator.reload(profiles: store.profiles)
        if let error = proxyHealthCoordinator.lastError,
           localError == nil
        {
            localError = error
        }
    }

    @MainActor
    private func startProxyTest(_ profile: BrowserProfile) {
        guard processes.processState(for: profile.id) == .stopped,
              !launchPreparingProfileIDs.contains(profile.id),
              !isProxyTestInFlight(profileID: profile.id)
        else { return }
        guard let token = beginProxyTest(for: profile) else { return }
        proxyTestTasks[profile.id] = Task { @MainActor in
            _ = await executeProxyTest(
                profile,
                token: token,
                clearsDedicatedTask: true
            )
        }
    }

    @MainActor
    private func performProxyTest(
        _ profile: BrowserProfile
    ) async -> ProxyHealthOutcome? {
        guard processes.processState(for: profile.id) == .stopped,
              !launchPreparingProfileIDs.contains(profile.id),
              !isProxyTestInFlight(profileID: profile.id)
        else { return nil }
        guard let token = beginProxyTest(for: profile) else { return nil }
        return await executeProxyTest(
            profile,
            token: token,
            clearsDedicatedTask: false
        )?.latestAttempt.outcome
    }

    @MainActor
    private func beginProxyTest(
        for profile: BrowserProfile
    ) -> ProxyTestOperationToken? {
        guard profile.proxy != nil,
              let token = proxyTestOperations.claim(profileID: profile.id)
        else { return nil }
        proxyTestingProfileIDs.insert(profile.id)
        return token
    }

    @MainActor
    private func executeProxyTest(
        _ profile: BrowserProfile,
        token: ProxyTestOperationToken,
        clearsDedicatedTask: Bool
    ) async -> ProxyHealthState? {
        defer {
            if proxyTestOperations.complete(token) {
                proxyTestingProfileIDs.remove(profile.id)
                if clearsDedicatedTask {
                    proxyTestTasks[profile.id] = nil
                }
            }
        }
        guard let proxy = profile.proxy else { return nil }
        do {
            return try await proxyHealthCoordinator.run(
                profile: profile,
                operationWithCurrentIdentity: { previous in
                    try Task.checkCancellation()
                    guard proxyTestOperations.isCurrent(token) else {
                        throw CancellationError()
                    }
                    return try await proxyHealthCommit(
                        profileID: profile.id,
                        expectedProxy: proxy,
                        expectedRevision: profile.revision,
                        previous: previous
                    )
                }
            )
        } catch is CancellationError {
            return nil
        } catch {
            localError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    private func proxyHealthCommit(
        profileID: UUID,
        expectedProxy: ProxyConfiguration,
        expectedRevision: UInt64,
        previous: ProxyHealthState?
    ) async throws -> ProxyHealthTestCommit {
        let checkedAt = Date()
        let next: ProxyHealthState
        let password = try keychain.proxyPassword(
            profileID: profileID
        ) ?? ""
        do {
            let observation = try await ProxyTester().probe(
                configuration: expectedProxy,
                password: password
            )
            try Task.checkCancellation()
            let currentPassword = try keychain.proxyPassword(
                profileID: profileID
            ) ?? ""
            guard var currentProfile = store.profile(withID: profileID),
                  ProxyTestCommitPolicy.matchesSnapshot(
                      expectedProxy: expectedProxy,
                      currentProxy: currentProfile.proxy,
                      expectedRevision: expectedRevision,
                      currentRevision: currentProfile.revision,
                      credentialsMatch: currentPassword == password
                  )
            else {
                throw CancellationError()
            }
            currentProfile.identity =
                currentProfile.identity.replacingProxyContext(
                    timezoneIdentifier:
                        observation.result.timezoneIdentifier,
                    localeIdentifier: observation.result.localeIdentifier,
                    evidence: .ipAPI(observedAt: observation.observedAt)
                )
            _ = try store.upsert(currentProfile)
            fingerprintObservationStore.remove(profileID: profileID)
            next = ProxyHealthUpdatePolicy.success(observation)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProxyProbeError {
            let currentPassword = try keychain.proxyPassword(
                profileID: profileID
            ) ?? ""
            guard let currentProfile = store.profile(withID: profileID),
                  ProxyTestCommitPolicy.matchesSnapshot(
                      expectedProxy: expectedProxy,
                      currentProxy: currentProfile.proxy,
                      expectedRevision: expectedRevision,
                      currentRevision: currentProfile.revision,
                      credentialsMatch: currentPassword == password
                  )
            else {
                throw CancellationError()
            }
            next = ProxyHealthUpdatePolicy.failure(
                error,
                checkedAt: checkedAt,
                previous: previous
            )
        } catch {
            throw error
        }

        guard let currentProfile = store.profile(withID: profileID),
              currentProfile.proxy == expectedProxy,
              let currentIdentity = ProxyHealthIdentity(
                  profile: currentProfile
              )
        else {
            throw CancellationError()
        }
        return ProxyHealthTestCommit(
            state: next,
            currentIdentity: currentIdentity
        )
    }

    @MainActor
    private func toggleBulkProxyTests() {
        if let bulkProxyTestTask {
            let completed = bulkProxyProgress?.completed ?? 0
            let total = bulkProxyProgress?.total ?? 0
            bulkProxyStatusMessage = total > 0
                ? "Проверка остановлена: \(completed) из \(total)"
                : "Проверка остановлена"
            if let bulkProxyStatusMessage {
                announceWorkspaceStatus(bulkProxyStatusMessage)
            }
            bulkProxyProgress = nil
            bulkProxyTestTask.cancel()
            return
        }
        startBulkProxyTests(bulkProxyActionProjection.profiles)
    }

    @MainActor
    private func retryFailedBulkProxyTests() {
        let failed = Set(bulkProxyFailedProfileIDs)
        let eligible = bulkProxyActionProjection.profiles.filter {
            failed.contains($0.id)
        }
        guard !eligible.isEmpty else {
            bulkProxyFailedProfileIDs = []
            bulkProxyStatusMessage =
                "Неуспешные профили больше недоступны для проверки в текущем списке"
            if let bulkProxyStatusMessage {
                announceWorkspaceStatus(bulkProxyStatusMessage)
            }
            return
        }
        startBulkProxyTests(eligible)
    }

    @MainActor
    private func startBulkProxyTests(_ profiles: [BrowserProfile]) {
        guard !profiles.isEmpty else { return }
        let runID = UUID()
        bulkProxyTestID = runID
        bulkProxyProgress = BulkProxyRunProgress(total: profiles.count)
        bulkProxyStatusMessage = nil
        bulkProxyFailedProfileIDs = []
        bulkProxyTestTask = Task { @MainActor in
            var progress = BulkProxyRunProgress(total: profiles.count)
            for batchStart in stride(from: 0, to: profiles.count, by: 3) {
                guard !Task.isCancelled else { break }
                let batchEnd = min(batchStart + 3, profiles.count)
                let batch = Array(profiles[batchStart..<batchEnd])
                await withTaskGroup(
                    of: (UUID, ProxyHealthOutcome?).self
                ) { group in
                    for profile in batch {
                        group.addTask {
                            (
                                profile.id,
                                await performProxyTest(profile)
                            )
                        }
                    }
                    for await (profileID, outcome) in group {
                        guard !Task.isCancelled else { continue }
                        progress.record(
                            profileID: profileID,
                            outcome: outcome
                        )
                        guard bulkProxyTestID == runID else { continue }
                        bulkProxyProgress = progress
                    }
                }
                guard bulkProxyTestID == runID else { return }
            }
            if bulkProxyTestID == runID {
                if !Task.isCancelled {
                    bulkProxyStatusMessage =
                        progress.summary
                    bulkProxyFailedProfileIDs = progress.failedProfileIDs
                    if let bulkProxyStatusMessage {
                        announceWorkspaceStatus(bulkProxyStatusMessage)
                    }
                }
                bulkProxyTestTask = nil
                bulkProxyTestID = nil
                bulkProxyProgress = nil
            }
        }
    }

    @MainActor
    private func clearProxyHealth(for profileID: UUID) {
        cancelLaunchPreparation(profileID: profileID)
        proxyTestTasks[profileID]?.cancel()
        proxyTestTasks[profileID] = nil
        if proxyTestOperations.cancel(profileID: profileID) {
            proxyTestingProfileIDs.remove(profileID)
        }
        Task {
            do {
                try await proxyHealthCoordinator.remove(
                    profileID: profileID
                )
            } catch {
                if localError == nil {
                    localError = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func cancelProxyTest(profileID: UUID) {
        cancelLaunchPreparation(profileID: profileID)
        proxyTestTasks[profileID]?.cancel()
        proxyTestTasks[profileID] = nil
        if proxyTestOperations.cancel(profileID: profileID) {
            proxyTestingProfileIDs.remove(profileID)
        }
    }

    @MainActor
    private func cancelProxyTests() {
        for task in launchPreparationTasks.values {
            task.cancel()
        }
        launchPreparationTasks.removeAll()
        launchPreparationTokens.removeAll()
        launchPreparingProfileIDs.removeAll()
        bulkProxyTestTask?.cancel()
        bulkProxyTestTask = nil
        bulkProxyTestID = nil
        bulkProxyProgress = nil
        for task in proxyTestTasks.values {
            task.cancel()
        }
        proxyTestTasks.removeAll()
        proxyTestOperations.cancelAll()
        proxyTestingProfileIDs.removeAll()
    }

    @MainActor
    private func cancelLaunchPreparation(profileID: UUID) {
        launchPreparationTasks[profileID]?.cancel()
        launchPreparationTasks[profileID] = nil
        launchPreparationTokens[profileID] = nil
        launchPreparingProfileIDs.remove(profileID)
        if proxyTestOperations.cancel(profileID: profileID) {
            proxyTestingProfileIDs.remove(profileID)
        }
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
