import Foundation
import Testing
@testable import NeAntik

struct WorkspaceUXPresentationTests {
    @Test
    func filteredCountSeparatesVisibleFromTotal() {
        let result = ProfileFilteredCountPresentation(
            visibleCount: 3,
            totalCount: 12
        )
        #expect(result.title == "Показано 3 из 12")
        #expect(result.announcement.contains("3 из 12"))
    }

    @Test
    func emptyStateExplainsSearchBeforeOtherFilters() {
        let result = ProfileListEmptyStatePresentation.resolve(
            searchText: "needle",
            routeFilter: .withProxy,
            scope: .archived,
            folderFilter: .unfiled,
            hasTagFilter: true
        )
        #expect(result.primaryAction == .clearSearch)
        #expect(result.title.contains("запросу"))
    }

    @Test
    func emptyFolderOffersCreationInCurrentFolder() {
        let result = ProfileListEmptyStatePresentation.resolve(
            searchText: "",
            routeFilter: .all,
            scope: .active,
            folderFilter: .folder(UUID()),
            hasTagFilter: false
        )
        #expect(result.primaryAction == .createInCurrentFolder)
    }
}
