import Foundation
import Testing
@testable import NeAntik

struct ProfileListProjectionTests {
    @Test
    func sortPreferencePersistsAndFallsBackToNameForUnknownValues() throws {
        let suite = "NeAntik.ProfileListSortPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ProfileListSortPreference.load(from: defaults) == .name)

        for sort in ProfileListSort.allCases {
            ProfileListSortPreference.save(sort, to: defaults)
            #expect(ProfileListSortPreference.load(from: defaults) == sort)
        }

        defaults.set("unsupported-order", forKey: ProfileListSortPreference.key)
        #expect(ProfileListSortPreference.load(from: defaults) == .name)
    }

    @Test
    func sortKeepsPinsFirstAndUnopenedLastWithStableTies() {
        let t = Date(timeIntervalSince1970: 1_000)
        let pinned = BrowserProfile(name: "Pinned", isPinned: true, createdAt: t)
        let never = BrowserProfile(name: "Never", createdAt: t.addingTimeInterval(3))
        let old = BrowserProfile(name: "Old", createdAt: t.addingTimeInterval(1), lastLaunchedAt: t)
        let recent = BrowserProfile(name: "Recent", createdAt: t.addingTimeInterval(2), lastLaunchedAt: t.addingTimeInterval(1))
        let tied = BrowserProfile(name: "A tie", createdAt: t, lastLaunchedAt: t.addingTimeInterval(1))
        // The production store supplies the index in its canonical name order.
        let profiles = [never, old, recent, pinned, tied]
            .sorted(by: ProfileListProjection.areInIncreasingOrder)
        func ordered(_ sort: ProfileListSort) -> [UUID] {
            ProfileListViewState(profiles: profiles, organization: .empty, query: .default,
                                 searchText: "", sort: sort).visibleProfiles.map(\.id)
        }
        #expect(ordered(.recentlyOpened) == [pinned.id, tied.id, recent.id, old.id, never.id])
        #expect(ordered(.newest) == [pinned.id, never.id, recent.id, old.id, tied.id])
        #expect(ordered(.name) == [pinned.id, tied.id, never.id, old.id, recent.id])
        let searched = ProfileListViewState(profiles: profiles, organization: .empty,
                                            query: .default, searchText: "recent",
                                            sort: .recentlyOpened)
        #expect(searched.visibleProfiles.map(\.id) == [recent.id])
    }

    @Test
    func sortRespectsFolderAndTagAndBreaksEqualDatesByID() throws {
        let t = Date(timeIntervalSince1970: 1_000)
        let folder = UUID()
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = BrowserProfile(id: firstID, name: "Same", tags: ["Work"], createdAt: t, lastLaunchedAt: t)
        let second = BrowserProfile(id: secondID, name: "Same", tags: ["Work"], createdAt: t, lastLaunchedAt: t)
        let otherFolder = BrowserProfile(name: "Other", tags: ["Work"], createdAt: t)
        let otherTag = BrowserProfile(name: "Other tag", tags: ["Personal"], createdAt: t)
        let profiles = [second, otherFolder, first, otherTag].sorted(by: ProfileListProjection.areInIncreasingOrder)
        let organization = ProfileOrganizationState(
            folders: [ProfileFolder(id: folder, name: "Work")],
            assignmentsByProfileID: [first.id: folder, second.id: folder, otherTag.id: folder]
        )
        let query = WorkspaceQueryState(folderFilter: .folder(folder), tag: ProfileTagID(displayName: "Work"))
        for sort in [ProfileListSort.name, .recentlyOpened, .newest] {
            let state = ProfileListViewState(profiles: profiles, organization: organization,
                                             query: query, searchText: "", sort: sort)
            #expect(state.visibleProfiles.map(\.id) == [firstID, secondID])
        }
    }
    @Test
    func sidebarFixedLabelsUseEnglishResourcesAndPreserveRussian() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let english = try #require(Bundle(path: root.appendingPathComponent("Resources/en.lproj").path))
        let russian = try #require(Bundle(path: root.appendingPathComponent("Resources/ru.lproj").path))
        let expected: [(ProfileSidebarLabel, String)] = [
            (.allProfiles, "All Profiles"), (.pinned, "Pinned"), (.archive, "Archive"),
            (.folders, "Folders"), (.unfiled, "Unfiled"), (.tags, "Tags")
        ]
        #expect(expected.count == ProfileSidebarLabel.allCases.count)
        for (label, translation) in expected {
            #expect(label.localized(bundle: english) == translation)
            #expect(label.localized(bundle: russian) == label.rawValue)
        }
    }

    @Test
    func foldedTagIdentitySurvivesDisplayRepresentativeFlip() {
        let accentedFirst = ProfileListIndex(
            profiles: [
                BrowserProfile(name: "A", tags: ["Café"]),
                BrowserProfile(name: "B", tags: ["cafe"]),
            ],
            organization: .empty
        ).tagSummaries(in: .all)
        let plainFirst = ProfileListIndex(
            profiles: [
                BrowserProfile(name: "B", tags: ["cafe"]),
                BrowserProfile(name: "A", tags: ["Café"]),
            ],
            organization: .empty
        ).tagSummaries(in: .all)

        #expect(accentedFirst.count == 1)
        #expect(plainFirst.count == 1)
        #expect(accentedFirst[0].name == "Café")
        #expect(plainFirst[0].name == "cafe")
        #expect(accentedFirst[0].id == plainFirst[0].id)
        #expect(accentedFirst[0].count == 2)
        #expect(plainFirst[0].count == 2)
    }

    @Test
    func tagSummariesRespectScopeAndFolder() {
        let workID = UUID()
        let personalID = UUID()
        let pinnedWork = BrowserProfile(
            name: "Pinned work",
            tags: ["Shared", "Pinned"],
            isPinned: true
        )
        let activeLoose = BrowserProfile(
            name: "Loose",
            tags: ["Shared"]
        )
        let archivedWork = BrowserProfile(
            name: "Archived work",
            tags: ["Shared", "Archive"],
            isArchived: true
        )
        let archivedPersonal = BrowserProfile(
            name: "Archived personal",
            tags: ["Archive"],
            isArchived: true
        )
        let organization = ProfileOrganizationState(
            folders: [
                ProfileFolder(id: workID, name: "Work"),
                ProfileFolder(id: personalID, name: "Personal"),
            ],
            assignmentsByProfileID: [
                pinnedWork.id: workID,
                archivedWork.id: workID,
                archivedPersonal.id: personalID,
            ]
        )
        let index = ProfileListIndex(
            profiles: [
                pinnedWork,
                activeLoose,
                archivedWork,
                archivedPersonal,
            ],
            organization: organization
        )

        let activeAll = Self.counts(index.tagSummaries(in: .all))
        let pinnedAll = Self.counts(
            index.tagSummaries(scope: .pinned, in: .all)
        )
        let archivedAll = Self.counts(
            index.tagSummaries(scope: .archived, in: .all)
        )
        let archivedWorkOnly = Self.counts(
            index.tagSummaries(
                scope: .archived,
                in: .folder(workID)
            )
        )
        let pinnedWorkOnly = Self.counts(
            index.tagSummaries(
                scope: .pinned,
                in: .folder(workID)
            )
        )

        #expect(activeAll[ProfileTagID(displayName: "Shared")] == 2)
        #expect(activeAll[ProfileTagID(displayName: "Pinned")] == 1)
        #expect(pinnedAll[ProfileTagID(displayName: "Shared")] == 1)
        #expect(pinnedAll[ProfileTagID(displayName: "Pinned")] == 1)
        #expect(archivedAll[ProfileTagID(displayName: "Archive")] == 2)
        #expect(archivedAll[ProfileTagID(displayName: "Shared")] == 1)
        #expect(
            archivedWorkOnly[ProfileTagID(displayName: "Archive")] == 1
        )
        #expect(
            archivedWorkOnly[ProfileTagID(displayName: "Shared")] == 1
        )
        #expect(pinnedWorkOnly == pinnedAll)
        #expect(index.count(scope: .active, in: .all) == 2)
        #expect(index.count(scope: .pinned, in: .all) == 1)
        #expect(index.count(scope: .archived, in: .all) == 2)
        #expect(index.count(scope: .archived, in: .folder(workID)) == 1)
        #expect(
            index.count(
                scope: .archived,
                in: .folder(workID),
                tagID: ProfileTagID(displayName: "Shared")
            ) == 1
        )
        #expect(
            index.count(
                scope: .archived,
                in: .folder(personalID),
                tagID: ProfileTagID(displayName: "Shared")
            ) == 0
        )
    }

    @Test
    func folderAndTagPreviewsLimitLargeSourcesAndKeepSelectionVisible() {
        let folders = (0..<50).map { index in
            ProfileFolder(name: "Folder \(index)")
        }.reversed()
        let selectedFolderID = folders.first { $0.name == "Folder 49" }!.id

        let folderPreview = ProfileListProjection.folderPreview(
            Array(folders),
            selectedID: selectedFolderID
        )

        #expect(folderPreview.visibleItems.count == 8)
        #expect(folderPreview.hiddenCount == 42)
        #expect(folderPreview.hasHiddenItems)
        #expect(folderPreview.visibleItems.contains { $0.id == selectedFolderID })

        let tags = (0..<100).map { index in
            ProfileTagSummary(name: "Tag \(index)", count: index + 1)
        }.reversed()
        let selectedTagID = ProfileTagID(displayName: "Tag 99")

        let tagPreview = ProfileListProjection.tagPreview(
            Array(tags),
            selectedID: selectedTagID
        )

        #expect(tagPreview.visibleItems.count == 8)
        #expect(tagPreview.hiddenCount == 92)
        #expect(tagPreview.hasHiddenItems)
        #expect(tagPreview.visibleItems.contains { $0.id == selectedTagID })
        #expect(!tagPreview.visibleItems.contains { $0.name == "Tag 7" })
    }

    @Test
    func sortedTenThousandItemPreviewsAvoidRepeatedFullSorting() {
        let folders = ProfileOrganizationState(
            folders: (0..<10_000).reversed().map { index in
                ProfileFolder(name: String(format: "Folder %05d", index))
            }
        ).folders
        let tags = (0..<10_000).map { index in
            ProfileTagSummary(
                name: String(format: "Tag %05d", index),
                count: index + 1
            )
        }
        let selectedFolderID = folders.last!.id
        let selectedTagID = tags.last!.id
        let startedAt = Date()
        var visibleItemCount = 0

        for _ in 0..<50 {
            let folderPreview = ProfileListProjection.folderPreview(
                folders,
                selectedID: selectedFolderID
            )
            let tagPreview = ProfileListProjection.tagPreview(
                tags,
                selectedID: selectedTagID
            )
            visibleItemCount += folderPreview.visibleItems.count
            visibleItemCount += tagPreview.visibleItems.count
            #expect(
                folderPreview.visibleItems.contains {
                    $0.id == selectedFolderID
                }
            )
            #expect(
                tagPreview.visibleItems.contains {
                    $0.id == selectedTagID
                }
            )
        }

        let budget: TimeInterval = _isDebugAssertConfiguration() ? 3 : 1
        #expect(visibleItemCount == 50 * 16)
        #expect(Date().timeIntervalSince(startedAt) < budget)
    }

    @Test
    func zeroLimitStillKeepsAnExistingSelectionVisible() {
        let tags = (0..<10).map { index in
            ProfileTagSummary(name: "Tag \(index)", count: 1)
        }
        let selectedID = ProfileTagID(displayName: "Tag 9")

        let preview = ProfileListProjection.tagPreview(
            tags,
            selectedID: selectedID,
            limit: 0
        )

        #expect(preview.visibleItems.map(\.id) == [selectedID])
        #expect(preview.hiddenCount == 9)
    }

    @Test
    func viewStateMatchesCurrentComposedProjectionSemantics() {
        let workID = UUID()
        let pinnedWork = BrowserProfile(
            name: "Pinned Café account",
            tags: ["Café", "Shared"],
            isPinned: true
        )
        let plainWork = BrowserProfile(
            name: "Plain work account",
            tags: ["cafe", "Work"]
        )
        let archivedWork = BrowserProfile(
            name: "Archived Café account",
            tags: ["CAFÉ", "Archive"],
            isArchived: true
        )
        let loose = BrowserProfile(name: "Loose", tags: ["Shared"])
        let profiles = [pinnedWork, plainWork, archivedWork, loose]
        let organization = ProfileOrganizationState(
            folders: [ProfileFolder(id: workID, name: "Work")],
            assignmentsByProfileID: [
                pinnedWork.id: workID,
                plainWork.id: workID,
                archivedWork.id: workID,
            ]
        )
        let query = WorkspaceQueryState(
            scope: .pinned,
            folderFilter: .folder(workID),
            tag: ProfileTagID(displayName: "cafe")
        )

        let state = ProfileListViewState(
            profiles: profiles,
            organization: organization,
            query: query,
            searchText: "  PINNED  "
        )
        let expectedSelectedTag = ProfileListProjection.allTags(
            in: profiles
        ).first {
            ProfileTagID(displayName: $0) == query.tag
        }
        let expectedAvailableTags = ProfileListProjection.allTags(
            in: ProfileListProjection.filtered(
                profiles,
                searchText: "",
                tag: nil,
                scope: query.scope,
                folderFilter: query.folderFilter,
                organization: organization
            )
        )
        let expectedVisible = ProfileListProjection.filtered(
            profiles,
            searchText: "  PINNED  ",
            tag: expectedSelectedTag,
            scope: query.scope,
            folderFilter: query.folderFilter,
            organization: organization
        )
        let expectedSummaries = ProfileListIndex(
            profiles: profiles,
            organization: organization
        ).tagSummaries(scope: query.scope, in: query.folderFilter)

        #expect(state.visibleProfiles == expectedVisible)
        #expect(state.tagSummaries == expectedSummaries)
        #expect(state.selectedTagDisplayName == expectedSelectedTag)
        #expect(state.availableTags == expectedAvailableTags)
    }

    @Test
    func noteSearchHandlesUnicodeAndMatchesFallbackProjection() {
        let matching = BrowserProfile(
            name: "Alpha",
            tags: ["Работа"],
            note: "Контакт Café\nВторая строка"
        )
        let other = BrowserProfile(
            name: "Beta",
            tags: ["Личный"],
            note: "Другой клиент"
        )
        let profiles = [matching, other]
        let query = WorkspaceQueryState(scope: .active)
        let indexed = ProfileListViewState(
            profiles: profiles,
            organization: .empty,
            query: query,
            searchText: "  CAFE  "
        )
        let fallback = ProfileListProjection.filtered(
            profiles,
            searchText: "  CAFE  ",
            tag: nil
        )

        #expect(indexed.visibleProfiles.map(\.id) == [matching.id])
        #expect(indexed.visibleProfiles == fallback)
        #expect(Set(indexed.tagSummaries.map(\.name)) == ["Личный", "Работа"])
    }

    @Test
    func missingSelectedTagKeepsCurrentNoTagFilterSemantics() {
        let profiles = [
            BrowserProfile(name: "Alpha", tags: ["Known"]),
            BrowserProfile(name: "Beta", tags: []),
        ]
        let query = WorkspaceQueryState(
            tag: ProfileTagID(displayName: "Deleted tag")
        )

        let state = ProfileListViewState(
            profiles: profiles,
            organization: .empty,
            query: query,
            searchText: ""
        )

        #expect(state.selectedTagDisplayName == nil)
        #expect(state.visibleProfiles == profiles)
        #expect(state.availableTags == ["Known"])
    }

    @Test
    func viewStateEqualityIsDeterministicWhenReusingItsIndex() {
        let profiles = [
            BrowserProfile(name: "Zulu", tags: ["Shared"]),
            BrowserProfile(
                name: "Alpha",
                tags: ["Café"],
                isPinned: true
            ),
        ]
        let query = WorkspaceQueryState(
            scope: .active,
            tag: ProfileTagID(displayName: "cafe")
        )
        let first = ProfileListViewState(
            profiles: profiles,
            organization: .empty,
            query: query,
            searchText: "alpha"
        )
        let independentlyBuilt = ProfileListViewState(
            profiles: profiles,
            organization: .empty,
            query: query,
            searchText: "alpha"
        )
        let reused = ProfileListViewState(
            index: first.index,
            query: query,
            searchText: "alpha"
        )
        let differentSearch = ProfileListViewState(
            index: first.index,
            query: query,
            searchText: "zulu"
        )

        #expect(first == independentlyBuilt)
        #expect(first == reused)
        #expect(first != differentSearch)
    }

    @Test
    func tenThousandProfileViewStateHasSeparateReusableIndexBudgets() {
        let folders = (0..<50).map { index in
            ProfileFolder(name: "Workspace \(index)")
        }
        let profiles = (0..<10_000).map { index in
            BrowserProfile(
                name: "Profile \(index)",
                tags: [
                    "Cohort \(index % 100)",
                    index.isMultiple(of: 2) ? "Even" : "Odd",
                ],
                note: "Account memo \(index)",
                isPinned: index.isMultiple(of: 10)
            )
        }
        let assignments = Dictionary(
            uniqueKeysWithValues: profiles.enumerated().map { index, profile in
                (profile.id, folders[index % folders.count].id)
            }
        )
        let organization = ProfileOrganizationState(
            folders: folders,
            assignmentsByProfileID: assignments
        )
        let query = WorkspaceQueryState(scope: .active)

        let initialStartedAt = Date()
        let initial = ProfileListViewState(
            profiles: profiles,
            organization: organization,
            query: query,
            searchText: "Account memo 99"
        )
        let initialElapsed = Date().timeIntervalSince(initialStartedAt)

        let repeatedStartedAt = Date()
        var repeatedVisibleCount = 0
        for searchIndex in 0..<25 {
            let state = ProfileListViewState(
                index: initial.index,
                query: query,
                searchText: "Account memo \(searchIndex)"
            )
            repeatedVisibleCount += state.visibleProfiles.count
        }
        let repeatedElapsed = Date().timeIntervalSince(repeatedStartedAt)

        let initialBudget: TimeInterval = _isDebugAssertConfiguration()
            ? 5
            : 2
        let repeatedBudget: TimeInterval = _isDebugAssertConfiguration()
            ? 8
            : 3
        print(
            "ProfileListViewState 10k benchmark: " +
                "initial=\(initialElapsed)s, " +
                "reused-searches=\(repeatedElapsed)s"
        )
        #expect(!initial.visibleProfiles.isEmpty)
        #expect(repeatedVisibleCount > 0)
        #expect(initialElapsed < initialBudget)
        #expect(repeatedElapsed < repeatedBudget)
    }

    @Test
    func tenThousandProfileFolderNameSearchStaysWithinLinearBudget() {
        let folders = (0..<50).map { index in
            ProfileFolder(name: "Needle Workspace \(index)")
        }
        let profiles = (0..<10_000).map { index in
            BrowserProfile(
                name: "Profile \(index)",
                tags: [index.isMultiple(of: 2) ? "Even" : "Odd"]
            )
        }
        let assignments = Dictionary(
            uniqueKeysWithValues: profiles.enumerated().map { index, profile in
                (profile.id, folders[index % folders.count].id)
            }
        )
        let organization = ProfileOrganizationState(
            folders: folders,
            assignmentsByProfileID: assignments
        )
        let startedAt = Date()

        let result = ProfileListProjection.filtered(
            profiles,
            searchText: "Needle Workspace 49",
            tag: nil,
            folderFilter: .all,
            organization: organization
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(result.count == 200)
        #expect(elapsed < 3)
    }

    private static func counts(
        _ summaries: [ProfileTagSummary]
    ) -> [ProfileTagID: Int] {
        Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.id, $0.count) }
        )
    }
}
