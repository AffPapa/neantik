import Foundation

enum ProfileListSort: String, CaseIterable, Identifiable, Sendable {
    case name, recentlyOpened, newest
    var id: Self { self }

    func sorted(_ profiles: [BrowserProfile]) -> [BrowserProfile] {
        guard self != .name else { return profiles }
        return profiles.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            switch self {
            case .name: break
            case .recentlyOpened:
                if lhs.lastLaunchedAt != rhs.lastLaunchedAt {
                    guard let left = lhs.lastLaunchedAt else { return false }
                    guard let right = rhs.lastLaunchedAt else { return true }
                    return left > right
                }
            case .newest:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            }
            return ProfileListProjection.areInIncreasingOrder(lhs, rhs)
        }
    }
}

/// Immutable data needed to render and normalize the profile list once.
///
/// Reusing `index` for search-only changes avoids rebuilding folder and tag
/// counts while preserving the same filtering semantics as the workspace.
/// The default name order preserves the canonical ordering supplied by ProfileStore.
struct ProfileListViewState: Equatable, Sendable {
    let index: ProfileListIndex
    let query: WorkspaceQueryState
    let searchText: String
    let sort: ProfileListSort
    let visibleProfiles: [BrowserProfile]
    let tagSummaries: [ProfileTagSummary]
    let selectedTagDisplayName: String?
    let availableTags: [String]

    init(
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState,
        query: WorkspaceQueryState,
        searchText: String,
        sort: ProfileListSort = .name
    ) {
        self.init(
            index: ProfileListIndex(
                profiles: profiles,
                organization: organization
            ),
            query: query,
            searchText: searchText,
            sort: sort
        )
    }

    init(
        index: ProfileListIndex,
        query: WorkspaceQueryState,
        searchText: String,
        sort: ProfileListSort = .name
    ) {
        let selectedTagDisplayName = query.tag.flatMap(index.displayName)
        let tagSummaries = index.tagSummaries(
            scope: query.scope,
            in: query.folderFilter
        )

        self.index = index
        self.query = query
        self.searchText = searchText
        self.sort = sort
        self.tagSummaries = tagSummaries
        self.selectedTagDisplayName = selectedTagDisplayName
        availableTags = tagSummaries.map(\.name)
        visibleProfiles = sort.sorted(index.filtered(
            searchText: searchText,
            tag: selectedTagDisplayName,
            scope: query.scope,
            folderFilter: query.folderFilter
        ))
    }
}
