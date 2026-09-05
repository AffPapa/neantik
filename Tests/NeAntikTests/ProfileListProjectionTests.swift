import Foundation
import Testing
@testable import NeAntik

extension ProfileListProjectionTests {
    private func results(_ query: String, _ profiles: [BrowserProfile]) -> [UUID] {
        ProfileListProjection.filtered(profiles, searchText: query, tag: nil).map(\.id)
    }

    @Test func fieldSearchDoesNotLeakAcrossFields() {
        let profile = BrowserProfile(name: "Alpha", tags: ["Beta"], note: "Gamma")
        for query in ["name:alpha", "имя:Alpha", "note:gamma", "заметка:Gamma"] {
            #expect(results(query, [profile]) == [profile.id])
        }
        for query in ["name:gamma", "note:alpha", "name:beta"] {
            #expect(results(query, [profile]).isEmpty)
        }
    }

    @Test func identifierSearchUsesOnlyProfileIdentifier() {
        let profile = BrowserProfile(name: "Alpha")
        #expect(results("id:\(profile.id.uuidString)", [profile]) == [profile.id])
        #expect(results("ид:\(profile.id.uuidString.prefix(8).lowercased())", [profile]) == [profile.id])
        #expect(results("id:Alpha", [profile]).isEmpty)
    }

    @Test func presencePredicatesComposeAndSupportAliases() {
        let full = BrowserProfile(name: "Full", tags: ["work"], note: "Review")
        let empty = BrowserProfile(name: "Empty")
        for query in ["has:note has:tags", "есть:заметка есть:теги"] {
            #expect(results(query, [full, empty]) == [full.id])
        }
        for query in ["missing:note missing:tags", "без:заметка без:теги"] {
            #expect(results(query, [full, empty]) == [empty.id])
        }
        #expect(results("has:note missing:note", [full, empty]).isEmpty)
    }

    @Test func recognizedMalformedQueriesExplainFailure() {
        for query in ["name:", "note:", "status:running", "has:password", "missing:cookie"] {
            #expect(ProfileSearchQuery(rawValue: query).validationMessage != nil)
            #expect(results(query, [BrowserProfile(name: query)]).isEmpty)
        }
        #expect(ProfileSearchQuery(rawValue: "https://example.com").validationMessage == nil)
        #expect(results("custom:value", [BrowserProfile(name: "custom:value")]).count == 1)
    }

    @Test func oversizedQueriesFailWithoutTruncatedMatching() {
        let limit = ProfileSearchQuery.maximumUTF8Bytes
        #expect(ProfileSearchQuery(rawValue: String(repeating: "a", count: limit)).validationMessage == nil)
        let oversized = String(repeating: "я", count: limit)
        #expect(ProfileSearchQuery(rawValue: oversized).validationMessage != nil)
        #expect(results(oversized, [BrowserProfile(name: "я")]).isEmpty)
    }

    @Test func phrasesDiacriticsAndExistingFacetsRemainCompatible() {
        let profile = BrowserProfile(name: "Café campaign", tags: ["TikTok"], note: "next action")
        #expect(results("имя:\"cafe campaign\" tag:tiktok missing:tags", [profile]).isEmpty)
        #expect(results("имя:\"cafe campaign\" tag:tiktok note:\"next action\"", [profile]) == [profile.id])
        #expect(results("campaign cafe", [profile]).isEmpty)
        #expect(results("cafe campaign", [profile]) == [profile.id])
    }

    @Test func indexedAndStandaloneQueriesAgree() {
        let profile = BrowserProfile(name: "Campaign", tags: ["work"], note: "Review")
        let index = ProfileListIndex(profiles: [profile], organization: .init())
        for query in ["name:campaign", "has:note", "missing:tags", "note:", "note:review"] {
            #expect(index.filtered(searchText: query, tag: nil, scope: .active, folderFilter: .all).map(\.id) == results(query, [profile]))
        }
    }

    @Test func visibleExamplesAreValidQueries() {
        for example in ProfileSearchSyntaxHelp.examples {
            #expect(ProfileSearchQuery(rawValue: example).validationMessage == nil)
        }
    }
}

struct ProfileListProjectionTests {
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
                isPinned: index.isMultiple(of: 10),
                proxy: index.isMultiple(of: 2)
                    ? ProxyConfiguration(
                        kind: .https,
                        host: "proxy-\(index).example",
                        port: 8_000 + index % 1_000,
                        username: "operator-\(index)"
                    )
                    : nil,
                createdAt: Date(
                    timeIntervalSinceReferenceDate: TimeInterval(index)
                ),
                lastLaunchedAt: index.isMultiple(of: 3)
                    ? Date(
                        timeIntervalSinceReferenceDate: TimeInterval(index)
                    )
                    : nil
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
        for ordering in ProfileListOrdering.allCases {
            for searchIndex in 0..<25 {
                let state = ProfileListViewState(
                    index: initial.index,
                    query: query,
                    searchText: "Account memo \(searchIndex)",
                    routeFilter: searchIndex.isMultiple(of: 2)
                        ? .withProxy
                        : .withoutProxy,
                    ordering: ordering
                )
                repeatedVisibleCount += state.visibleProfiles.count
            }
        }
        let repeatedElapsed = Date().timeIntervalSince(repeatedStartedAt)

        let initialBudget: TimeInterval = _isDebugAssertConfiguration()
            ? 5
            : 2
        let repeatedBudget: TimeInterval = _isDebugAssertConfiguration()
            ? 12
            : 5
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

    @Test
    func structuredSearchCombinesTagsFoldersProxyStatusAndFreeText() {
        let paidID = UUID()
        let organicID = UUID()
        let matching = BrowserProfile(
            name: "TikTok campaign",
            tags: ["TikTok", "Scale"],
            note: "Creative batch 12",
            isPinned: true,
            proxy: ProxyConfiguration(
                kind: .http,
                host: "de.proxy.example",
                port: 8_080,
                username: ""
            )
        )
        let archived = BrowserProfile(
            name: "Archived direct",
            tags: ["TikTok"],
            isArchived: true
        )
        let organization = ProfileOrganizationState(
            folders: [
                ProfileFolder(id: paidID, name: "Paid Social"),
                ProfileFolder(id: organicID, name: "Organic"),
            ],
            assignmentsByProfileID: [
                matching.id: paidID,
                archived.id: organicID,
            ]
        )
        let profiles = [matching, archived]
        let query =
            "campaign tag:tiktok folder:\"Paid Social\" proxy:yes status:pinned"

        let directResult = ProfileListProjection.filtered(
            profiles,
            searchText: query,
            tag: nil,
            organization: organization
        )
        let indexedResult = ProfileListIndex(
            profiles: profiles,
            organization: organization
        ).filtered(
            searchText: query,
            tag: nil,
            scope: .active,
            folderFilter: .all
        )

        #expect(directResult.map(\.id) == [matching.id])
        #expect(indexedResult.map(\.id) == [matching.id])
    }

    @Test
    func structuredSearchSupportsRussianAliasesAndFailClosedStatus() {
        let active = BrowserProfile(name: "Active", tags: ["Тизерки"])
        let archived = BrowserProfile(
            name: "Archived",
            tags: ["Тизерки"],
            isArchived: true
        )
        let profiles = [active, archived]

        let archivedResult = ProfileListProjection.filtered(
            profiles,
            searchText: "тег:тизерки прокси:нет статус:архив",
            tag: nil,
            scope: .archived
        )
        let unsupportedStatus = ProfileListProjection.filtered(
            profiles,
            searchText: "status:running",
            tag: nil
        )

        #expect(archivedResult.map(\.id) == [archived.id])
        #expect(unsupportedStatus.isEmpty)
    }

    private static func counts(
        _ summaries: [ProfileTagSummary]
    ) -> [ProfileTagID: Int] {
        Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.id, $0.count) }
        )
    }
}
