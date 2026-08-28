import Foundation

/// One value for the three composable facets shown in the workspace.
///
/// Transitions deliberately change only the selected facet. A caller can
/// therefore select a scope, folder, and tag in any order without losing the
/// other two selections.
struct WorkspaceQueryState: Equatable, Sendable {
    static let `default` = WorkspaceQueryState()

    let scope: ProfileListScope
    let folderFilter: ProfileFolderFilter
    let tag: ProfileTagID?

    init(
        scope: ProfileListScope = .active,
        folderFilter: ProfileFolderFilter = .all,
        tag: ProfileTagID? = nil
    ) {
        self.scope = scope
        self.folderFilter = folderFilter
        self.tag = tag
    }

    var selectedFolderID: UUID? {
        guard case let .folder(id) = folderFilter else { return nil }
        return id
    }

    func selecting(scope: ProfileListScope) -> Self {
        Self(scope: scope, folderFilter: folderFilter, tag: tag)
    }

    func selecting(folderFilter: ProfileFolderFilter) -> Self {
        Self(scope: scope, folderFilter: folderFilter, tag: tag)
    }

    func selecting(tag: ProfileTagID?) -> Self {
        Self(scope: scope, folderFilter: folderFilter, tag: tag)
    }

    func removing(_ facet: WorkspaceQueryFacet) -> Self {
        switch facet {
        case .scope:
            selecting(scope: .active)
        case .folder:
            selecting(folderFilter: .all)
        case .tag:
            selecting(tag: nil)
        }
    }

    func reset() -> Self {
        .default
    }
}

enum WorkspaceQueryFacet: Equatable, Sendable {
    case scope
    case folder
    case tag
}

/// Stable focus identity shared by the visual source list and keyboard order.
enum WorkspaceQueryFocus: Hashable, Sendable {
    case allProfiles
    case pinned
    case archive
    case unfiled
    case folder(UUID)
    case tag(ProfileTagID)
}

/// Builds keyboard order from the same preview rules as the visible sources.
/// Hidden groups contribute no focus targets.
enum WorkspaceQueryFocusProjection {
    static func visibleOrder(
        query: WorkspaceQueryState,
        index: ProfileListIndex,
        folders: [ProfileFolder],
        foldersExpanded: Bool,
        tagsExpanded: Bool,
        folderPreviewLimit: Int = ProfileListProjection.defaultPreviewLimit,
        tagPreviewLimit: Int = ProfileListProjection.defaultPreviewLimit
    ) -> [WorkspaceQueryFocus] {
        var order: [WorkspaceQueryFocus] = [
            .allProfiles,
            .pinned,
        ]
        if index.archivedCount > 0 {
            order.append(.archive)
        }

        if foldersExpanded {
            order.append(.unfiled)
            let preview = ProfileListProjection.folderPreview(
                folders,
                selectedID: query.selectedFolderID,
                limit: folderPreviewLimit
            )
            order.append(
                contentsOf: preview.visibleItems.map {
                    .folder($0.id)
                }
            )
        }

        if tagsExpanded {
            let summaries = index.tagSummaries(
                scope: query.scope,
                in: query.folderFilter
            )
            let preview = ProfileListProjection.tagPreview(
                summaries,
                selectedID: query.tag,
                limit: tagPreviewLimit
            )
            order.append(
                contentsOf: preview.visibleItems.map {
                    .tag($0.id)
                }
            )
        }

        return order
    }
}
