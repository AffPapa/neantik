import Testing
@testable import NeAntik

struct ProfileFolderParentPickerPresentationTests {
    @Test
    func excludesSelfAndDescendantsAndMarksNameConflicts() {
        let source = ProfileFolder(name: "Campaigns")
        let moving = ProfileFolder(name: "Japan", parentFolderID: source.id)
        let descendant = ProfileFolder(name: "Tokyo", parentFolderID: moving.id)
        let archive = ProfileFolder(name: "Archive")
        let conflict = ProfileFolder(name: "Japan", parentFolderID: archive.id)
        let rootConflict = ProfileFolder(name: "Japan")
        let other = ProfileFolder(name: "Other")
        let organization = ProfileOrganizationState(
            folders: [source, moving, descendant, archive, conflict, rootConflict, other]
        )

        let presentation = ProfileFolderParentPickerPresentation.resolve(
            movingFolderID: moving.id,
            organization: organization,
            searchText: ""
        )

        let eligibleIDs = Set(presentation.eligibleFolders.map(\.id))
        #expect(!eligibleIDs.contains(moving.id))
        #expect(!eligibleIDs.contains(descendant.id))
        #expect(eligibleIDs.contains(source.id))
        #expect(eligibleIDs.contains(archive.id))
        #expect(presentation.selectedParentFolderID == source.id)
        #expect(presentation.pathByFolderID[conflict.id] == "Archive › Japan")
        #expect(presentation.blockedParentFolderIDs.contains(archive.id))
        #expect(presentation.rootDestinationBlocked)
    }

    @Test
    func ancestorSearchFindsEligibleParentByItsFullPath() {
        let campaign = ProfileFolder(name: "Campaigns")
        let region = ProfileFolder(name: "Asia", parentFolderID: campaign.id)
        let moving = ProfileFolder(name: "Japan")
        let organization = ProfileOrganizationState(folders: [campaign, region, moving])

        let presentation = ProfileFolderParentPickerPresentation.resolve(
            movingFolderID: moving.id,
            organization: organization,
            searchText: "Campaigns"
        )

        #expect(Set(presentation.eligibleFolders.map(\.id)) == Set([campaign.id, region.id]))
        #expect(presentation.pathByFolderID[region.id] == "Campaigns › Asia")
    }
}
