import Foundation
import Testing
@testable import NeAntik

struct ProfileBatchActionsTests {
    @Test
    func tagPreviewCountsActualChangesAndCaseInsensitiveCoverage() {
        let profiles = [BrowserProfile(name: "A", tags: ["CAFÉ"]), BrowserProfile(name: "B")]
        let add = ProfileBatchTagPreview.resolve(profiles: profiles, tag: "cafe", adding: true)
        #expect(add.matching == 1 && add.affected == 1 && add.canApply)
        let remove = ProfileBatchTagPreview.resolve(profiles: profiles, tag: "cafe", adding: false)
        #expect(remove.matching == 1 && remove.affected == 1 && remove.canApply)
    }

    @Test
    func tagPreviewDisablesEmptyInvalidAndNoOpActions() {
        let profiles = [BrowserProfile(name: "A", tags: ["TikTok"])]
        #expect(!ProfileBatchTagPreview.resolve(profiles: profiles, tag: "tiktok", adding: true).canApply)
        #expect(!ProfileBatchTagPreview.resolve(profiles: profiles, tag: "absent", adding: false).canApply)
        #expect(!ProfileBatchTagPreview.resolve(profiles: [], tag: "tag", adding: true).canApply)
        #expect(!ProfileBatchTagPreview.resolve(profiles: profiles, tag: "", adding: true).valid)
        #expect(!ProfileBatchTagPreview.resolve(profiles: profiles, tag: "bad\ntag", adding: true).valid)
    }

    @Test
    func tagPreviewBlocksWholeBatchOnLimitButAllowsExistingTagAndRemoval() {
        let tags = (0..<BrowserProfile.maximumTagCount).map { "tag\($0)" }
        let profiles = [BrowserProfile(name: "Full", tags: tags), BrowserProfile(name: "Empty")]
        let blocked = ProfileBatchTagPreview.resolve(profiles: profiles, tag: "new", adding: true)
        #expect(blocked.blocked == 1 && !blocked.canApply)
        #expect(ProfileBatchTagPreview.resolve(profiles: profiles, tag: "tag0", adding: true).canApply)
        #expect(ProfileBatchTagPreview.resolve(profiles: profiles, tag: "tag0", adding: false).canApply)
    }

    @Test
    func removalSuggestionsComeOnlyFromSelectedProfilesAndDeduplicate() {
        let profiles = [BrowserProfile(name: "A", tags: ["TikTok"]), BrowserProfile(name: "B", tags: ["tiktok"])]
        let remove = ProfileBatchTagPreview.suggestions(profiles: profiles, library: ["Unrelated"], adding: false)
        #expect(remove.count == 1 && remove[0] == "TikTok")
        #expect(ProfileBatchTagPreview.suggestions(profiles: profiles, library: ["Unrelated"], adding: true) == ["Unrelated"])
    }

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
