import Foundation
import Testing
@testable import NeAntik

struct ProfileBatchActionsTests {
    @Test
    func presentationKeepsOnlyVisibleSelectionAndResolvesBulkIntent() {
        let pinned = BrowserProfile(name: "Pinned", isPinned: true)
        let regular = BrowserProfile(name: "Regular")
        let hidden = BrowserProfile(name: "Hidden")

        let presentation = ProfileBatchSelectionPresentation.resolve(
            visibleProfiles: [pinned, regular],
            selectedProfileIDs: [pinned.id, regular.id, hidden.id],
            runningProfileIDs: [regular.id]
        )

        #expect(presentation.selectedCount == 2)
        #expect(presentation.allVisibleSelected)
        #expect(!presentation.allSelectedPinned)
        #expect(!presentation.allSelectedArchived)
        #expect(presentation.containsRunningProfile)
        #expect(!presentation.selectedProfileIDs.contains(hidden.id))
    }

    @Test
    func emptySelectionNeverClaimsEveryProfileMatches() {
        let profile = BrowserProfile(
            name: "Archived",
            isPinned: true,
            isArchived: true
        )

        let presentation = ProfileBatchSelectionPresentation.resolve(
            visibleProfiles: [profile],
            selectedProfileIDs: [],
            runningProfileIDs: []
        )

        #expect(!presentation.hasSelection)
        #expect(!presentation.allVisibleSelected)
        #expect(!presentation.allSelectedPinned)
        #expect(!presentation.allSelectedArchived)
        #expect(!presentation.containsRunningProfile)
    }

    @Test
    func selectedArchivedProfilesResolveRestoreActionState() {
        let first = BrowserProfile(name: "A", isArchived: true)
        let second = BrowserProfile(name: "B", isArchived: true)

        let presentation = ProfileBatchSelectionPresentation.resolve(
            visibleProfiles: [first, second],
            selectedProfileIDs: [first.id, second.id],
            runningProfileIDs: []
        )

        #expect(presentation.allSelectedArchived)
        #expect(!presentation.containsRunningProfile)
    }
}
