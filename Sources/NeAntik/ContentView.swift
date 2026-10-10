import AppKit
import SwiftUI

private struct EditorRequest: Identifiable {
    let id = UUID()
    let profile: BrowserProfile?
    let targetFolderID: UUID?
    let initialFocus: ProfileEditorField?
    let creationTemplate: UserProfileTemplate?

    init(
        profile: BrowserProfile?,
        targetFolderID: UUID? = nil,
        initialFocus: ProfileEditorField? = nil,
        creationTemplate: UserProfileTemplate? = nil
    ) {
        self.profile = profile
        self.targetFolderID = targetFolderID
        self.initialFocus = initialFocus
        self.creationTemplate = creationTemplate
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

private struct SnapshotRestoreRequest: Identifiable {
    let id = UUID()
    let payload: ProfileSnapshotRestorePayload
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

private struct WorkspaceSuccessNotice: Identifiable, Equatable {
    let id: UUID
    let message: String
}

private struct BulkProxyProgress: Equatable {
    let completed: Int
    let total: Int
}

private struct ProfileLifecycleScanID: Hashable {
    let profileID: UUID
    let profileRevision: UInt64
    let lastLaunchedAt: Date?
    let isRunning: Bool
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
    }

    func resolve(
        revision requestedRevision: UInt64,
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState,
        query: WorkspaceQueryState,
        searchText: String
    ) -> ProfileListViewState {
        let currentIndex = resolveIndex(
            revision: requestedRevision,
            profiles: profiles,
            organization: organization
        )
        let key = ViewStateKey(
            revision: requestedRevision,
            query: query,
            searchText: searchText
        )
        if viewStateKey == key, let viewState {
            return viewState
        }
        let resolved = ProfileListViewState(
            index: currentIndex,
            query: query,
            searchText: searchText
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

    @State private var pendingManagerAction: (() -> Void)?
    @State private var showingManagerLibrary = false
    @State private var showingQuickCommands = false
    @State private var proxyDiagnosticProfile: BrowserProfile?
    @State private var cacheMaintenanceProfile: BrowserProfile?
    @State private var browserDataBackupRequest: ProfileBrowserDataBackupRequest?
    @State private var backupRecoveryRequired = false
    @State private var showingBackupRecovery = false
    @State private var selection: UUID?
    @State private var editorRequest: EditorRequest?
    @State private var showingDeleteConfirmation = false
    @State private var showingReleaseFingerprintAudit = false
    @State private var fingerprintAuditRequest: FingerprintAuditRequest?
    @State private var privacyPanelByProfileID:
        [UUID: ProfilePrivacyPanelSnapshot] = [:]
    @State private var siteCompatibilityByProfileID:
        [UUID: SiteCompatibilityAssessment] = [:]
    @State private var lifecycleHealthByProfileID:
        [UUID: ProfileLifecycleHealthSnapshot] = [:]
    @State private var artifactProvenanceByProfileID:
        [UUID: ProfileArtifactProvenanceSnapshot] = [:]
    @State private var bulkProxyImportRequest: BulkProxyImportRequest?
    @State private var transferPassphraseMode:
        ProfileConfigurationPassphraseMode?
    @State private var isImportingProfileConfigurations = false
    @State private var isPreparingProfileExport = false
    @State private var isSavingLocalSnapshot = false
    @State private var isRestoringLocalSnapshot = false
    @State private var pendingSnapshotRestore: SnapshotRestoreRequest?
    @State private var pendingBookmarkImport: BookmarkImportRequest?
    @State private var isImportingBookmarks = false
    @State private var isCreatingBookmarkProfile = false
    @State private var backgroundFileOperationTasks:
        [UUID: Task<Void, Never>] = [:]
    @State private var localError: String?
    @State private var workspaceSuccessNotice: WorkspaceSuccessNotice?
    @State private var workspaceSuccessNoticeTask: Task<Void, Never>?
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
    @State private var preferredProfileSelection: UUID?
    @FocusState private var profileSearchIsFocused: Bool
    @FocusState private var focusedWorkspaceSource: WorkspaceSourceFocus?
    @State private var usesCompactWorkspaceColumns: Bool?
    @State private var foldersSourceExpanded = true
    @State private var tagsSourceExpanded = true
    @State private var showsAllFolders = false
    @State private var showsAllTags = false
    @State private var isCreatingFirstProfile = false
    @State private var profileListResolver = ProfileListStateResolver()

    private var selectedProfile: BrowserProfile? {
        store.profile(withID: selection)
    }

    private var selectedLifecycleScanID: ProfileLifecycleScanID? {
        guard let profile = selectedProfile else { return nil }
        return ProfileLifecycleScanID(
            profileID: profile.id,
            profileRevision: profile.revision,
            lastLaunchedAt: profile.lastLaunchedAt,
            isRunning: processes.runningProfileIDs.contains(profile.id)
        )
    }

    private var selectedProfileCommandSet: ProfileCommandSet {
        guard !isWorkspaceModalPresented,
              let selectedProfile
        else {
            return .unavailable
        }
        return profileCommandSet(for: selectedProfile)
    }

    private var allowsDevelopmentBrowserDataBackup: Bool {
        #if DEBUG
        return Bundle.main.object(forInfoDictionaryKey: "NeAntikBrowserDataBackupDevelopmentEnabled") as? Bool == true &&
            KeychainStore.usesDisposableDevelopmentBackend(environment: NeAntikApplicationEnvironment.resolve(bundleIdentifier: Bundle.main.bundleIdentifier), paths: store.paths,
                fixtureRoot: Bundle.main.object(forInfoDictionaryKey: "NeAntikDevelopmentFixtureRoot") as? String)
        #else
        return false
        #endif
    }

    @ViewBuilder private func browserDataBackupActions(_ commands: ProfileCommandSet, profile: BrowserProfile) -> some View {
        if allowsDevelopmentBrowserDataBackup {
            Button("Создать копию данных…", systemImage: "externaldrive") {
                browserDataBackupRequest = .init(profile: profile, mode: .export)
            }.disabled(!commands.presentation.editIsEnabled || runtime == nil)
            Button("Восстановить данные из копии…", systemImage: "arrow.counterclockwise") {
                browserDataBackupRequest = .init(profile: profile, mode: .restore)
            }.disabled(!commands.presentation.editIsEnabled || runtime == nil)
        }
    }

    private var isWorkspaceModalPresented: Bool {
        showingManagerLibrary || showingQuickCommands ||
            cacheMaintenanceProfile != nil || proxyDiagnosticProfile != nil || browserDataBackupRequest != nil ||
            showingBackupRecovery ||
            editorRequest != nil ||
            folderNameRequest != nil ||
            profileFolderPickerRequest != nil ||
            bulkProxyImportRequest != nil ||
            transferPassphraseMode != nil ||
            isImportingProfileConfigurations ||
            isImportingBookmarks || pendingBookmarkImport != nil ||
            isPreparingProfileExport ||
            isSavingLocalSnapshot ||
            isRestoringLocalSnapshot ||
            pendingSnapshotRestore != nil ||
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
            exportProfiles: exportProfileConfigurations,
            exportSupportBundle: exportRedactedSupportBundle,
            saveSnapshot: saveLocalSnapshot,
            restoreSnapshot: restoreLocalSnapshot,
            importProfiles: importProfileConfigurations,
            importBookmarks: importBookmarks,
            exportEncryptedProfiles: {
                transferPassphraseMode = .export
            },
            importEncryptedProfiles: {
                transferPassphraseMode = .import
            },
            canUndoMetadata: store.metadataUndo != nil,
            undoMetadata: undoMetadata,
            showManagerLibrary: { showingManagerLibrary = true },
            showQuickCommands: { showingQuickCommands = true },
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
            searchText: profileSearchText
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

    private var canRunFingerprintAudit: Bool {
        FingerprintAuditReadinessPolicy.canOffer(
            runtimeReady: runtimePreflight?.isReady == true,
            supportsFingerprintIdentity:
                runtime?.supportsFingerprintIdentity == true,
            activeProfileCount: fingerprintAuditProfiles.count,
            profileStates: fingerprintAuditProfiles.map {
                processes.processState(for: $0.id)
            }
        )
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
                ),
            siteCompatibility: siteCompatibilityByProfileID[
                selectedProfile.id
            ]
        )
    }

    private var selectedProxyCheckSummary: ProxyCheckSummary? {
        guard let profile = selectedProfile, profile.proxy != nil else {
            return nil
        }
        return ProxyCheckSummary(
            record: proxyHealthCoordinator.healthByProfileID[profile.id],
            currentIdentity: ProxyHealthIdentity(profile: profile)
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
            let title = !store.hasTrustedMetadata ? "Не удалось загрузить профили"
                : (!store.hasTrustedOrganization ? "Не удалось загрузить папки" : "Не удалось сохранить данные")
            return WorkspaceAlertPresentation(
                source: .storage,
                title: title,
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

    private var workspaceBase: some View {
        VStack(spacing: 0) {
            if selection == nil, let recoveryNotice = store.recoveryNotice {
                ProfileRecoveryWorkspaceNoticeView(notice: recoveryNotice)
            }
            GeometryReader { proxy in
                workspaceNavigation
                    .onAppear {
                        updateWorkspaceColumns(for: proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        updateWorkspaceColumns(for: width)
                    }
                    .onChange(of: editorRequest?.id) { _, _ in
                        updateWorkspaceColumns(for: proxy.size.width)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let workspaceSuccessNotice {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(
                        workspaceSuccessNotice.message,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Закрыть") {
                        clearWorkspaceSuccessNotice()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var workspaceNavigation: some View {
        let listState = currentProfileListViewState
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            workspaceSources(listState)
                .navigationSplitViewColumnWidth(
                    min: WorkspaceLayout.minimumSourceColumnWidth,
                    ideal: WorkspaceLayout.idealSourceColumnWidth,
                    max: WorkspaceLayout.maximumSourceColumnWidth
                )
        } content: {
            profileListPane(listState)
                .navigationSplitViewColumnWidth(
                    min: WorkspaceLayout.minimumProfileColumnWidth,
                    ideal: WorkspaceLayout.idealProfileColumnWidth,
                    max: WorkspaceLayout.maximumProfileColumnWidth
                )
        } detail: {
            detail
                .frame(
                    minWidth: WorkspaceLayout.minimumDetailColumnWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(isImportingProfileConfigurations || isRestoringLocalSnapshot)
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
        .sheet(isPresented: $showingManagerLibrary, onDismiss: completeManagerSheetAction) {
            ManagerLibrarySheet(library: store.managerLibrary, profile: selectedProfile,
                folderID: selectedProfile.flatMap { store.folderID(forProfileID: $0.id) },
                folders: store.organization.folders, query: workspaceQuery, search: profileSearchText,
                create: { template in
                    editorRequest = EditorRequest(profile: nil,
                        targetFolderID: store.folder(withID: template.folderID)?.id,
                        creationTemplate: template)
                }, apply: applySavedFilter, performAction: { action in
                    pendingManagerAction = action; showingManagerLibrary = false
                })
        }
        .sheet(item: $proxyDiagnosticProfile) { snapshot in
            if let proxy = snapshot.proxy {
                let savedKeychain = keychain
                ProxyDiagnosticSheet(
                    configuration: store.profile(withID: snapshot.id)?.proxy ?? proxy,
                    contextRevision: store.profile(withID: snapshot.id).map { String($0.revision) } ?? "removed",
                    paths: store.paths,
                    readPassword: {
                        try await Task.detached(priority: .utility) {
                            try savedKeychain.proxyPassword(profileID: snapshot.id) ?? ""
                        }.value
                    },
                    snapshotIsCurrent: {
                        try await store.refreshExternalMetadata(force: true)
                        return store.profile(withID: snapshot.id).map {
                            $0.revision == snapshot.revision && $0.proxy == snapshot.proxy
                        } ?? false
                    }
                )
            }
        }
        .sheet(item: $browserDataBackupRequest) { request in
            if let runtime {
                let environment = NeAntikApplicationEnvironment.resolve(bundleIdentifier: Bundle.main.bundleIdentifier)
                let paths = store.paths
                let service = ProfileBrowserDataBackupService(paths: paths, processes: processes,
                    scope: BackupCompatibilityScopeStore.applicationStore(environment: environment, paths: paths), inspectRuntime: {
                        BrowserRuntimeInspector.inspect(executableURL: runtime.executableURL)
                    })
                ProfileBrowserDataBackupSheet(request: request, service: service) {
                    try await store.refreshExternalMetadata(force: true)
                    fingerprintObservationStore.remove(profileID: request.profile.id)
                    privacyPanelByProfileID.removeValue(forKey: request.profile.id)
                    lifecycleHealthByProfileID.removeValue(forKey: request.profile.id)
                    try await proxyHealthCoordinator.remove(profileID: request.profile.id)
                }
            } else { Text("Движок недоступен. Закрой окно и проверь установку NeAntik.").padding(24) }
        }
        .sheet(isPresented: $showingBackupRecovery) {
            if let runtime {
                let environment = NeAntikApplicationEnvironment.resolve(bundleIdentifier: Bundle.main.bundleIdentifier)
                let paths = store.paths
                let service = ProfileBrowserDataBackupService(paths: paths, processes: processes,
                    scope: BackupCompatibilityScopeStore.applicationStore(environment: environment, paths: paths), inspectRuntime: {
                        BrowserRuntimeInspector.inspect(executableURL: runtime.executableURL)
                    })
                ProfileBrowserDataRecoverySheet(service: service) { result in
                    try await store.refreshExternalMetadata(force: true)
                    backupRecoveryRequired = false
                    fingerprintObservationStore.remove(profileID: result.profileID)
                    privacyPanelByProfileID.removeValue(forKey: result.profileID)
                    lifecycleHealthByProfileID.removeValue(forKey: result.profileID)
                    try await proxyHealthCoordinator.remove(profileID: result.profileID)
                }
            } else { Text("Движок недоступен. Проверь установку NeAntik перед восстановлением.").padding(24) }
        }
        .sheet(item: $cacheMaintenanceProfile) { snapshot in
            ProfileCacheMaintenanceSheet(profile: snapshot, paths: store.paths, processes: processes) {
                try await store.refreshExternalMetadata(force: true)
                return store.profile(withID: snapshot.id).map {
                    $0.revision == snapshot.revision && $0.identity == snapshot.identity
                } ?? false
            }
        }
        .sheet(isPresented: $showingQuickCommands, onDismiss: completeManagerSheetAction) {
            ProfileQuickCommandsSheet(commands: quickCommands, profiles: store.profiles, organization: store.organization, profileCommand: quickProfileCommand, performAction: { action in
                pendingManagerAction = action; showingQuickCommands = false
            })
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
        .sheet(item: $transferPassphraseMode) { mode in
            ProfileConfigurationPassphraseSheet(
                mode: mode,
                onSubmit: { passphrase in
                    transferPassphraseMode = nil
                    switch mode {
                    case .export:
                        exportEncryptedProfileConfigurations(
                            passphrase: passphrase
                        )
                    case .import:
                        importEncryptedProfileConfigurations(
                            passphrase: passphrase
                        )
                    }
                },
                onCancel: {
                    transferPassphraseMode = nil
                }
            )
        }
        .sheet(item: $pendingBookmarkImport) { request in
            BookmarkImportPreviewSheet(document: request.document, isCreating: isCreatingBookmarkProfile, onCancel: {
                pendingBookmarkImport = nil
            }, onCreate: { name in
                createProfileFromBookmarks(name: name, request: request)
            })
        }
        .sheet(item: $pendingSnapshotRestore) { request in
            ProfileSnapshotRestorePreviewSheet(
                preview: ProfileSnapshotRestorePreview(
                    payload: request.payload,
                    existingFolderNames: store.organization.folders.map(\.name)
                ),
                isRestoring: isRestoringLocalSnapshot,
                onCancel: {
                    guard !isRestoringLocalSnapshot else { return }
                    pendingSnapshotRestore = nil
                },
                onRestore: { confirmLocalSnapshotRestore(request.payload) }
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
                    privacyPanelByProfileID[report.firstInitial.profileID] =
                        ProfilePrivacyPanelSnapshot.from(
                            capture: report.firstInitial
                        )
                    if let profile = request.auditedProfiles.first(where: {
                        $0.id == report.firstInitial.profileID
                    }), let assessment = SiteCompatibilityAssessment.resolve(
                        report: report,
                        profile: profile,
                        runtime: request.runtime
                    ) {
                        siteCompatibilityByProfileID[profile.id] = assessment
                    }
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
                    store.managerLibrary.record(.delete, .succeeded)
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
            Text("Профиль «\(profile.name)» и его данные браузера будут перемещены в Корзину macOS. Пароль прокси будет удалён из Связки ключей. Возврат файлов из Корзины не восстанавливает профиль полностью. Для обратимого скрытия используй архив.")
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
        }
        .onChange(of: telemetrySnapshot) { _, value in
            telemetry.record(.snapshot, snapshot: value)
        }
    }

    private var workspaceNotifications: some View {
        workspaceStateObservers
        .task {
            while !Task.isCancelled {
                try? await store.refreshExternalMetadata()
                try? await Task.sleep(for: .seconds(2))
            }
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
            Task { @MainActor in
                try? await store.refreshExternalMetadata(force: true)
                processes.reconcile(profiles: store.profiles)
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
        }
    }

    private var workspaceLifecycle: some View {
        workspaceNotifications
        .task(id: store.hasTrustedMetadata) {
            guard allowsDevelopmentBrowserDataBackup else { backupRecoveryRequired = false; return }
            let paths = store.paths
            let trusted = store.hasTrustedMetadata
            let required = await Task.detached(priority: .utility) {
                do { try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory); return false }
                catch { return true }
            }.value
            guard !Task.isCancelled, store.hasTrustedMetadata == trusted else { return }
            backupRecoveryRequired = required
        }
        .task {
            await resolveRuntime()
        }
        .task {
            await recoverDeletedProfileCredentials()
        }
        .task {
            await loadProxyHealth()
        }
        .task(id: selectedLifecycleScanID) {
            guard let profile = selectedProfile else { return }
            do {
                let artifacts = try await ProfileArtifactProvenanceSnapshot
                    .inspectAsync(profileID: profile.id, paths: store.paths)
                guard !Task.isCancelled,
                      selectedProfile?.id == profile.id
                else { return }
                artifactProvenanceByProfileID[profile.id] = artifacts
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      selectedProfile?.id == profile.id
                else { return }
                artifactProvenanceByProfileID[profile.id] = .unavailable
            }
            do {
                let snapshot = try await ProfileLifecycleHealthSnapshot
                    .inspectAsync(
                        profileID: profile.id,
                        lastLaunchedAt: profile.lastLaunchedAt,
                        processState: presentedProcessState(for: profile),
                        paths: store.paths
                    )
                guard !Task.isCancelled,
                      selectedProfile?.id == profile.id
                else { return }
                lifecycleHealthByProfileID[profile.id] = snapshot
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      selectedProfile?.id == profile.id
                else { return }
                lifecycleHealthByProfileID[profile.id] =
                    ProfileLifecycleHealthSnapshot.inspect(
                        profileID: profile.id,
                        lastLaunchedAt: profile.lastLaunchedAt,
                        processState: presentedProcessState(for: profile),
                        paths: store.paths
                    )
            }
        }
        .onDisappear {
            cancelProxyTests()
            cancelBackgroundFileOperations()
            workspaceSuccessNoticeTask?.cancel()
        }
    }

    private func profileEditor(
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
            creationTemplate: request.creationTemplate,
            keychain: keychain,
            folders: store.organization.folders,
            initialFolderID: initialFolderID,
            suggestedTags: suggestedTags,
            paths: store.paths,
            initialFocus: request.initialFocus,
            onClose: {
                editorRequest = nil
                profileSearchIsFocused = true
            }
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
        var succeeded = false
        defer { store.managerLibrary.record(original == nil ? .create : .edit, succeeded ? .succeeded : .failed) }

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
            toFolderID: folderID,
            registerMetadataUndo: ProfileMetadataUndo.editorPreservesSecrets(original: original, passwordUpdate: passwordUpdate)
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
        succeeded = true
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
        ToolbarItem(placement: .automatic) {
            HelpLink(topic: .profiles)
        }
        ToolbarItem(placement: .automatic) {
            Button {
                beginCreatingProfile()
            } label: {
                Label("Новый профиль…", systemImage: "plus")
            }
            .help("Создать профиль (⌘N)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let profile = selectedProfile {
                let processState = presentedProcessState(for: profile)
                let commands = profileCommandSet(
                    for: profile,
                    processState: processState
                )
                Button(action: commands.toggleRunning) {
                    Label(
                        commands.presentation.launchTitle,
                        systemImage:
                            commands.presentation.launchSystemImage
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!commands.presentation.launchIsEnabled)
                .help(commands.presentation.launchHelp)
                .accessibilityLabel(
                    "\(commands.presentation.launchTitle) профиль " +
                        profile.name
                )

                Button(action: commands.edit) {
                    Label("Изменить…", systemImage: "pencil")
                }
                .disabled(!commands.presentation.editIsEnabled)
                .help(
                    commands.presentation.editIsEnabled
                        ? "Изменить профиль"
                        : "Сначала останови профиль"
                )

                Menu {
                    profileOrganizationActions(commands)
                    Divider()
                    Button(action: commands.revealInFinder) {
                        Label(
                            "Показать папку данных в Finder",
                            systemImage: "folder"
                        )
                    }
                    Button("Очистить кэш…", systemImage: "arrow.triangle.2.circlepath", action: commands.clearCache)
                        .disabled(!commands.presentation.editIsEnabled)
                    browserDataBackupActions(commands, profile: profile)
                    Divider()
                    Button(role: .destructive, action: commands.delete) {
                        Label("Удалить профиль", systemImage: "trash")
                    }
                    .disabled(!commands.presentation.deleteIsEnabled)
                } label: {
                    Text("Действия")
                        .fixedSize()
                }
                .help("Другие действия с профилем")
                .accessibilityLabel("Другие действия с профилем")
                .accessibilityHint(
                    "Открывает меню управления выбранным профилем"
                )
            }
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
            organization: store.organization
        )
        profileSearchText = decision.searchText
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

    private func updateWorkspaceColumns(for width: CGFloat) {
        let shouldUseCompactColumns =
            width < WorkspaceLayout.minimumSourceColumnWidth +
                WorkspaceLayout.minimumProfileColumnWidth +
                WorkspaceLayout.minimumDetailColumnWidth
        let desiredVisibility: NavigationSplitViewVisibility =
            shouldUseCompactColumns
                ? (editorRequest == nil ? .doubleColumn : .detailOnly)
                : .all
        guard shouldUseCompactColumns != usesCompactWorkspaceColumns ||
                columnVisibility != desiredVisibility else {
            return
        }
        usesCompactWorkspaceColumns = shouldUseCompactColumns
        columnVisibility = desiredVisibility
    }

    private var quickCommands: [ProfileQuickCommand] {
        [
            ProfileQuickCommand(id: "library", title: "Шаблоны, фильтры и журнал", subtitle: "Локальная библиотека", enabled: true, action: { showingManagerLibrary = true }),
            ProfileQuickCommand(id: "create", title: "Новый профиль", subtitle: "Открыть форму создания", enabled: true, action: beginCreatingProfile),
            ProfileQuickCommand(id: "diagnostics", title: "Безопасная диагностика", subtitle: "Сохранить отчёт без паролей и данных сайтов", enabled: true, action: exportRedactedSupportBundle)
        ]
    }

    private func quickProfileCommand(_ profile: BrowserProfile) -> ProfileQuickCommand {
        ProfileQuickCommand(
            id: profile.id.uuidString,
            title: profile.name,
            subtitle: "Показать в менеджере",
            enabled: true,
            action: {
                guard let current = store.profile(withID: profile.id) else { return }
                revealSavedProfile(current)
            },
            openAction: { openOrShowProfile(profile.id) },
            openEnabled: presentedProcessState(for: profile) != .stopped || profileCommandSet(for: profile).presentation.launchIsEnabled
        )
    }

    private func completeManagerSheetAction() {
        let action = pendingManagerAction
        pendingManagerAction = nil
        profileSearchIsFocused = true
        action?()
    }

    private func openOrShowProfile(_ id: UUID) {
        guard let profile = store.profile(withID: id) else { return }
        revealSavedProfile(profile)
        if presentedProcessState(for: profile) == .stopped {
            guard profileCommandSet(for: profile).presentation.launchIsEnabled else { return }
            launch(profile)
        }
    }

    private func applySavedFilter(_ filter: SavedWorkspaceFilter) {
        let tags = Set(store.profiles.flatMap(\.tags).map { ProfileTagID(displayName: $0) })
        let resolved = filter.resolved(folders: store.organization.folders, tags: tags)
        profileListScope = resolved.query.scope
        selectedFolderFilter = resolved.query.folderFilter
        selectedProfileTag = resolved.query.tag
        profileSearchText = filter.search
        normalizeSelection()
        if resolved.adjusted {
            localError = "Фильтр применён с изменениями: удалённая папка заменена на «Без папки», отсутствующий тег снят."
        }
    }

    private func undoMetadata() {
        guard let token = store.metadataUndo,
              !processes.processState(for: token.profileID).isRunning else {
            localError = "Сначала останови профиль, затем отмени изменение метаданных."
            return
        }
        do {
            let saved = try store.undoLastMetadataChange()
            revealSavedProfile(saved)
            store.managerLibrary.record(.undo, .succeeded)
        } catch {
            store.managerLibrary.record(.undo, .failed)
            localError = error.localizedDescription
        }
    }

    private func beginCreatingProfile() {
        guard !isWorkspaceModalPresented else { return }
        guard store.hasTrustedMetadata else {
            localError = "Сохранённые профили сейчас недоступны. NeAntik не будет заменять их пустым списком."
            return
        }
        editorRequest = EditorRequest(
            profile: nil,
            targetFolderID: selectedFolderID
        )
    }

    private func beginCreatingFolder() {
        guard !isWorkspaceModalPresented else { return }
        folderNameRequest = FolderNameRequest(folder: nil)
    }

    private func runBackgroundFileOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let id = UUID()
        let task = Task { @MainActor in
            await operation()
            backgroundFileOperationTasks[id] = nil
        }
        backgroundFileOperationTasks[id] = task
    }

    private func showWorkspaceSuccessNotice(_ message: String) {
        let notice = WorkspaceSuccessNotice(id: UUID(), message: message)
        workspaceSuccessNoticeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            workspaceSuccessNotice = notice
        }
        workspaceSuccessNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled,
                  workspaceSuccessNotice?.id == notice.id
            else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                workspaceSuccessNotice = nil
            }
        }
    }

    private func clearWorkspaceSuccessNotice() {
        workspaceSuccessNoticeTask?.cancel()
        workspaceSuccessNoticeTask = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            workspaceSuccessNotice = nil
        }
    }

    private func cancelBackgroundFileOperations() {
        for task in backgroundFileOperationTasks.values {
            task.cancel()
        }
        backgroundFileOperationTasks.removeAll()
    }

    private func exportProfileConfigurations() {
        guard !isPreparingProfileExport else { return }
        isPreparingProfileExport = true
        let stoppedProfiles = store.profiles.filter {
            processes.processState(for: $0.id) == .stopped
        }
        let folderNames: [UUID: String] = Dictionary(
            uniqueKeysWithValues: stoppedProfiles.compactMap {
                profile in
                guard let folderID = store.folderID(forProfileID: profile.id),
                      let folder = store.folder(withID: folderID)
                else {
                    return nil
                }
                return (profile.id, folder.name)
            }
        )
        runBackgroundFileOperation {
            defer { isPreparingProfileExport = false }
            do {
                try Task.checkCancellation()
                guard let exportedCount = try await
                    ProfileConfigurationTransferFileCoordinator.export(
                        profiles: stoppedProfiles,
                        folderNameByProfileID: folderNames
                    ) else {
                    return
                }
                try Task.checkCancellation()
                showWorkspaceSuccessNotice(
                    "Экспортировано настроек профилей: \(exportedCount)."
                )
            } catch is CancellationError {
                return
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func importBookmarks() {
        guard !isImportingBookmarks, pendingBookmarkImport == nil else { return }
        isImportingBookmarks = true
        runBackgroundFileOperation {
            defer { isImportingBookmarks = false }
            do {
                guard let document = try await BookmarkImportFileService.select() else { return }
                try Task.checkCancellation()
                pendingBookmarkImport = .init(document: document)
            } catch is CancellationError { return }
            catch { localError = error.localizedDescription }
        }
    }

    private func createProfileFromBookmarks(name: String, request: BookmarkImportRequest) {
        guard !isCreatingBookmarkProfile, pendingBookmarkImport?.id == request.id else { return }
        isCreatingBookmarkProfile = true
        runBackgroundFileOperation {
            defer { isCreatingBookmarkProfile = false }
            do {
                let saved = try await store.createProfileFromBookmarks(name: name, document: request.document)
                pendingBookmarkImport = nil
                revealSavedProfile(saved)
                showWorkspaceSuccessNotice("Профиль создан. Закладок: \(request.document.linkCount).")
            } catch is CancellationError { return }
            catch { localError = error.localizedDescription }
        }
    }

    private func importProfileConfigurations() {
        guard !isImportingProfileConfigurations else { return }
        isImportingProfileConfigurations = true
        runBackgroundFileOperation {
            defer { isImportingProfileConfigurations = false }
            do {
                try Task.checkCancellation()
                guard let document = try await
                    ProfileConfigurationTransferFileCoordinator.import()
                else { return }
                let imported = try await Task.detached(priority: .userInitiated) {
                    try document.makeProfiles()
                }.value
                try Task.checkCancellation()
                let saved = try await store.insertImportedProfilesOffMainActor(
                    imported,
                    folderNames: document.profiles.map(\.folderName)
                )
                if let first = saved.first {
                    revealSavedProfile(first)
                }
                showWorkspaceSuccessNotice(
                    "Импортировано профилей: \(saved.count)."
                )
            } catch is CancellationError {
                return
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func saveLocalSnapshot() {
        guard !isSavingLocalSnapshot else { return }
        let totalProfileCount = store.profiles.count
        let stoppedProfiles = store.profiles.filter {
            processes.processState(for: $0.id) == .stopped
        }
        guard !stoppedProfiles.isEmpty else {
            localError = "Нет остановленных профилей для snapshot."
            return
        }
        let folderNames: [UUID: String] = Dictionary(
            uniqueKeysWithValues: stoppedProfiles.compactMap { profile in
                guard let folderID = store.folderID(forProfileID: profile.id),
                      let folder = store.folder(withID: folderID)
                else { return nil }
                return (profile.id, folder.name)
            }
        )
        isSavingLocalSnapshot = true
        runBackgroundFileOperation {
            defer { isSavingLocalSnapshot = false }
            do {
                try Task.checkCancellation()
                _ = try await ProfileSnapshotFileService.save(
                    profiles: stoppedProfiles,
                    folderNameByProfileID: folderNames,
                    paths: store.paths
                )
                let summary = ProfileSnapshotSaveSummary(
                    savedProfileCount: stoppedProfiles.count,
                    skippedRunningProfileCount:
                        totalProfileCount - stoppedProfiles.count
                )
                showWorkspaceSuccessNotice(summary.statusMessage)
            } catch is CancellationError {
                return
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func restoreLocalSnapshot() {
        guard !isRestoringLocalSnapshot else { return }
        guard processes.runningProfileIDs.isEmpty else {
            localError = "Сначала останови все профили, потом восстанавливай snapshot."
            return
        }
        isRestoringLocalSnapshot = true
        runBackgroundFileOperation {
            defer { isRestoringLocalSnapshot = false }
            do {
                try Task.checkCancellation()
                guard let url = try ProfileSnapshotFileCoordinator.chooseSnapshot(
                    paths: store.paths
                ) else { return }
                let prepared = try await ProfileSnapshotFileService
                    .prepareRestore(from: url, paths: store.paths)
                try Task.checkCancellation()
                guard processes.runningProfileIDs.isEmpty else {
                    localError =
                        "Восстановление отменено: сначала закрой все профили."
                    return
                }
                pendingSnapshotRestore = SnapshotRestoreRequest(payload: prepared)
            } catch is CancellationError {
                return
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func confirmLocalSnapshotRestore(
        _ prepared: ProfileSnapshotRestorePayload
    ) {
        guard !isRestoringLocalSnapshot else { return }
        guard processes.runningProfileIDs.isEmpty else {
            pendingSnapshotRestore = nil
            localError = "Восстановление отменено: сначала закрой все профили."
            return
        }
        isRestoringLocalSnapshot = true
        runBackgroundFileOperation {
            defer { isRestoringLocalSnapshot = false }
            guard processes.runningProfileIDs.isEmpty else {
                pendingSnapshotRestore = nil
                localError = "Восстановление отменено: сначала закрой все профили."
                return
            }
            do {
                let saved = try await store.insertImportedProfilesOffMainActor(
                    prepared.profiles,
                    folderNames: prepared.folderNames
                )
                pendingSnapshotRestore = nil
                if let first = saved.first {
                    revealSavedProfile(first)
                }
                showWorkspaceSuccessNotice(
                    "Восстановлено профилей: \(saved.count), с новыми identity."
                )
            } catch {
                pendingSnapshotRestore = nil
                localError = error.localizedDescription
            }
        }
    }

    private func exportRedactedSupportBundle() {
        do {
            let bundle = try RedactedSupportBundle(
                managerVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String,
                managerBuild: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String,
                runtime: runtime,
                runtimeAvailability: runtimeAvailability,
                profiles: store.profiles,
                folderCount: store.organization.folders.count,
                processStates: store.profiles.map {
                    processes.processState(for: $0.id)
                }
            )
            guard (try RedactedSupportBundleFileCoordinator.export(
                bundle: bundle
            )) != nil else {
                return
            }
            showWorkspaceSuccessNotice("Безопасная диагностика сохранена.")
        } catch {
            localError = error.localizedDescription
        }
    }

    private func exportEncryptedProfileConfigurations(
        passphrase: String
    ) {
        guard !isPreparingProfileExport else { return }
        isPreparingProfileExport = true
        let stoppedProfiles = store.profiles.filter {
            processes.processState(for: $0.id) == .stopped
        }
        let folderNames: [UUID: String] = Dictionary(
            uniqueKeysWithValues: stoppedProfiles.compactMap { profile in
                guard let folderID = store.folderID(forProfileID: profile.id),
                      let folder = store.folder(withID: folderID)
                else {
                    return nil
                }
                return (profile.id, folder.name)
            }
        )
        runBackgroundFileOperation {
            defer { isPreparingProfileExport = false }
            do {
                try Task.checkCancellation()
                guard let exportedCount = try await
                    ProfileConfigurationTransferFileCoordinator
                        .exportEncrypted(
                            profiles: stoppedProfiles,
                            folderNameByProfileID: folderNames,
                            passphrase: passphrase
                        ) else {
                    return
                }
                try Task.checkCancellation()
                showWorkspaceSuccessNotice(
                    "Зашифрованный экспорт сохранён: \(exportedCount) профилей."
                )
            } catch is CancellationError {
                return
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func importEncryptedProfileConfigurations(
        passphrase: String
    ) {
        guard !isImportingProfileConfigurations else { return }
        isImportingProfileConfigurations = true
        runBackgroundFileOperation {
            defer { isImportingProfileConfigurations = false }
            do {
                try Task.checkCancellation()
                guard let document = try await
                    ProfileConfigurationTransferFileCoordinator
                        .importEncrypted(passphrase: passphrase)
                else { return }
                let imported = try await Task.detached(priority: .userInitiated) {
                    try document.makeProfiles()
                }.value
                try Task.checkCancellation()
                let saved = try await store.insertImportedProfilesOffMainActor(
                    imported,
                    folderNames: document.profiles.map(\.folderName)
                )
                if let first = saved.first {
                    revealSavedProfile(first)
                }
                showWorkspaceSuccessNotice(
                    "Импортировано профилей из зашифрованного файла: \(saved.count)."
                )
            } catch is CancellationError {
                return
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func createAndOpenFirstProfile() {
        guard store.hasTrustedMetadata else {
            localError = "Сохранённые профили сейчас недоступны. NeAntik не будет заменять их пустым списком."
            return
        }
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
            try store.moveProfileWithUndo(profile, toFolderID: folderID)
            store.managerLibrary.record(.move, .succeeded)
            normalizeSelection(preferred: profile.id)
        } catch {
            store.managerLibrary.record(.move, .failed)
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
            let saved = try store.mutateProfile(withID: profile.id, registerMetadataUndo: true) {
                $0.isArchived.toggle()
            }
            store.managerLibrary.record(.archive, .succeeded)
            if !saved.isArchived {
                profileListScope = .active
                normalizeSelection(preferred: saved.id)
            } else {
                normalizeSelection()
            }
        } catch {
            store.managerLibrary.record(.archive, .failed)
            localError = error.localizedDescription
        }
    }

    private func duplicate(_ profile: BrowserProfile) {
        do {
            let copy = profile.duplicated()
            let password = try keychain.proxyPassword(
                profileID: profile.id
            )
            let saved = try store.duplicateProfile(
                profile, name: copy.name
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
        VStack(spacing: 0) {
            profileListHeader(listState)
            Divider()
            runtimeReadinessBanner
            if isImportingProfileConfigurations {
                Label("Импортирую профили…", systemImage: "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Выполняется импорт профилей")
            }
            if isRestoringLocalSnapshot {
                Label("Проверяю snapshot…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Проверяю локальный snapshot")
            }
            if isSavingLocalSnapshot {
                Label("Сохраняю snapshot…", systemImage: "externaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Сохраняю локальный snapshot")
            }
            if isPreparingProfileExport {
                Label("Подготавливаю экспорт…", systemImage: "square.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Подготавливаю экспорт профилей")
            }
            activeFiltersBar

            if !store.hasTrustedMetadata {
                ContentUnavailableView {
                    Label("Профили недоступны", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("NeAntik сохранил данные без изменений. Подробности показаны справа.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.profiles.isEmpty {
                ContentUnavailableView {
                    Label(
                        "Нет профилей",
                        systemImage: "person.crop.rectangle.stack"
                    )
                } description: {
                    Text("Первый профиль создаётся в основной области окна.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listState.visibleProfiles.isEmpty {
                ContentUnavailableView {
                    Label(
                        "Ничего не найдено",
                        systemImage: "magnifyingglass"
                    )
                } description: {
                    Text("Измени поиск, папку, раздел или выбранный тег.")
                } actions: {
                    Button("Сбросить все фильтры") {
                        resetProfileFilters()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                            proxyHealth:
                                proxyHealthCoordinator.healthByProfileID[
                                    profile.id
                                ],
                            isTestingProxy:
                                isProxyTestInFlight(profileID: profile.id),
                            folderName: store.folderID(forProfileID: profile.id)
                                .flatMap { listState.index.folderNameByID[$0] },
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
                        )
                        .tag(profile.id)
                        .contextMenu {
                            profileContextMenu(profile, processState: processState)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("Профили")
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(
                    "\(listState.visibleProfiles.count) " +
                        profileCountWord(listState.visibleProfiles.count)
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: beginCreatingProfile) {
                Label("Создать профиль…", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.hasTrustedMetadata || isWorkspaceModalPresented)
            .help("Создать профиль с настройками (⌘N)")

            Button {
                bulkProxyImportRequest = BulkProxyImportRequest(
                    targetFolderID: selectedFolderID
                )
            } label: {
                Label(
                    "Создать профили из списка прокси…",
                    systemImage: "list.bullet.clipboard"
                )
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!store.hasTrustedMetadata || isWorkspaceModalPresented)
            .help("Каждая строка списка станет отдельным профилем")

            profileSearchField

            if bulkProxyTestTask != nil || bulkProxyAction.isVisible {
                Button {
                    toggleBulkProxyTests()
                } label: {
                    Label(
                        bulkProxyTestTask == nil
                            ? "Проверить прокси (\(bulkProxyAction.count))"
                            : "Остановить проверку",
                        systemImage:
                            bulkProxyTestTask == nil
                            ? "checkmark.shield"
                            : "stop.circle"
                    )
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .help(
                    bulkProxyTestTask == nil
                        ? "Проверить доступные остановленные прокси-профили, не более трёх одновременно"
                        : "Остановить массовую проверку прокси"
                )
                .accessibilityLabel(
                    bulkProxyTestTask == nil
                        ? "Проверить прокси доступных профилей: \(bulkProxyAction.count)"
                        : "Остановить массовую проверку прокси"
                )
                if let bulkProxyProgress, bulkProxyTestTask != nil {
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
                } else if let bulkProxyStatusMessage {
                    Text(bulkProxyStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(bulkProxyStatusMessage)
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
                "Поиск профилей, заметок, тегов и папок",
                text: $profileSearchText
            )
            .textFieldStyle(.plain)
            .focused($profileSearchIsFocused)
            .accessibilityLabel("Поиск профилей, заметок, тегов и папок")
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
        .frame(minHeight: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
            profileListScope != .active
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
                }
                Text(title).lineLimit(1)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(background, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Убрать фильтр «\(title)»")
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
        Button("Очистить кэш…", systemImage: "arrow.triangle.2.circlepath", action: commands.clearCache)
            .disabled(!commands.presentation.editIsEnabled)
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
            "Копировать настройки",
            systemImage: "plus.square.on.square",
            action: commands.duplicate
        )
        .help("Новый профиль с отдельной средой: копируются настройки и прокси, без данных сайтов и заметки")
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
            openOrShow: { openOrShowProfile(profile.id) },
            toggleRunning: {
                if launchPreparingProfileIDs.contains(profile.id) {
                    cancelLaunchPreparation(profileID: profile.id)
                } else if processState.isRunning {
                    processes.stop(profileID: profile.id)
                    store.managerLibrary.record(.stop, .requested)
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
            delete: { requestProfileDeletion(profile) },
            clearCache: { cacheMaintenanceProfile = profile }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let request = editorRequest {
            profileEditor(for: request)
                .id(request.id)
        } else if let profile = selectedProfile {
            ProfileDetailView(
                profile: profile,
                processState: presentedProcessState(for: profile),
                browserDataPath: store.paths.browserDataDirectory(for: profile.id).path,
                lifecycleHealth: lifecycleHealthByProfileID[profile.id]
                    ?? ProfileLifecycleHealthSnapshot.inspect(
                        profileID: profile.id,
                        lastLaunchedAt: profile.lastLaunchedAt,
                        processState: presentedProcessState(for: profile),
                        paths: store.paths
                    ),
                privacyPanel: privacyPanelByProfileID[profile.id]
                    ?? .empty,
                artifactProvenance: artifactProvenanceByProfileID[profile.id]
                    ?? .empty,
                runtimeProvenance: RuntimeProvenanceSnapshot.inspect(
                    runtime: runtime,
                    preflight: runtimePreflight
                ),
                recoveryNotice: store.recoveryNotice,
                folderName: store.folderID(forProfileID: profile.id).flatMap {
                    store.folder(withID: $0)?.name
                },
                environmentSnapshot: selectedEnvironmentSnapshot,
                proxyCheckSummary: selectedProxyCheckSummary,
                isTestingProxy: isProxyTestInFlight(profileID: profile.id),
                canCancelProxyTest:
                    proxyTestingProfileIDs.contains(profile.id) ||
                    launchPreparingProfileIDs.contains(profile.id),
                canRunFingerprintAudit: canRunFingerprintAudit,
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
                onCustomProxyDiagnostic: {
                    proxyDiagnosticProfile = profile
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
            if !store.hasTrustedMetadata {
                if allowsDevelopmentBrowserDataBackup && backupRecoveryRequired {
                    ContentUnavailableView {
                        Label("Заверши восстановление данных", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("После прерванной замены данные сохранены. Закрой другие версии NeAntik и проверь журнал восстановления; список откроется после завершения операции.")
                            .frame(maxWidth: 480)
                    } actions: {
                        Button("Проверить восстановление…") { showingBackupRecovery = true }
                            .disabled(runtime == nil || isWorkspaceModalPresented)
                    }
                } else { ProfileStorageUnavailableView() }
            } else if store.profiles.isEmpty {
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
        guard !isImportingProfileConfigurations,
              !isRestoringLocalSnapshot
        else {
            localError = "Дождись завершения импорта или восстановления профилей."
            return
        }
        do {
            try store.validateLaunchSnapshot(profile)
            let runtime = try launchReadyRuntime()
            switch BrowserLaunchPreparationPolicy.resolveForUserStart(
                profile: profile
            ) {
            case .launchImmediately:
                let admissionToken = try ManagerLaunchAdmission.shared.begin(profileID: profile.id)
                var launched = false
                defer { ManagerLaunchAdmission.shared.finish(token: admissionToken, launched: launched) }
                try launchPreparedProfile(
                    profile,
                    runtime: runtime,
                    preparationReceipt: nil
                )
                launched = true
            case .prepareProxyContext:
                // Every browser session gets its own route observation.
                // A manual health check is useful feedback, not authority to
                // reuse a potentially rotating endpoint at Start time.
                let admissionToken = try ManagerLaunchAdmission.shared.begin(profileID: profile.id)
                startAutomaticLaunchPreparation(
                    profile,
                    runtime: runtime,
                    admissionToken: admissionToken
                )
            }
        } catch {
            store.managerLibrary.record(.launch, error is ManagerLaunchAdmissionError ? .deferred : .failed)
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
        store.managerLibrary.record(.launch, .succeeded)
        telemetry.record(
            .browserLaunched,
            snapshot: telemetrySnapshot
        )
    }

    @MainActor
    private func startAutomaticLaunchPreparation(
        _ profile: BrowserProfile,
        runtime: BrowserRuntime,
        admissionToken: UUID
    ) {
        guard launchPreparationTasks[profile.id] == nil else {
            ManagerLaunchAdmission.shared.finish(token: admissionToken)
            return
        }
        guard !isProxyTestInFlight(profileID: profile.id) else {
            ManagerLaunchAdmission.shared.finish(token: admissionToken)
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
            var launched = false
            defer {
                ManagerLaunchAdmission.shared.finish(token: admissionToken, launched: launched)
                if !launched && !Task.isCancelled { store.managerLibrary.record(.launch, .failed) }
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
                clearsDedicatedTask: false,
                commitsLaunchContext: true
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
                launched = true
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

    private func beginFingerprintAudit() {
        guard let runtime, canRunFingerprintAudit
        else {
            localError =
                "Для ручной проверки нужны два остановленных профиля и готовый встроенный браузерный движок. Создавать профиль можно без неё."
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
        clearsDedicatedTask: Bool,
        commitsLaunchContext: Bool = false
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
                        previous: previous,
                        commitsLaunchContext: commitsLaunchContext
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
        previous: ProxyHealthState?,
        commitsLaunchContext: Bool
    ) async throws -> ProxyHealthTestCommit {
        try await ProfileProxyOperations(store: store, keychain: keychain,
            invalidateObservation: { fingerprintObservationStore.remove(profileID: $0) })
            .commit(profileID: profileID, expectedProxy: expectedProxy,
                    expectedRevision: expectedRevision, previous: previous,
                    commitsLaunchContext: commitsLaunchContext)
    }

    @MainActor
    private func toggleBulkProxyTests() {
        if let bulkProxyTestTask {
            let completed = bulkProxyProgress?.completed ?? 0
            let total = bulkProxyProgress?.total ?? 0
            bulkProxyStatusMessage = total > 0
                ? "Проверка остановлена: \(completed) из \(total)"
                : "Проверка остановлена"
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
        if launchPreparationTasks[profileID] != nil { store.managerLibrary.record(.launch, .cancelled) }
        launchPreparationTasks[profileID]?.cancel()
        launchPreparationTasks[profileID] = nil
        launchPreparationTokens[profileID] = nil
        launchPreparingProfileIDs.remove(profileID)
        if proxyTestOperations.cancel(profileID: profileID) {
            proxyTestingProfileIDs.remove(profileID)
        }
    }

    private func presentReleaseFingerprintAuditIfNeeded() {
        guard launchIntent.opensFingerprintAudit else { return }
        let trigger: FingerprintAuditTrigger =
            .explicitReleaseGate
        guard FingerprintAuditTriggerPolicy.shouldAutomaticallyStart(
            trigger: trigger
        ),
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
    let launchAction: BrowserLaunchActionPresentation
    let proxyHealth: ProxyHealthRecord?
    let isTestingProxy: Bool
    let folderName: String?
    var onToggleRunning: () -> Void = {}

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
                                processState.statusTone == .healthy
                                    ? Color.green
                                    : Color.orange,
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
                    if !profile.note.isEmpty {
                        Image(systemName: "note.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Есть заметка")
                            .accessibilityLabel("Есть заметка")
                    }
                    if !isTestingProxy, profile.proxy != nil {
                        let summary = ProxyCheckSummary(
                            record: proxyHealth,
                            currentIdentity: ProxyHealthIdentity(profile: profile)
                        )
                        let routeContextIsComplete =
                            summary.status == .currentSuccess &&
                            proxyHealth?.state.hasCompleteRouteContext == true
                        Image(
                            systemName:
                                routeContextIsComplete
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            routeContextIsComplete
                                ? Color.green
                                : Color.orange
                        )
                        .help(
                            summary.title + (summary.checkedAt.map {
                                " Последняя проверка: \($0.formatted(date: .abbreviated, time: .shortened))."
                            } ?? "")
                        )
                        .accessibilityLabel(
                            summary.title + (summary.checkedAt.map {
                                ". Последняя проверка: \($0.formatted(date: .abbreviated, time: .shortened))."
                            } ?? "")
                        )
                    }
                }
                ViewThatFits(in: .horizontal) {
                    secondaryMetadata(includeTags: true)
                    secondaryMetadata(includeTags: false)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if isTestingProxy && processState == .stopped {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Проверяется прокси")
            } else if processState == .checking && !launchAction.isEnabled {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Профиль подготавливается")
            } else {
                Button(action: onToggleRunning) {
                    Image(systemName: launchAction.systemImage)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    processState.statusTone == .healthy
                        ? Color.red
                        : (
                            processState.isRunning
                                ? Color.orange
                                : Color.accentColor
                        )
                )
                .disabled(!launchAction.isEnabled)
                .help("\(launchAction.help): «\(profile.name)»")
                .accessibilityLabel(
                    "\(launchAction.title) профиль \(profile.name)"
                )
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        .accessibilityElement(children: .contain)
    }

    private func secondaryMetadata(
        includeTags: Bool
    ) -> some View {
        HStack(spacing: 5) {
            if let folderName {
                Label(folderName, systemImage: "folder")
                    .lineLimit(1)
                    .help(folderName)
                    .layoutPriority(2)
            }
            if profile.isArchived {
                Text("В архиве")
                    .lineLimit(1)
                    .layoutPriority(1)
            } else if let proxy = profile.proxy {
                Text(proxy.displayName)
                    .lineLimit(1)
                    .help(proxy.displayName)
                    .layoutPriority(1)
            }
            if includeTags, let tag = profile.tags.first {
                ProfileTagChip(
                    tag: tag,
                    horizontalPadding: 5,
                    verticalPadding: 1
                )
            }
            if includeTags, profile.tags.count > 1 {
                Text("+\(profile.tags.count - 1)")
            }
        }
    }
}

struct ProfileDetailView: View {
    @State private var technicalDetailsExpanded = false
    @State private var noteExpanded = false
    @State private var diagnosticsExpanded = false

    let profile: BrowserProfile
    let processState: BrowserProfileProcessState
    let browserDataPath: String
    var lifecycleHealth: ProfileLifecycleHealthSnapshot = .empty
    var privacyPanel: ProfilePrivacyPanelSnapshot = .empty
    var artifactProvenance: ProfileArtifactProvenanceSnapshot = .empty
    var runtimeProvenance: RuntimeProvenanceSnapshot = .empty
    var recoveryNotice: ProfileRecoveryNotice? = nil
    var folderName: String? = nil
    var environmentSnapshot: ProfileEnvironmentSnapshot? = nil
    var proxyCheckSummary: ProxyCheckSummary? = nil
    var isTestingProxy: Bool = false
    var canCancelProxyTest: Bool = false
    var canRunFingerprintAudit: Bool = false
    let clipboardNotice: String?
    let onCopyProxyUsername: () -> Void
    let onCopyProxyPassword: () -> Void
    var onTestProxy: () -> Void = {}
    var onCancelProxyTest: () -> Void = {}
    var onEditProxy: () -> Void = {}
    var onCustomProxyDiagnostic: () -> Void = {}
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
                    .frame(maxWidth: 900, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                networkSummary
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } label: {
                Label("Подключение", systemImage: "network")
                    .font(.headline)
            }

            if let environmentSnapshot {
                ProfileEnvironmentView(
                    snapshot: environmentSnapshot,
                    hasProxy: profile.proxy != nil,
                    canRunFingerprintAudit: canRunFingerprintAudit,
                    onRunFingerprintAudit: onRunFingerprintAudit
                )
                .id(environmentSnapshot.profileID)
            }

            GroupBox("Основное") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(
                        "Стартовая страница",
                        value: profile.startURL
                    )
                    .textSelection(.enabled)
                    Divider()
                    Label(
                        "Cookies, настройки и данные сайтов хранятся отдельно",
                        systemImage: "person.crop.rectangle.stack"
                    )
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            }

            if !profile.note.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
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
            }

            ProfileDiagnosticsSummaryView(
                lifecycle: lifecycleHealth,
                privacyPanel: privacyPanel,
                artifactProvenance: artifactProvenance,
                runtimeProvenance: runtimeProvenance,
                isExpanded: $diagnosticsExpanded
            )

            if diagnosticsExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ProfileLifecycleHealthView(
                        snapshot: lifecycleHealth,
                        recoveryNotice: recoveryNotice
                    )
                    ProfilePrivacyPanelView(snapshot: privacyPanel)
                    ProfileArtifactProvenanceView(
                        snapshot: artifactProvenance
                    )
                    RuntimeProvenanceCardView(snapshot: runtimeProvenance)
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
            Label("Изменить заметку…", systemImage: "pencil")
                .frame(minHeight: 28)
        }
        .disabled(isRunning)
        .help(
            isRunning
                ? "Сначала останови профиль"
                : "Открыть заметку в редакторе профиля"
        )
    }

    private var networkSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let proxy = profile.proxy {
                Label {
                    Text("\(proxy.kind.title) · \(proxy.displayEndpoint)")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "network")
                }
                .font(.body.weight(.medium))
                .accessibilityLabel(
                    "Прокси \(proxy.kind.title), сервер \(proxy.displayEndpoint)"
                )

                Text(
                    proxy.username.isEmpty
                        ? "Без авторизации"
                        : "Авторизация настроена · пароль в Связке ключей"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let proxyCheckSummary {
                    ProxyCheckSummaryView(summary: proxyCheckSummary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        connectionActions(hasCredentials: !proxy.username.isEmpty)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        connectionActions(hasCredentials: !proxy.username.isEmpty)
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
                Label("Без прокси · прямое подключение", systemImage: "network")
                    .font(.body)
            }
        }
    }

    @ViewBuilder
    private func connectionActions(hasCredentials: Bool) -> some View {
        Button(
            action: isTestingProxy && canCancelProxyTest
                ? onCancelProxyTest : onTestProxy
        ) {
            Label(
                isTestingProxy
                    ? (
                        canCancelProxyTest
                            ? "Отменить проверку"
                            : "Проверка в другом окне…"
                    )
                    : "Проверить прокси",
                systemImage: isTestingProxy
                    ? "stop.circle"
                    : "network.badge.shield.half.filled"
            )
        }
        .buttonStyle(.bordered)
        .disabled(
            (isTestingProxy && !canCancelProxyTest) ||
                (!isTestingProxy && processState != .stopped)
        )
        .help(
            isTestingProxy
                ? (
                    canCancelProxyTest
                        ? "Отменить проверку прокси"
                        : "Проверка запущена в другом окне NeAntik"
                )
                : (
                    processState == .stopped
                        ? "Проверяет доступность и контекст выхода прокси"
                        : "Сначала останови профиль"
                )
        )

        Button(action: onEditProxy) {
            Label("Изменить прокси…", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.borderedProminent)
        .disabled(processState != .stopped)
        .help(
            processState == .stopped
                ? "Исправить адрес, порт, логин или пароль прокси"
                : "Сначала останови профиль"
        )
        .accessibilityHint("Открывает настройки прокси текущего профиля")

        Button("Свой адрес диагностики…", action: onCustomProxyDiagnostic)
            .buttonStyle(.bordered)
            .disabled(processState != .stopped || isTestingProxy)
            .help("Ручной запрос через твой HTTPS-сервис; не меняет геоконтекст и не измеряет маршрут Chromium")

        if hasCredentials {
            Menu {
                credentialButtons
            } label: {
                Label("Учётные данные", systemImage: "key")
            }
            .menuStyle(.borderlessButton)
            .help("Скопировать логин или пароль прокси")
        }
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
