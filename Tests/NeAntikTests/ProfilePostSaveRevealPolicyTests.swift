import Foundation
import Testing
@testable import NeAntik

struct ProfilePostSaveRevealPolicyTests {
    @Test
    func activeMatchingSearchAndAllFoldersStayUnchanged() {
        let profile = BrowserProfile(
            name: "Client Alpha",
            tags: ["Работа"],
            note: "Контекст"
        )
        let current = WorkspaceQueryState(scope: .active)

        let decision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: current,
            currentSearchText: " alpha ",
            organization: .empty
        )

        #expect(decision.query == current)
        #expect(decision.searchText == " alpha ")
        #expect(decision.selectedProfileID == profile.id)
        expectVisible(profile, decision: decision, organization: .empty)
    }

    @Test
    func unpinnedCloneLeavesPinnedScopeAndClearsNoteOnlySearch() {
        let original = BrowserProfile(
            name: "Source",
            note: "Только в исходной заметке",
            isPinned: true
        )
        let clone = original.duplicated()

        let decision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: clone,
            currentQuery: WorkspaceQueryState(scope: .pinned),
            currentSearchText: "исходной заметке",
            organization: .empty
        )

        #expect(decision.query.scope == .active)
        #expect(decision.searchText.isEmpty)
        expectVisible(clone, decision: decision, organization: .empty)
    }

    @Test
    func pinnedSavedProfileKeepsPinnedScope() {
        let profile = BrowserProfile(name: "Pinned", isPinned: true)
        let current = WorkspaceQueryState(scope: .pinned)

        let decision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: current,
            currentSearchText: "",
            organization: .empty
        )

        #expect(decision.query.scope == .pinned)
        expectVisible(profile, decision: decision, organization: .empty)
    }

    @Test
    func activeProfileLeavesArchiveAndArchivedProfileEntersIt() {
        let active = BrowserProfile(name: "Active")
        let activeDecision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: active,
            currentQuery: WorkspaceQueryState(scope: .archived),
            currentSearchText: "",
            organization: .empty
        )
        #expect(activeDecision.query.scope == .active)
        expectVisible(active, decision: activeDecision, organization: .empty)

        let archived = BrowserProfile(name: "Archived", isArchived: true)
        let archivedDecision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: archived,
            currentQuery: WorkspaceQueryState(scope: .active),
            currentSearchText: "",
            organization: .empty
        )
        #expect(archivedDecision.query.scope == .archived)
        expectVisible(
            archived,
            decision: archivedDecision,
            organization: .empty
        )
    }

    @Test
    func compatibleTagStaysAndIncompatibleTagIsRemoved() {
        let profile = BrowserProfile(name: "Tagged", tags: ["Café"])
        let matching = WorkspaceQueryState(
            tag: ProfileTagID(displayName: "CAFE")
        )
        let matchingDecision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: matching,
            currentSearchText: "",
            organization: .empty
        )
        #expect(matchingDecision.query.tag == matching.tag)
        expectVisible(
            profile,
            decision: matchingDecision,
            organization: .empty
        )

        let incompatible = WorkspaceQueryState(
            tag: ProfileTagID(displayName: "Личный")
        )
        let incompatibleDecision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: incompatible,
            currentSearchText: "",
            organization: .empty
        )
        #expect(incompatibleDecision.query.tag == nil)
        expectVisible(
            profile,
            decision: incompatibleDecision,
            organization: .empty
        )
    }

    @Test
    func matchingFolderStaysAndMismatchedFolderRevealsAssignment() {
        let savedFolderID = UUID()
        let otherFolderID = UUID()
        let profile = BrowserProfile(name: "Folder profile")
        let organization = ProfileOrganizationState(
            folders: [
                ProfileFolder(id: savedFolderID, name: "Saved"),
                ProfileFolder(id: otherFolderID, name: "Other"),
            ],
            assignmentsByProfileID: [profile.id: savedFolderID]
        )

        let matchingDecision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: WorkspaceQueryState(
                folderFilter: .folder(savedFolderID)
            ),
            currentSearchText: "",
            organization: organization
        )
        #expect(
            matchingDecision.query.folderFilter == .folder(savedFolderID)
        )
        expectVisible(
            profile,
            decision: matchingDecision,
            organization: organization
        )

        let mismatchedDecision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: WorkspaceQueryState(
                folderFilter: .folder(otherFolderID)
            ),
            currentSearchText: "",
            organization: organization
        )
        #expect(
            mismatchedDecision.query.folderFilter == .folder(savedFolderID)
        )
        expectVisible(
            profile,
            decision: mismatchedDecision,
            organization: organization
        )
    }

    @Test
    func unfiledProfileMovesFromFolderFilterToUnfiled() {
        let folderID = UUID()
        let profile = BrowserProfile(name: "Unfiled")
        let organization = ProfileOrganizationState(
            folders: [ProfileFolder(id: folderID, name: "Folder")]
        )

        let decision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: WorkspaceQueryState(
                folderFilter: .folder(folderID)
            ),
            currentSearchText: "",
            organization: organization
        )

        #expect(decision.query.folderFilter == .unfiled)
        expectVisible(profile, decision: decision, organization: organization)
    }

    @Test
    func incompatibleRouteFilterIsClearedAfterSave() {
        let direct = BrowserProfile(name: "Direct")
        let proxied = BrowserProfile(
            name: "Proxied",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 8443,
                username: ""
            )
        )

        let directDecision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: direct,
            currentQuery: WorkspaceQueryState(),
            currentSearchText: "",
            currentRouteFilter: .withProxy,
            organization: .empty
        )
        let proxiedDecision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: proxied,
            currentQuery: WorkspaceQueryState(),
            currentSearchText: "",
            currentRouteFilter: .withoutProxy,
            organization: .empty
        )

        #expect(directDecision.routeFilter == .all)
        #expect(proxiedDecision.routeFilter == .all)
        expectVisible(direct, decision: directDecision, organization: .empty)
        expectVisible(proxied, decision: proxiedDecision, organization: .empty)
    }

    @Test
    func compatibleRouteFilterStaysAfterSave() {
        let profile = BrowserProfile(
            name: "Proxied",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 8443,
                username: ""
            )
        )

        let decision = ProfilePostSaveRevealPolicy.resolve(
            savedProfile: profile,
            currentQuery: WorkspaceQueryState(),
            currentSearchText: "",
            currentRouteFilter: .withProxy,
            organization: .empty
        )

        #expect(decision.routeFilter == .withProxy)
        expectVisible(profile, decision: decision, organization: .empty)
    }

    private func expectVisible(
        _ profile: BrowserProfile,
        decision: ProfilePostSaveRevealDecision,
        organization: ProfileOrganizationState
    ) {
        let state = ProfileListViewState(
            profiles: [profile],
            organization: organization,
            query: decision.query,
            searchText: decision.searchText,
            routeFilter: decision.routeFilter
        )
        #expect(state.visibleProfiles.map(\.id) == [profile.id])
    }
}
