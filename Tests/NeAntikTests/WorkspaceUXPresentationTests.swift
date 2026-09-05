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

    @Test
    func combinedFolderAndScopeOffersScopeRecoveryInsteadOfCreation() {
        for folder in [ProfileFolderFilter.folder(UUID()), .unfiled] {
            for scope in [ProfileListScope.pinned, .archived] {
                let result = ProfileListEmptyStatePresentation.resolve(
                    searchText: "", routeFilter: .all, scope: scope,
                    folderFilter: folder, hasTagFilter: false
                )
                #expect(result.primaryAction == .clearScope)
                #expect(result.title.contains(scope == .archived ? "архивных" : "закреплённых"))
                #expect(!result.title.contains("пока нет профилей"))
                if folder == .unfiled {
                    #expect(result.title.contains("Без папки"))
                }
                let query = WorkspaceQueryState(scope: scope, folderFilter: folder)
                let recovered = query.removing(.scope)
                #expect(recovered.scope == .active)
                #expect(recovered.folderFilter == folder)
            }
        }
    }

    @Test
    func activeUnfiledScopeKeepsItsExistingRecovery() {
        let result = ProfileListEmptyStatePresentation.resolve(
            searchText: "", routeFilter: .all, scope: .active,
            folderFilter: .unfiled, hasTagFilter: false
        )
        #expect(result.primaryAction == .showAllProfiles)
        #expect(result.title == "Все профили разложены по папкам")
    }
}
