import AppKit
import SwiftUI

private struct EditorRequest: Identifiable {
    let id = UUID()
    let profile: BrowserProfile?
    let targetFolderID: UUID?
    let initialFocus: ProfileEditorField?

    init(
        profile: BrowserProfile?,
        targetFolderID: UUID? = nil,
        initialFocus: ProfileEditorField? = nil
    ) {
        self.profile = profile
        self.targetFolderID = targetFolderID
        self.initialFocus = initialFocus
    }
}

private struct FolderNameRequest: Identifiable {
    let id = UUID()
    let folder: ProfileFolder?
}

private struct ProfileFolderPickerRequest: Identifiable {
    let id = UUID()
    let profileID: UUID
}

struct BulkProxyImportRequest: Identifiable {
    let id = UUID()
    let targetFolderID: UUID?
}

private typealias WorkspaceSourceFocus = WorkspaceQueryFocus

private struct WorkspaceAlertPresentation: Identifiable {
    enum Source: Hashable {
        case local
        case process
        case storage
    }

    let source: Source
    let title: String
    let message: String

    var id: Source { source }
}

private struct ClipboardNotice: Equatable {
    let profileID: UUID
    let message: String
}

private struct BulkProxyProgress: Equatable {
    let completed: Int
    let total: Int
}

private struct LaunchPreparationFailure: Identifiable, Equatable {
    let profileID: UUID
    let message: String
    var title: String = "Прокси не готов"
    var offersProxyEdit = true

    var id: UUID { profileID }
}

@MainActor
private final class ProfileListStateResolver {
    private var revision: UInt64?
    private var index: ProfileListIndex?
    private var viewStateKey: ViewStateKey?
    private var viewState: ProfileListViewState?

    private struct ViewStateKey: Equatable {
        let revision: UInt64
        let query: WorkspaceQueryState
        let searchText: String
        let routeFilter: ProfileRouteFilter
        let ordering: ProfileListOrdering
    }

    func resolve(
        revision requestedRevision: UInt64,
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState,
        query: WorkspaceQueryState,
        searchText: String,
        routeFilter: ProfileRouteFilter,
        ordering: ProfileListOrdering
    ) -> ProfileListViewState {
        let currentIndex = resolveIndex(
            revision: requestedRevision,
            profiles: profiles,
            organization: organization
        )
        let key = ViewStateKey(
            revision: requestedRevision,
            query: query,
            searchText: searchText,
            routeFilter: routeFilter,
            ordering: ordering
        )
        if viewStateKey == key, let viewState {
            return viewState
        }
        let resolved = ProfileListViewState(
            index: currentIndex,
            query: query,
            searchText: searchText,
            routeFilter: routeFilter,
            ordering: ordering
        )
        viewStateKey = key
        viewState = resolved
        return resolved
    }

    func resolveIndex(
        revision requestedRevision: UInt64,
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState
    ) -> ProfileListIndex {
        if revision == requestedRevision, let index {
            return index
        }
        let resolved = ProfileListIndex(
            profiles: profiles,
            organization: organization
        )
        revision = requestedRevision
        index = resolved
        viewStateKey = nil
        viewState = nil
        return resolved
    }
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
    @ObservedObject var fingerprintObservationStore:
        FingerprintObservationStore
    @ObservedObject var proxyHealthCoordinator:
        ProxyHealthCoordinator

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
    @State private var fingerprintAuditRequest: FingerprintAuditRequest?
    @State private var bulkProxyImportRequest: BulkProxyImportRequest?
    @State private var localError: String?
    @State private var launchPreparationFailure: LaunchPreparationFailure?
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
    @State private var selectedProfileTag: ProfileTagID?
    @State private var profileListScope: ProfileListScope = .active
    @State private var selectedFolderFilter: ProfileFolderFilter = .all
    @State private var profileRouteFilter: ProfileRouteFilter = .all
    @State private var profileListOrdering: ProfileListOrdering =
        .pinnedThenName
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
    @State private var bulkProxyProgress: BulkProxyProgress?
    @State private var bulkProxyStatusMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsProfileInspector = false
    @State private var preferredProfileSelection: UUID?
    @FocusState private var profileSearchIsFocused: Bool
    @FocusState private var focusedWorkspaceSource: WorkspaceSourceFocus?
    @State private var foldersSourceExpanded = true
    @State private var tagsSourceExpanded = true
    @State private var showsAllFolders = false
    @State private var showsAllTags = false
    @State private var isCreatingFirstProfile = false
    @State private var profileListResolver = ProfileListStateResolver()
    @State private var workspaceAnnouncementGate =
        AccessibilityAnnouncementGate<String>()

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
            folderNameRequest != nil ||
            profileFolderPickerRequest != nil ||
            bulkProxyImportRequest != nil ||
            showingReleaseFingerprintAudit ||
            fingerprintAuditRequest != nil ||
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
            createProfile: beginCreatingProfile,
            createFolder: beginCreatingFolder,
            focusProfileSearch: { profileSearchIsFocused = true },
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
        currentProfileListViewState.visibleProfiles
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

    private var hasArchivedProfiles: Bool {
        store.profiles.contains(where: \.isArchived)
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

    private var telemetrySnapshot: TelemetrySnapshot {
        TelemetrySnapshot(
            profileCount: store.profiles.count,
            proxyProfileCount: store.profiles.filter {
                $0.proxy != nil
            }.count
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
                .navigationSplitViewColumnWidth(
                    min: WorkspaceLayout.minimumSourceColumnWidth,
                    ideal: WorkspaceLayout.idealSourceColumnWidth,
                    max: WorkspaceLayout.maximumSourceColumnWidth
                )
        } detail: {
            profileListPane(listState)
                .navigationSplitViewColumnWidth(
                    min: WorkspaceLayout.minimumProfileColumnWidth,
                    ideal: WorkspaceLayout.idealProfileColumnWidth,
                    max: WorkspaceLayout.maximumProfileColumnWidth
                )
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showsProfileInspector) {
            detail
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
            if let profile = store.profile(withID: request.profileID) {
                ProfileFolderPickerSheet(
                    profileName: profile.name,
                    folders: store.organization.folders,
                    selectedFolderID: store.folderID(
                        forProfileID: profile.id
                    )
                ) { folderID in
                    moveProfile(profile, toFolderID: folderID)
                }
            } else {
                ProfileFolderPickerUnavailableSheet {
                        profileFolderPickerRequest = nil
                }
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
                    try store.delete(
                        profile,
                        processManager: processes
                    ) { deletedProfile in
                        try keychain.deleteProxyPassword(
                            profileID: deletedProfile.id
                        )
                    }
                    if store.profiles.isEmpty {
                        profileSearchText = ""
                        selectedProfileTag = nil
                        profileListScope = .active
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
                    fingerprintObservationStore.remove(profileID: profile.id)
                    clearProxyHealth(for: profile.id)
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
        .alert(item: workspaceAlertBinding) { presentation in
            Alert(
                title: Text(presentation.title),
                message: Text(presentation.message),
                dismissButton: .default(Text("OK")) {
                    clearWorkspaceAlert(presentation.source)
                }
            )
        }
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
            telemetry.record(.snapshot, snapshot: telemetrySnapshot)
            presentReleaseFingerprintAuditIfNeeded()
        }
        .onChange(of: profileSearchText) { _, _ in
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: selection) { _, selectedProfileID in
            if selectedProfileID == nil {
                showsProfileInspector = false
            }
        }
        .onChange(of: selectedProfileTag) { _, _ in
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: profileListScope) { _, _ in
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: selectedFolderFilter) { _, _ in
            normalizeSelection(preferred: preferredProfileSelection)
        }
        .onChange(of: store.profileListRevision) { _, _ in
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
        .onChange(of: telemetrySnapshot) { _, value in
            telemetry.record(.snapshot, snapshot: value)
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
    }

    private var workspaceLifecycle: some View {
        workspaceNotifications
        .task {
            await resolveRuntime()
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
            initialFocus: request.initialFocus
        ) { profile, passwordUpdate, folderID in
            try saveProfileEditorDraft(
                profile,
                passwordUpdate: passwordUpdate,
                folderID: folderID,
                original: request.profile
            )
        }
    }

    private func saveProfileEditorDraft(
        _ profile: BrowserProfile,
        passwordUpdate: ProxyPasswordUpdate,
        folderID: UUID?,
        original: BrowserProfile?
    ) throws {
        if original != nil,
           presentedProcessState(for: profile).isRunning
        {
            throw NeAntikError.profileAlreadyRunning
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
        if original == nil {
            telemetry.record(.profileCreated, snapshot: telemetrySnapshot)
        }
        let hadProxy = original?.proxy != nil
        let hasProxy = saved.proxy != nil
        if original?.proxy != saved.proxy ||
            passwordUpdate != .keepExisting
        {
            clearProxyHealth(for: saved.id)
        }
        if hasProxy && !hadProxy {
            telemetry.record(.proxyEnabled, snapshot: telemetrySnapshot)
        } else if hadProxy && !hasProxy {
            telemetry.record(.proxyDisabled, snapshot: telemetrySnapshot)
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsProfileInspector.toggle()
            } label: {
                Label(
                    showsProfileInspector ? "Скрыть сведения" : "Сведения",
                    systemImage: "sidebar.right"
                )
            }
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(selectedProfile == nil)
            .help(
                showsProfileInspector
                    ? "Скрыть сведения о профиле (⌘I)"
                    : "Показать сведения о профиле (⌘I)"
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

    private func beginEditing(
        _ profile: BrowserProfile,
        initialFocus: ProfileEditorField? = nil
    ) {
        guard !processes.runningProfileIDs.contains(profile.id) else {
            localError =
                "Сначала останови профиль. Изменения применяются при следующем запуске."
            return
        }
        editorRequest = EditorRequest(
            profile: profile,
            initialFocus: initialFocus
        )
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
        profileSearchText = ""
        profileRouteFilter = .all
        applyWorkspaceQuery(workspaceQuery.reset(), normalize: false)
        normalizeSelection(preferred: preferredProfileSelection)
    }

    private func applyWorkspaceQuery(
        _ query: WorkspaceQueryState,
        normalize: Bool = true
    ) {
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

    private func createAndOpenFirstProfile() {
        guard runtimeAvailability == .ready else {
            if !isResolvingRuntime {
                Task { await resolveRuntime() }
            }
            return
        }
        guard !isCreatingFirstProfile,
              let profile = FirstProfileBootstrap.makeProfile(
                  existingProfiles: store.profiles
              )
        else {
            return
        }

        isCreatingFirstProfile = true
        defer { isCreatingFirstProfile = false }

        do {
            let saved = try store.upsert(
                profile,
                toFolderID: selectedFolderID
            )
            revealSavedProfile(saved)
            telemetry.record(
                .profileCreated,
                snapshot: telemetrySnapshot
            )
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
            Section("Профили") {
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
                .foregroundStyle(.secondary)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarStatus
        }
    }

    private func profileListPane(
        _ listState: ProfileListViewState
    ) -> some View {
        GeometryReader { proxy in
            let usesWideLayout =
                proxy.size.width >= ProfileRowLayout.minimumWideWidth
            VStack(spacing: 0) {
                profileListHeader(listState)
                Divider()
                runtimeReadinessBanner
                activeFiltersBar

                if store.profiles.isEmpty {
                    FirstProfileOnboardingView(
                        runtimeAvailability: runtimeAvailability,
                        isCreatingProfile: isCreatingFirstProfile,
                        onCreateAndOpen: createAndOpenFirstProfile,
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
                } else {
                    VStack(spacing: 0) {
                        profileTableHeader(usesWideLayout: usesWideLayout)
                        List(selection: profileSelectionBinding) {
                            ForEach(listState.visibleProfiles) { profile in
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
        .navigationTitle("Профили")
    }

    @ViewBuilder
    private func profileTableHeader(
        usesWideLayout: Bool
    ) -> some View {
        if usesWideLayout {
            VStack(spacing: 0) {
                HStack(spacing: ProfileRowLayout.spacing) {
                    Text("Действие")
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
                    Text("Контекст")
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

    private func profileListHeader(
        _ listState: ProfileListViewState
    ) -> some View {
        let bulkProxyAction = BulkProxyActionProjection.resolve(
            visibleProfiles: listState.visibleProfiles,
            processState: { processes.processState(for: $0) },
            isPreparing: { launchPreparingProfileIDs.contains($0) },
            isTesting: { isProxyTestInFlight(profileID: $0) }
        )
        let runningCount = listState.visibleProfiles.lazy.filter {
            processes.runningProfileIDs.contains($0.id)
        }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Профили")
                    .font(.headline)
                Text(
                    "\(listState.visibleProfiles.count) " +
                        profileCountWord(listState.visibleProfiles.count)
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if runningCount > 0 {
                    Label("\(runningCount) запущено", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            if !store.profiles.isEmpty {
                HStack(spacing: 8) {
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
                        ViewThatFits(in: .horizontal) {
                            Label("Ещё", systemImage: "ellipsis.circle")
                            Image(systemName: "ellipsis.circle")
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 28)
                    }
                    .help("Дополнительные действия со списком профилей")
                    .accessibilityLabel(
                        "Дополнительные действия со списком профилей"
                    )

                    profileListViewMenu

                    Button {
                        beginCreatingProfile()
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label("Создать профиль", systemImage: "plus")
                            Image(systemName: "plus")
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help("Создать профиль (⌘N)")
                    .accessibilityLabel("Создать профиль")
                }
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
                    ProgressView(
                        value: Double(bulkProxyProgress.completed),
                        total: Double(max(1, bulkProxyProgress.total))
                    ) {
                        Text(
                            "Проверено \(bulkProxyProgress.completed) из " +
                                "\(bulkProxyProgress.total)"
                        )
                    }
                    .font(.caption)
                    .accessibilityLabel(
                        "Проверено \(bulkProxyProgress.completed) из " +
                            "\(bulkProxyProgress.total)"
                    )
                }
            }
        }
        .padding(12)
    }

    private var profileSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                "Поиск профилей, прокси и заметок",
                text: $profileSearchText
            )
            .textFieldStyle(.plain)
            .focused($profileSearchIsFocused)
            .accessibilityLabel(
                "Поиск профилей, маршрутов, заметок, тегов и папок"
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
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 180, minHeight: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
        } label: {
            ViewThatFits(in: .horizontal) {
                Label("Фильтры", systemImage: "line.3.horizontal.decrease")
                Image(systemName: "line.3.horizontal.decrease")
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 28)
        }
        .help("Сортировка и фильтр подключения")
        .accessibilityLabel("Фильтры и сортировка профилей")
        .accessibilityValue(
            "\(profileListOrdering.title), \(profileRouteFilter.title)"
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
                    Button("Повторить") {
                        Task { await resolveRuntime() }
                    }
                    .controlSize(.small)
                    .help("Повторно проверить браузерный движок")
                    .accessibilityLabel(
                        "Повторно проверить браузерный движок"
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
                } icon: {
                    if let tagTone {
                        Image(systemName: systemImage)
                            .foregroundStyle(
                                Color(profileTagTone: tagTone)
                            )
                    } else {
                        Image(systemName: systemImage)
                    }
                }
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Text(title)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        Button(
            "Изменить…",
            systemImage: "pencil",
            action: commands.edit
        )
        .disabled(!commands.presentation.editIsEnabled)
        Button(
            commands.presentation.launchTitle,
            systemImage: commands.presentation.launchSystemImage,
            action: commands.toggleRunning
        )
        .disabled(!commands.presentation.launchIsEnabled)
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
            "Дублировать",
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
            edit: { beginEditing(profile) },
            togglePinned: { togglePinned(profile) },
            duplicate: { duplicate(profile) },
            moveToFolder: { moveProfile(profile, toFolderID: $0) },
            chooseFolder: {
                profileFolderPickerRequest = ProfileFolderPickerRequest(
                    profileID: profile.id
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
                    beginEditing(profile, initialFocus: .note)
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
                    isCreatingProfile: isCreatingFirstProfile,
                    onCreateAndOpen: createAndOpenFirstProfile,
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

    @ViewBuilder
    private var sidebarStatus: some View {
        if updateChannel.isEnabled || telemetry.isConfigured
        {
            VStack(alignment: .leading, spacing: 7) {
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
        try processes.launch(
            profile: profile,
            runtime: runtime,
            preparationReceipt: preparationReceipt
        )
        guard store.markLaunched(profile.id) else {
            processes.stop(profileID: profile.id)
            throw NeAntikError.profileLaunchStateNotPersisted
        }
        telemetry.record(
            .browserLaunched,
            snapshot: telemetrySnapshot
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
    private func performProxyTest(_ profile: BrowserProfile) async -> Bool {
        guard processes.processState(for: profile.id) == .stopped,
              !launchPreparingProfileIDs.contains(profile.id),
              !isProxyTestInFlight(profileID: profile.id)
        else { return false }
        guard let token = beginProxyTest(for: profile) else { return false }
        return await executeProxyTest(
            profile,
            token: token,
            clearsDedicatedTask: false
        ) != nil
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
        let profiles = bulkProxyActionProjection.profiles
        guard !profiles.isEmpty else { return }
        let runID = UUID()
        bulkProxyTestID = runID
        bulkProxyProgress = BulkProxyProgress(
            completed: 0,
            total: profiles.count
        )
        bulkProxyStatusMessage = nil
        bulkProxyTestTask = Task { @MainActor in
            var completed = 0
            for batchStart in stride(from: 0, to: profiles.count, by: 3) {
                guard !Task.isCancelled else { break }
                let batchEnd = min(batchStart + 3, profiles.count)
                let batch = Array(profiles[batchStart..<batchEnd])
                await withTaskGroup(of: Bool.self) { group in
                    for profile in batch {
                        group.addTask {
                            await performProxyTest(profile)
                        }
                    }
                    for await didFinish in group where didFinish {
                        completed += 1
                        guard bulkProxyTestID == runID else { continue }
                        bulkProxyProgress = BulkProxyProgress(
                            completed: completed,
                            total: profiles.count
                        )
                    }
                }
                guard bulkProxyTestID == runID else { return }
            }
            if bulkProxyTestID == runID {
                if !Task.isCancelled {
                    bulkProxyStatusMessage =
                        "Проверено \(completed) из \(profiles.count)"
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

private enum ProfileRowLayout {
    static let minimumWideWidth: CGFloat = 780
    static let spacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 4
    static let actionWidth: CGFloat = 82
    static let minimumIdentityWidth: CGFloat = 180
    static let statusWidth: CGFloat = 105
    static let minimumRouteWidth: CGFloat = 140
    static let minimumContextWidth: CGFloat = 135
    static let menuWidth: CGFloat = 28
}

private struct ProfileRow<Actions: View>: View {
    let profile: BrowserProfile
    let processState: BrowserProfileProcessState
    let launchAction: BrowserLaunchActionPresentation
    let proxyHealth: ProxyHealthState?
    let isTestingProxy: Bool
    let folderName: String?
    let usesWideLayout: Bool
    let onToggleRunning: () -> Void
    let actions: Actions

    init(
        profile: BrowserProfile,
        processState: BrowserProfileProcessState,
        launchAction: BrowserLaunchActionPresentation,
        proxyHealth: ProxyHealthState?,
        isTestingProxy: Bool,
        folderName: String?,
        usesWideLayout: Bool,
        onToggleRunning: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.profile = profile
        self.processState = processState
        self.launchAction = launchAction
        self.proxyHealth = proxyHealth
        self.isTestingProxy = isTestingProxy
        self.folderName = folderName
        self.usesWideLayout = usesWideLayout
        self.onToggleRunning = onToggleRunning
        self.actions = actions()
    }

    var body: some View {
        let presentation = ProfileRowPresentation.resolve(
            profile: profile,
            processState: processState
        )

        Group {
            if usesWideLayout {
                wideRow(presentation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                compactRow(presentation)
            }
        }
        .padding(.vertical, 7)
        .frame(minHeight: 62)
        .accessibilityElement(children: .contain)
    }

    private func wideRow(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        HStack(spacing: ProfileRowLayout.spacing) {
            launchButton(presentation)
                .frame(width: ProfileRowLayout.actionWidth)
            identityBlock
                .frame(
                    minWidth: ProfileRowLayout.minimumIdentityWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            statusBadge(presentation)
                .frame(
                    width: ProfileRowLayout.statusWidth,
                    alignment: .leading
                )
            routeBlock(presentation)
                .frame(
                    minWidth: ProfileRowLayout.minimumRouteWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            contextBlock(presentation)
                .frame(
                    minWidth: ProfileRowLayout.minimumContextWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            actionsMenu
                .frame(width: ProfileRowLayout.menuWidth)
        }
        .padding(.horizontal, ProfileRowLayout.horizontalPadding)
    }

    private func compactRow(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        HStack(spacing: 10) {
            profileAvatar
            VStack(alignment: .leading, spacing: 4) {
                profileName
                HStack(spacing: 5) {
                    Label(
                        presentation.statusTitle,
                        systemImage: presentation.statusSystemImage
                    )
                    .foregroundStyle(statusColor(for: presentation.statusTone))
                    .layoutPriority(2)
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    routeBlock(presentation)
                        .layoutPriority(1)
                }
                .font(.caption)
                .lineLimit(1)

                if !presentation.noteSummary.isEmpty {
                    noteLabel(presentation.noteSummary)
                } else if folderName != nil || !profile.tags.isEmpty {
                    organizationMetadata
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)
            launchButton(presentation)
            actionsMenu
        }
    }

    private var identityBlock: some View {
        HStack(spacing: 8) {
            profileAvatar
            VStack(alignment: .leading, spacing: 3) {
                profileName
                if folderName != nil || !profile.tags.isEmpty {
                    organizationMetadata
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var profileAvatar: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(hex: profile.colorHex))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: profile.displaySymbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        ProfileAppearance.usesDarkForeground(
                            for: profile.colorHex
                        ) ? Color.black : Color.white
                    )
                if processState.isRunning {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            processState.statusTone == .healthy
                                ? Color.green
                                : Color.orange,
                            lineWidth: 2
                        )
                        .padding(-2)
                }
            }
            .accessibilityHidden(true)
    }

    private var profileName: some View {
        HStack(spacing: 5) {
            Text(profile.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .help(profile.name)
            if profile.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Закреплён")
            }
        }
    }

    private func statusBadge(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        Label(
            presentation.statusTitle,
            systemImage: presentation.statusSystemImage
        )
        .font(.caption)
        .foregroundStyle(statusColor(for: presentation.statusTone))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            statusColor(for: presentation.statusTone).opacity(0.12),
            in: Capsule()
        )
    }

    private func routeBlock(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        HStack(spacing: 4) {
            Label(presentation.routeTitle, systemImage: "network")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(presentation.routeTitle)
            routeHealthIndicator
        }
        .font(.caption)
    }

    @ViewBuilder
    private var routeHealthIndicator: some View {
        if !isTestingProxy,
           let attempt = proxyHealth?.latestAttempt
        {
            let routeContextIsComplete =
                proxyHealth?.hasCompleteRouteContext == true
            Image(
                systemName:
                    routeContextIsComplete
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(routeContextIsComplete ? Color.green : .orange)
            .help(
                "Прокси: \(routeContextIsComplete ? attempt.outcome.userSummary : "Маршрут требует повторной подготовки.") \(attempt.checkedAt.neAntikDisplayDateTime)"
            )
            .accessibilityLabel(
                "Проверка прокси: \(routeContextIsComplete ? attempt.outcome.userSummary : "Маршрут требует повторной подготовки.")"
            )
        }
    }

    private func contextBlock(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !presentation.noteSummary.isEmpty {
                noteLabel(presentation.noteSummary)
            }
            Label(
                profile.lastLaunchedAt.map {
                    "Запуск \($0.neAntikDisplayDateTime)"
                } ?? "Не запускался",
                systemImage: "clock"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    private func noteLabel(_ summary: String) -> some View {
        Label(summary, systemImage: "note.text")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .privacySensitive()
            .accessibilityLabel("Заметка: \(summary)")
    }

    private func launchButton(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        Button(action: onToggleRunning) {
            if presentation.statusTone == .activity,
               !launchAction.isEnabled
            {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                ViewThatFits(in: .horizontal) {
                    Label(
                        ProfileRowPresentation.compactLaunchTitle(
                            launchAction.title
                        ),
                        systemImage: launchAction.systemImage
                    )
                    Image(systemName: launchAction.systemImage)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(minWidth: 28, minHeight: 28)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(launchTint)
        .disabled(!launchAction.isEnabled)
        .help("\(launchAction.help): «\(profile.name)»")
        .accessibilityLabel("\(launchAction.title) профиль \(profile.name)")
        .layoutPriority(2)
    }

    private var actionsMenu: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Действия с профилем «\(profile.name)»")
        .accessibilityLabel("Действия с профилем \(profile.name)")
    }

    private func statusColor(for tone: BrowserProcessStatusTone) -> Color {
        switch tone {
        case .neutral:
            return .secondary
        case .activity, .attention:
            return .orange
        case .healthy:
            return .green
        }
    }

    private var launchTint: Color {
        processState.statusTone == .healthy ? .red : .green
    }

    private var organizationMetadata: some View {
        HStack(spacing: 5) {
            if let folderName {
                Label(folderName, systemImage: "folder")
                    .lineLimit(1)
                    .help(folderName)
                    .layoutPriority(2)
            }
            if let tag = profile.tags.first {
                ProfileTagChip(
                    tag: tag,
                    horizontalPadding: 5,
                    verticalPadding: 1
                )
            }
            if profile.tags.count > 1 {
                Text("+\(profile.tags.count - 1)")
            }
        }
    }
}

struct ProfileDetailView: View {
    @State private var technicalDetailsExpanded = false
    @State private var noteExpanded = false

    let profile: BrowserProfile
    let processState: BrowserProfileProcessState
    let browserDataPath: String
    var folderName: String? = nil
    var environmentSnapshot: ProfileEnvironmentSnapshot? = nil
    var isTestingProxy: Bool = false
    var canCancelProxyTest: Bool = false
    var canRunFingerprintAudit: Bool = false
    let clipboardNotice: String?
    let onCopyProxyUsername: () -> Void
    let onCopyProxyPassword: () -> Void
    var onTestProxy: () -> Void = {}
    var onCancelProxyTest: () -> Void = {}
    var onEditProxy: () -> Void = {}
    var onChangeNote: () -> Void = {}
    var onRunFingerprintAudit: () -> Void = {}

    private var isRunning: Bool {
        processState.isRunning
    }

    private var notePresentation: ProfileNotePresentation {
        ProfileNotePresentation.resolve(profile.note)
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
            profileIcon
            profileTitle

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 22) {
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

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if profile.note.isEmpty {
                        Text("Не добавлена")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Заметка профиля")
                            .accessibilityValue("Не добавлена")
                    } else {
                        Text(profile.note)
                            .lineLimit(
                                notePresentation.shouldOfferExpansion &&
                                    !noteExpanded
                                    ? 3
                                    : nil
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityLabel("Заметка профиля")
                            .accessibilityValue(profile.note)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            noteActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            noteActions
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Заметка", systemImage: "note.text")
            }

            if profile.proxy != nil {
                GroupBox("Прокси") {
                    networkSummary
                        .padding(.vertical, 4)
                }
            }

            if let environmentSnapshot {
                ProfileEnvironmentView(
                    snapshot: environmentSnapshot,
                    hasProxy: profile.proxy != nil,
                    isTestingProxy: isTestingProxy,
                    canTestProxy: processState == .stopped,
                    canCancelProxyTest: canCancelProxyTest,
                    canRunFingerprintAudit: canRunFingerprintAudit,
                    onTestProxy: onTestProxy,
                    onCancelProxy: onCancelProxyTest,
                    onEditProxy: onEditProxy,
                    onRunFingerprintAudit: onRunFingerprintAudit
                )
                .id(environmentSnapshot.profileID)
            } else if profile.proxy == nil {
                GroupBox("Сеть") {
                    networkSummary
                        .padding(.vertical, 4)
                }
            }

            Button {
                technicalDetailsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: technicalDetailsExpanded
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                    Text("Технические сведения")
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                technicalDetailsExpanded ? "Развёрнуто" : "Свёрнуто"
            )
            .accessibilityHint(
                technicalDetailsExpanded
                    ? "Скрывает локальный путь данных профиля"
                    : "Показывает локальный путь данных профиля"
            )

            if technicalDetailsExpanded {
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

            if let lastLaunchedAt = profile.lastLaunchedAt {
                Text(
                    "Последний запуск: \(lastLaunchedAt.neAntikDisplayDateTime)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var noteActions: some View {
        if notePresentation.shouldOfferExpansion {
            Button(noteExpanded ? "Свернуть" : "Показать полностью") {
                noteExpanded.toggle()
            }
            .frame(minHeight: 28)
            .accessibilityValue(
                noteExpanded ? "Заметка раскрыта" : "Краткий вид"
            )
        }

        Button(action: onChangeNote) {
            Label(
                profile.note.isEmpty
                    ? "Добавить заметку…"
                    : "Изменить заметку…",
                systemImage: profile.note.isEmpty ? "plus" : "pencil"
            )
                .frame(minHeight: 28)
        }
        .disabled(isRunning)
        .help(
            isRunning
                ? "Сначала останови профиль"
                : (
                    profile.note.isEmpty
                        ? "Добавить заметку в редакторе профиля"
                        : "Открыть заметку в редакторе профиля"
                )
        )
    }

    private var networkSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let proxy = profile.proxy {
                LabeledContent("Тип", value: proxy.kind.title)
                LabeledContent("Сервер", value: proxy.displayEndpoint)
                LabeledContent(
                    "Авторизация",
                    value: proxy.username.isEmpty ? "Нет" : "Настроена"
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
                if let clipboardNotice {
                    Label(
                        clipboardNotice,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(clipboardNotice)
                }
            } else {
                LabeledContent("Подключение", value: "Без прокси")
            }
        }
    }

    @ViewBuilder
    private var credentialButtons: some View {
        Button(action: onCopyProxyUsername) {
            Label(
                "Копировать логин",
                systemImage: "person.text.rectangle"
            )
            .frame(minHeight: 28)
        }
        .help("Скопировать логин прокси на 60 секунд")
        .accessibilityHint(
            "Буфер обмена очистится через 60 секунд, если его содержимое не изменится."
        )

        Button(action: onCopyProxyPassword) {
            Label("Копировать пароль", systemImage: "key")
                .frame(minHeight: 28)
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
            .accessibilityHidden(true)
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
            .foregroundStyle(processStatusColor)
            if let guidance = processState.guidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(
                        processState.statusTone == .attention
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
            if let folderName {
                Label(folderName, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if profile.isArchived {
                Label("В архиве", systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var processStatusColor: Color {
        switch processState.statusTone {
        case .neutral:
            Color.secondary
        case .activity, .attention:
            Color.orange
        case .healthy:
            Color.green
        }
    }
}
