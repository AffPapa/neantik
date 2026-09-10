import Foundation
import Testing
@testable import NeAntik

struct WorkplaceMenuProjectionTests {
    @Test func recentPlacesExcludeArchiveAndMatchHomeOrder() {
        let pinned = BrowserProfile(
            name: "Pinned",
            isPinned: true,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let recent = BrowserProfile(
            name: "Recent",
            lastLaunchedAt: Date(timeIntervalSince1970: 3)
        )
        let older = BrowserProfile(
            name: "Older",
            lastLaunchedAt: Date(timeIntervalSince1970: 2)
        )
        let archived = BrowserProfile(name: "Archive", isArchived: true)
        let profiles = [older, archived, recent, pinned]

        #expect(WorkplaceMenuProjection.recentPlaces(profiles: profiles) == [pinned, recent, older])
        #expect(WorkplaceMenuProjection.recentPlaces(profiles: profiles, limit: 2) == [pinned, recent])
    }
}
