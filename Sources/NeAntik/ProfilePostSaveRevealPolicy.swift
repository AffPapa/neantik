import Foundation

/// The smallest workspace transition that makes a newly saved profile visible.
///
/// Creation and duplication may happen while the list is narrowed to pinned,
/// archived, a tag, a folder, or note text that the saved profile does not
/// inherit. Persisting must not silently leave the result behind those facets.
struct ProfilePostSaveRevealDecision: Equatable, Sendable {
    let query: WorkspaceQueryState
    let searchText: String
    let routeFilter: ProfileRouteFilter
    let selectedProfileID: UUID
}

enum ProfilePostSaveRevealPolicy {
    static func resolve(
        savedProfile: BrowserProfile,
        currentQuery: WorkspaceQueryState,
        currentSearchText: String,
        currentRouteFilter: ProfileRouteFilter = .all,
        organization: ProfileOrganizationState
    ) -> ProfilePostSaveRevealDecision {
        let scope = revealedScope(
            for: savedProfile,
            current: currentQuery.scope
        )
        let folderFilter = revealedFolderFilter(
            for: savedProfile.id,
            current: currentQuery.folderFilter,
            organization: organization
        )
        let tag = currentQuery.tag.flatMap { selectedTag in
            savedProfile.tags.contains {
                ProfileTagID(displayName: $0) == selectedTag
            } ? selectedTag : nil
        }
        let query = WorkspaceQueryState(
            scope: scope,
            folderFilter: folderFilter,
            tag: tag
        )
        let searchText = searchReveals(
            savedProfile,
            query: query,
            searchText: currentSearchText,
            organization: organization
        ) ? currentSearchText : ""

        return ProfilePostSaveRevealDecision(
            query: query,
            searchText: searchText,
            routeFilter: revealedRouteFilter(
                for: savedProfile,
                current: currentRouteFilter
            ),
            selectedProfileID: savedProfile.id
        )
    }

    private static func revealedRouteFilter(
        for profile: BrowserProfile,
        current: ProfileRouteFilter
    ) -> ProfileRouteFilter {
        switch current {
        case .all:
            return .all
        case .withProxy where profile.proxy != nil:
            return .withProxy
        case .withoutProxy where profile.proxy == nil:
            return .withoutProxy
        default:
            return .all
        }
    }

    private static func revealedScope(
        for profile: BrowserProfile,
        current: ProfileListScope
    ) -> ProfileListScope {
        if profile.isArchived {
            return .archived
        }
        if current == .pinned, profile.isPinned {
            return .pinned
        }
        return .active
    }

    private static func revealedFolderFilter(
        for profileID: UUID,
        current: ProfileFolderFilter,
        organization: ProfileOrganizationState
    ) -> ProfileFolderFilter {
        let assignedFolderID = organization.folderID(forProfileID: profileID)
            .flatMap { organization.folder(withID: $0)?.id }
        let profileFilter = assignedFolderID.map(ProfileFolderFilter.folder)
            ?? .unfiled

        switch current {
        case .all:
            return .all
        case .unfiled where assignedFolderID == nil:
            return .unfiled
        case let .folder(folderID) where folderID == assignedFolderID:
            return current
        default:
            return profileFilter
        }
    }

    private static func searchReveals(
        _ profile: BrowserProfile,
        query: WorkspaceQueryState,
        searchText: String,
        organization: ProfileOrganizationState
    ) -> Bool {
        let selectedTagName = query.tag.flatMap { selectedTag in
            profile.tags.first {
                ProfileTagID(displayName: $0) == selectedTag
            }
        }
        return ProfileListProjection.filtered(
            [profile],
            searchText: searchText,
            tag: selectedTagName,
            scope: query.scope,
            folderFilter: query.folderFilter,
            organization: organization
        ).contains { $0.id == profile.id }
    }
}
