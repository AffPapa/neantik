import Foundation
import Testing
@testable import NeAntik

struct ProfileListOrderingTests {
    @Test
    func defaultOrderingPinsFirstAndMatchesLegacyComparator() {
        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let profiles = [
            BrowserProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                name: "Profile 10",
                createdAt: createdAt
            ),
            BrowserProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Profile 2",
                createdAt: createdAt
            ),
            BrowserProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Zulu",
                isPinned: true,
                createdAt: createdAt
            ),
        ]

        let ordered = profiles.sorted(
            by: ProfileListOrdering.pinnedThenName.areInIncreasingOrder
        )
        let legacy = profiles.sorted(
            by: ProfileListProjection.areInIncreasingOrder
        )

        #expect(ordered.map(\.name) == ["Zulu", "Profile 2", "Profile 10"])
        #expect(ordered == legacy)
    }

    @Test
    func recentLaunchKeepsPinsFirstAndNeverLaunchedProfilesLast() {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let pinned = BrowserProfile(
            name: "Pinned",
            isPinned: true,
            createdAt: base
        )
        let older = BrowserProfile(
            name: "Older",
            createdAt: base.addingTimeInterval(1),
            lastLaunchedAt: base.addingTimeInterval(10)
        )
        let newestLaunch = BrowserProfile(
            name: "Newest launch",
            createdAt: base.addingTimeInterval(2),
            lastLaunchedAt: base.addingTimeInterval(20)
        )
        let never = BrowserProfile(
            name: "Never",
            createdAt: base.addingTimeInterval(3)
        )

        let ordered = [never, older, pinned, newestLaunch].sorted(
            by: ProfileListOrdering.recentLaunch.areInIncreasingOrder
        )

        #expect(
            ordered.map(\.id) == [
                pinned.id,
                newestLaunch.id,
                older.id,
                never.id,
            ]
        )
    }

    @Test
    func newestOrderingUsesCreationDateWithoutOverridingPins() {
        let base = Date(timeIntervalSinceReferenceDate: 20_000)
        let pinnedOld = BrowserProfile(
            name: "Pinned old",
            isPinned: true,
            createdAt: base
        )
        let old = BrowserProfile(
            name: "Old",
            createdAt: base.addingTimeInterval(1)
        )
        let new = BrowserProfile(
            name: "New",
            createdAt: base.addingTimeInterval(2)
        )

        let ordered = [old, new, pinnedOld].sorted(
            by: ProfileListOrdering.newest.areInIncreasingOrder
        )

        #expect(ordered.map(\.id) == [pinnedOld.id, new.id, old.id])
    }

    @Test
    func routeFilterAndOrderingComposeInCachedAndFallbackProjections() {
        let base = Date(timeIntervalSinceReferenceDate: 30_000)
        let direct = BrowserProfile(
            name: "Direct",
            createdAt: base.addingTimeInterval(1)
        )
        let proxy = BrowserProfile(
            name: "Proxy",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 8443,
                username: "private-login-marker"
            ),
            createdAt: base.addingTimeInterval(2)
        )
        let profiles = [direct, proxy]
        let index = ProfileListIndex(
            profiles: profiles,
            organization: .empty
        )

        for routeFilter in ProfileRouteFilter.allCases {
            for ordering in ProfileListOrdering.allCases {
                let indexed = index.filtered(
                    searchText: "",
                    tag: nil,
                    scope: .active,
                    folderFilter: .all,
                    routeFilter: routeFilter,
                    ordering: ordering
                )
                let fallback = ProfileListProjection.filtered(
                    profiles,
                    searchText: "",
                    tag: nil,
                    routeFilter: routeFilter,
                    ordering: ordering
                )
                #expect(indexed == fallback)
            }
        }

        #expect(
            index.filtered(
                searchText: "",
                tag: nil,
                scope: .active,
                folderFilter: .all,
                routeFilter: .withProxy
            ).map(\.id) == [proxy.id]
        )
        #expect(
            index.filtered(
                searchText: "",
                tag: nil,
                scope: .active,
                folderFilter: .all,
                routeFilter: .withoutProxy
            ).map(\.id) == [direct.id]
        )
    }

    @Test
    func routeSearchIndexesEndpointAndTypeButNeverUsername() {
        let profile = BrowserProfile(
            name: "Neutral profile",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "edge.proxy.example",
                port: 9443,
                username: "private-login-marker"
            )
        )
        let index = ProfileListIndex(
            profiles: [profile],
            organization: .empty
        )

        #expect(Self.search("edge.proxy.example", in: index) == [profile])
        #expect(Self.search("HTTPS", in: index) == [profile])
        #expect(Self.search("private-login-marker", in: index).isEmpty)
        #expect(
            !ProfileRouteSearchDocument.values(for: profile)
                .joined(separator: " ")
                .contains("private-login-marker")
        )
    }

    @Test
    func viewStateDefaultsPreserveExplicitLegacyConfiguration() {
        let profiles = [
            BrowserProfile(name: "Zulu"),
            BrowserProfile(name: "Alpha", isPinned: true),
        ]
        let query = WorkspaceQueryState.default
        let implicit = ProfileListViewState(
            profiles: profiles,
            organization: .empty,
            query: query,
            searchText: ""
        )
        let explicit = ProfileListViewState(
            profiles: profiles,
            organization: .empty,
            query: query,
            searchText: "",
            routeFilter: .all,
            ordering: .pinnedThenName
        )

        #expect(implicit == explicit)
        #expect(implicit.routeFilter == .all)
        #expect(implicit.ordering == .pinnedThenName)
    }

    private static func search(
        _ query: String,
        in index: ProfileListIndex
    ) -> [BrowserProfile] {
        index.filtered(
            searchText: query,
            tag: nil,
            scope: .active,
            folderFilter: .all
        )
    }
}
