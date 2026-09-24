import Foundation
import Testing
@testable import NeAntik

struct ProfileEditorPresentationTests {
    @Test
    func quickStartTemplatesOnlySuggestEditableNameAndTag() {
        let blank = ProfileQuickStartTemplate.blank.draft(
            name: "", tags: []
        )
        #expect(blank.name.isEmpty)
        #expect(blank.tags.isEmpty)

        let work = ProfileQuickStartTemplate.work.draft(
            name: "", tags: ["личное"]
        )
        #expect(work.name == "Работа")
        #expect(work.tags == ["личное", "работа"])

        let customized = ProfileQuickStartTemplate.testing.draft(
            name: "Мой стенд", tags: ["тест"]
        )
        #expect(customized.name == "Мой стенд")
        #expect(customized.tags == ["тест"])

        let switched = ProfileQuickStartTemplate.testing.draft(
            name: "Работа",
            tags: ["работа", "важно"],
            replacing: .work,
            replacingGeneratedName: true,
            replacingGeneratedTag: true
        )
        #expect(switched.name == "Тестирование")
        #expect(switched.tags == ["важно", "тест"])

        let userOwned = ProfileQuickStartTemplate.blank.draft(
            name: "Работа", tags: ["работа"], replacing: .work
        )
        #expect(userOwned.name == "Работа")
        #expect(userOwned.tags == ["работа"])

        let generated = ProfileQuickStartTemplate.blank.draft(
            name: "Работа",
            tags: ["работа"],
            replacing: .work,
            replacingGeneratedName: true,
            replacingGeneratedTag: true
        )
        #expect(generated.name.isEmpty)
        #expect(generated.tags.isEmpty)
    }
    @Test
    func compactFolderControlCoversZeroAndOneFolder() {
        let empty = ProfileEditorFolderPresentation.resolve(
            folders: [],
            selectedFolderID: nil
        )
        #expect(empty.quickOptions.count == 1)
        #expect(empty.selectedTitle == "Без папки")
        #expect(!empty.offersSearchablePicker)

        let folder = ProfileFolder(name: "Работа")
        let single = ProfileEditorFolderPresentation.resolve(
            folders: [folder],
            selectedFolderID: folder.id
        )
        #expect(single.quickOptions.count == 2)
        #expect(single.selectedTitle == "Работа")
        #expect(!single.offersSearchablePicker)
    }

    @Test
    func largeFolderControlStaysBoundedAndKeepsCurrentSelection() {
        let folders = (0..<24).map {
            ProfileFolder(name: "Папка \($0 + 1)")
        }
        let current = folders.last!

        let presentation = ProfileEditorFolderPresentation.resolve(
            folders: folders,
            selectedFolderID: current.id
        )

        #expect(presentation.offersSearchablePicker)
        #expect(
            presentation.quickOptions.count ==
                ProfileFolderCommandProjection.defaultLimit
        )
        #expect(presentation.selectedTitle == current.name)
        #expect(
            presentation.quickOptions.contains(where: {
                $0.folderID == current.id && $0.isSelected
            })
        )
    }

    @Test
    func folderSearchReturnIsExplicitAndDoesNotMoveOnEmptyQuery() {
        let folders = (0..<24).map {
            ProfileFolder(name: "Папка \($0 + 1)")
        }

        let emptyQuery = ProfileFolderPickerPresentation.resolve(
            folders: folders,
            searchText: ""
        )
        #expect(emptyQuery.filteredFolders.count == 24)
        #expect(emptyQuery.returnFolderID == nil)

        let filtered = ProfileFolderPickerPresentation.resolve(
            folders: folders,
            searchText: "Папка 24"
        )
        #expect(filtered.filteredFolders.map(\.name) == ["Папка 24"])
        #expect(filtered.returnFolderID == folders.last?.id)

        let missing = ProfileFolderPickerPresentation.resolve(
            folders: folders,
            searchText: "Нет такой папки"
        )
        #expect(missing.filteredFolders.isEmpty)
        #expect(missing.returnFolderID == nil)
    }

    @Test
    func proxyContextUsesTextAndIconForFreshness() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let fresh = ProfileEditorProxyContextPresentation.resolve(
            evidence: .ipAPI(observedAt: now.addingTimeInterval(-60)),
            now: now
        )
        #expect(fresh.title.contains("свежий"))
        #expect(fresh.systemImage == "checkmark.circle.fill")
        #expect(!fresh.requiresAttention)
        #expect(fresh.detail.contains("Перед каждым запуском"))

        let stale = ProfileEditorProxyContextPresentation.resolve(
            evidence: .ipAPI(
                observedAt: now.addingTimeInterval(
                    -ProxyContextEvidence.freshnessLifetime - 1
                )
            ),
            now: now
        )
        #expect(stale.title.contains("устарел"))
        #expect(stale.systemImage == "exclamationmark.triangle.fill")
        #expect(stale.requiresAttention)
        #expect(stale.detail.contains("Перед следующим запуском"))
    }

    @Test
    func proxySuccessPresentationNeverIncludesDetectedIPAddress() {
        let withoutLocation = ProfileProxyTestPresentation.successMessage(
            location: ""
        )
        let withLocation = ProfileProxyTestPresentation.successMessage(
            location: "Нидерланды · Europe/Amsterdam"
        )

        #expect(withoutLocation == "Маршрут подтверждён")
        #expect(withLocation.contains("Маршрут подтверждён"))
        #expect(!withoutLocation.contains("203.0.113.77"))
        #expect(!withLocation.contains("203.0.113.77"))
        #expect(!withLocation.contains("ipAddress"))
    }
}
