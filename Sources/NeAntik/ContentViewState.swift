import Foundation

struct RecoveryProfileID: Identifiable, Equatable {
    let id: UUID
}

struct EditorRequest: Identifiable {
    let initialFocus: ProfileEditorField?
    let id = UUID()
    let profile: BrowserProfile?
    let targetFolderID: UUID?
    let openedProcessState: BrowserProfileProcessState?

    init(
        initialFocus: ProfileEditorField? = nil,
        profile: BrowserProfile?,
        targetFolderID: UUID? = nil,
        openedProcessState: BrowserProfileProcessState? = nil
    ) {
        self.initialFocus = initialFocus
        self.profile = profile
        self.targetFolderID = targetFolderID
        self.openedProcessState = openedProcessState
    }
}

struct QuickCreateRequest: Identifiable {
    let id = UUID()
    let targetFolderID: UUID?
}

/// One immutable presentation snapshot; selecting another row cannot retarget it.
struct WorkspaceSheetRequest: Identifiable {
    enum Destination {
        case editor(EditorRequest)
        case quickCreate(QuickCreateRequest)
        case duplication(ProfileDuplicationRequest)
        case note(BrowserProfile)
        case folderName(ProfileFolder?)
        case folderPicker(Set<UUID>)
        case batchTags(Set<UUID>)
        case proxyImport(targetFolderID: UUID?)
        case cookieImport(BrowserProfile)
        case readiness
        case fingerprintAudit(FingerprintAuditRequest)
    }

    let id = UUID()
    let destination: Destination

    var isReadiness: Bool {
        Self.isReadiness(destination)
    }

    private static func isReadiness(_ destination: Destination) -> Bool {
        if case .readiness = destination { return true }
        return false
    }

    static func canPresent(
        _ destination: Destination,
        hasBlockingModal: Bool,
        hasWorkspaceAlert: Bool,
        recoveringWorkspaceAlert: Bool = false
    ) -> Bool {
        !hasBlockingModal && (
            !hasWorkspaceAlert || (recoveringWorkspaceAlert && isReadiness(destination))
        )
    }
}

enum WorkspaceBatchUndo: Equatable {
    case metadata(ProfileMetadataBatchUndoReceipt)
    case folder(ProfileFolderBatchUndoReceipt)

    var affectedCount: Int {
        switch self {
        case let .metadata(receipt): receipt.affectedCount
        case let .folder(receipt): receipt.affectedCount
        }
    }
}

typealias WorkspaceSourceFocus = WorkspaceQueryFocus

struct WorkspaceAlertPresentation: Identifiable {
    enum Source: Hashable {
        case local
        case process
        case storage
    }

    let source: Source
    let title: String
    let message: String

    var id: Source { source }

    var offersReadinessRecovery: Bool {
        switch source {
        case .process, .storage:
            true
        case .local:
            false
        }
    }
}

struct ClipboardNotice: Equatable {
    let profileID: UUID
    let message: String
}

struct LaunchPreparationFailure: Identifiable, Equatable {
    let profileID: UUID
    let message: String
    var title: String = "Прокси не готов"
    var offersProxyEdit = true

    var id: UUID { profileID }
}

@MainActor
final class ProfileListStateResolver {
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
