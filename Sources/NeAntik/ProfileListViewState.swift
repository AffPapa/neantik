import Foundation

/// Immutable data needed to render and normalize the profile list once.
///
/// Reusing `index` for search-only changes avoids rebuilding folder and tag
/// counts while preserving the same filtering semantics as the workspace.
struct ProfileListViewState: Equatable, Sendable {
    let index: ProfileListIndex
    let query: WorkspaceQueryState
    let searchText: String
    let visibleProfiles: [BrowserProfile]
    let tagSummaries: [ProfileTagSummary]
    let selectedTagDisplayName: String?
    let availableTags: [String]

    init(
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState,
        query: WorkspaceQueryState,
        searchText: String
    ) {
        self.init(
            index: ProfileListIndex(
                profiles: profiles,
                organization: organization
            ),
            query: query,
            searchText: searchText
        )
    }

    init(
        index: ProfileListIndex,
        query: WorkspaceQueryState,
        searchText: String
    ) {
        let selectedTagDisplayName = query.tag.flatMap(index.displayName)
        let tagSummaries = index.tagSummaries(
            scope: query.scope,
            in: query.folderFilter
        )

        self.index = index
        self.query = query
        self.searchText = searchText
        self.tagSummaries = tagSummaries
        self.selectedTagDisplayName = selectedTagDisplayName
        availableTags = tagSummaries.map(\.name)
        visibleProfiles = index.filtered(
            searchText: searchText,
            tag: selectedTagDisplayName,
            scope: query.scope,
            folderFilter: query.folderFilter
        )
    }
}
