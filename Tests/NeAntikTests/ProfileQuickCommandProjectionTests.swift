import Foundation
import Testing
@testable import NeAntik

struct ProfileQuickCommandProjectionTests {
    @Test func searchesNameTagsNoteAndFolderWithMainListFolding() {
        let folder = ProfileFolder(name: "Café team")
        let byName = BrowserProfile(name: "Alpha")
        let byTag = BrowserProfile(name: "Beta", tags: ["Finance"])
        let byNote = BrowserProfile(name: "Gamma", note: "Quarterly review")
        let byFolder = BrowserProfile(name: "Delta")
        let profiles = [byName, byTag, byNote, byFolder]
        let organization = ProfileOrganizationState(
            folders: [folder], assignmentsByProfileID: [byFolder.id: folder.id]
        )
        #expect(ProfileQuickCommandProjection.matching(profiles, search: "alpha", organization: organization).map(\.id) == [byName.id])
        #expect(ProfileQuickCommandProjection.matching(profiles, search: "FINANCE", organization: organization).map(\.id) == [byTag.id])
        #expect(ProfileQuickCommandProjection.matching(profiles, search: "review", organization: organization).map(\.id) == [byNote.id])
        #expect(ProfileQuickCommandProjection.matching(profiles, search: "cafe", organization: organization).map(\.id) == [byFolder.id])
    }
}
