import Foundation
import Testing
@testable import NeAntik

struct WorkspaceQueryStateTests {
    @Test
    func selectingAnyScopePreservesEveryFolderAndTagCombination() {
        for initialScope in ProfileListScope.allCases {
            for folder in Self.folderFilters {
                for tag in Self.tags {
                    let initial = WorkspaceQueryState(
                        scope: initialScope,
                        folderFilter: folder,
                        tag: tag
                    )

                    for selectedScope in ProfileListScope.allCases {
                        let result = initial.selecting(scope: selectedScope)

                        #expect(result.scope == selectedScope)
                        #expect(result.folderFilter == folder)
                        #expect(result.tag == tag)
                    }
                }
            }
        }
    }

    @Test
    func selectingAnyFolderPreservesEveryScopeAndTagCombination() {
        for scope in ProfileListScope.allCases {
            for initialFolder in Self.folderFilters {
                for tag in Self.tags {
                    let initial = WorkspaceQueryState(
                        scope: scope,
                        folderFilter: initialFolder,
                        tag: tag
                    )

                    for selectedFolder in Self.folderFilters {
                        let result = initial.selecting(
                            folderFilter: selectedFolder
                        )

                        #expect(result.scope == scope)
                        #expect(result.folderFilter == selectedFolder)
                        #expect(result.tag == tag)
                    }
                }
            }
        }
    }

    @Test
    func selectingOptionalTagPreservesEveryScopeAndFolderCombination() {
        for scope in ProfileListScope.allCases {
            for folder in Self.folderFilters {
                for initialTag in Self.tags {
                    let initial = WorkspaceQueryState(
                        scope: scope,
                        folderFilter: folder,
                        tag: initialTag
                    )

                    for selectedTag in Self.tags {
                        let result = initial.selecting(tag: selectedTag)

                        #expect(result.scope == scope)
                        #expect(result.folderFilter == folder)
                        #expect(result.tag == selectedTag)
                    }
                }
            }
        }
    }

    @Test
    func removingOneFacetPreservesTheOtherTwoFacets() {
        for scope in ProfileListScope.allCases {
            for folder in Self.folderFilters {
                for tag in Self.tags {
                    let initial = WorkspaceQueryState(
                        scope: scope,
                        folderFilter: folder,
                        tag: tag
                    )

                    let withoutScope = initial.removing(.scope)
                    #expect(withoutScope.scope == .active)
                    #expect(withoutScope.folderFilter == folder)
                    #expect(withoutScope.tag == tag)

                    let withoutFolder = initial.removing(.folder)
                    #expect(withoutFolder.scope == scope)
                    #expect(withoutFolder.folderFilter == .all)
                    #expect(withoutFolder.tag == tag)

                    let withoutTag = initial.removing(.tag)
                    #expect(withoutTag.scope == scope)
                    #expect(withoutTag.folderFilter == folder)
                    #expect(withoutTag.tag == nil)
                }
            }
        }
    }

    @Test
    func resetReturnsTheSingleDefaultQuery() {
        for scope in ProfileListScope.allCases {
            for folder in Self.folderFilters {
                for tag in Self.tags {
                    let state = WorkspaceQueryState(
                        scope: scope,
                        folderFilter: folder,
                        tag: tag
                    )

                    #expect(state.reset() == .default)
                }
            }
        }
    }

    @Test
    func collapsedGroupsExcludeEveryHiddenFolderAndTagFocus() {
        let fixture = Self.makeFocusFixture()

        let order = WorkspaceQueryFocusProjection.visibleOrder(
            query: fixture.query,
            index: fixture.index,
            folders: fixture.folders,
            foldersExpanded: false,
            tagsExpanded: false,
            folderPreviewLimit: 2,
            tagPreviewLimit: 1
        )

        #expect(order == [.allProfiles, .pinned, .archive])
    }

    @Test
    func expandedFolderGroupIncludesUnfiledAndOnlyFolderPreviewItems() {
        let fixture = Self.makeFocusFixture()

        let order = WorkspaceQueryFocusProjection.visibleOrder(
            query: fixture.query,
            index: fixture.index,
            folders: fixture.folders,
            foldersExpanded: true,
            tagsExpanded: false,
            folderPreviewLimit: 2,
            tagPreviewLimit: 1
        )

        #expect(
            order == [
                .allProfiles,
                .pinned,
                .archive,
                .unfiled,
                .folder(fixture.alphaFolderID),
                .folder(fixture.selectedFolderID),
            ]
        )
    }

    @Test
    func expandedTagGroupIncludesOnlyTagPreviewItemsForComposedQuery() {
        let fixture = Self.makeFocusFixture()

        let order = WorkspaceQueryFocusProjection.visibleOrder(
            query: fixture.query,
            index: fixture.index,
            folders: fixture.folders,
            foldersExpanded: false,
            tagsExpanded: true,
            folderPreviewLimit: 2,
            tagPreviewLimit: 1
        )

        #expect(
            order == [
                .allProfiles,
                .pinned,
                .archive,
                .tag(fixture.selectedTagID),
            ]
        )
    }

    @Test
    func fullyExpandedOrderCombinesBothVisiblePreviews() {
        let fixture = Self.makeFocusFixture()

        let order = WorkspaceQueryFocusProjection.visibleOrder(
            query: fixture.query,
            index: fixture.index,
            folders: fixture.folders,
            foldersExpanded: true,
            tagsExpanded: true,
            folderPreviewLimit: 2,
            tagPreviewLimit: 1
        )

        #expect(
            order == [
                .allProfiles,
                .pinned,
                .archive,
                .unfiled,
                .folder(fixture.alphaFolderID),
                .folder(fixture.selectedFolderID),
                .tag(fixture.selectedTagID),
            ]
        )
    }

    @Test
    func archiveFocusIsAbsentWhenNoArchivedProfilesExist() {
        let profile = BrowserProfile(name: "Active", tags: ["Tag"])
        let index = ProfileListIndex(
            profiles: [profile],
            organization: .empty
        )

        let order = WorkspaceQueryFocusProjection.visibleOrder(
            query: .default,
            index: index,
            folders: [],
            foldersExpanded: true,
            tagsExpanded: true
        )

        #expect(
            order == [
                .allProfiles,
                .pinned,
                .unfiled,
                .tag(ProfileTagID(displayName: "Tag")),
            ]
        )
    }

    @Test
    func unlimitedPreviewIncludesEverySortedFolderAndTag() {
        let fixture = Self.makeFocusFixture()

        let order = WorkspaceQueryFocusProjection.visibleOrder(
            query: fixture.query,
            index: fixture.index,
            folders: fixture.folders,
            foldersExpanded: true,
            tagsExpanded: true,
            folderPreviewLimit: .max,
            tagPreviewLimit: .max
        )

        #expect(order.filter(\.isFolder).count == fixture.folders.count)
        #expect(
            order.filter(\.isTag).count ==
                fixture.index.tagSummaries(
                    scope: fixture.query.scope,
                    in: fixture.query.folderFilter
                ).count
        )
    }

    private static let firstFolderID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    private static let secondFolderID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    private static let selectedTagID = ProfileTagID(displayName: "Zulu")

    private static let folderFilters: [ProfileFolderFilter] = [
        .all,
        .unfiled,
        .folder(firstFolderID),
        .folder(secondFolderID),
    ]

    private static let tags: [ProfileTagID?] = [nil, selectedTagID]

    private static func makeFocusFixture() -> FocusFixture {
        let alphaFolderID = UUID(
            uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        )!
        let middleFolderID = UUID(
            uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        )!
        let selectedFolderID = UUID(
            uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        )!
        let folders = [
            ProfileFolder(id: selectedFolderID, name: "Zulu"),
            ProfileFolder(id: middleFolderID, name: "Middle"),
            ProfileFolder(id: alphaFolderID, name: "Alpha"),
        ]
        let active = BrowserProfile(
            name: "Active",
            tags: ["Alpha", "Zulu"],
            isPinned: true
        )
        let archived = BrowserProfile(
            name: "Archived",
            tags: ["Archive"],
            isArchived: true
        )
        let organization = ProfileOrganizationState(
            folders: folders,
            assignmentsByProfileID: [
                active.id: selectedFolderID,
                archived.id: alphaFolderID,
            ]
        )
        let index = ProfileListIndex(
            profiles: [active, archived],
            organization: organization
        )
        let selectedTagID = ProfileTagID(displayName: "Zulu")
        return FocusFixture(
            query: WorkspaceQueryState(
                scope: .pinned,
                folderFilter: .folder(selectedFolderID),
                tag: selectedTagID
            ),
            index: index,
            folders: folders,
            alphaFolderID: alphaFolderID,
            selectedFolderID: selectedFolderID,
            selectedTagID: selectedTagID
        )
    }
}

private struct FocusFixture {
    let query: WorkspaceQueryState
    let index: ProfileListIndex
    let folders: [ProfileFolder]
    let alphaFolderID: UUID
    let selectedFolderID: UUID
    let selectedTagID: ProfileTagID
}

private extension WorkspaceQueryFocus {
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var isTag: Bool {
        if case .tag = self { return true }
        return false
    }
}
