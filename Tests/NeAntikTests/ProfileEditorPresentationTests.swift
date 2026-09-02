import Foundation
import Testing
@testable import NeAntik

struct ProfileEditorPresentationTests {
    @Test
    func editorHeadingMakesCreateAndEditModesExplicit() {
        let create = ProfileEditorHeadingPresentation.resolve(
            original: nil,
            currentName: "Новый"
        )
        #expect(create.title == "Создание профиля")
        #expect(create.subtitle == nil)

        let profile = BrowserProfile(name: "TikTok · US · 01")
        let edit = ProfileEditorHeadingPresentation.resolve(
            original: profile,
            currentName: profile.name
        )
        #expect(edit.title == "Редактирование профиля")
        #expect(edit.subtitle == profile.name)
        #expect(ProfileEditorAdvancedPresentation.summary.contains("Стартовая"))
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
    func folderPickerMovesAVisibleKeyboardHighlight() {
        let first = ProfileFolder(name: "Alpha")
        let second = ProfileFolder(name: "Beta")
        let presentation = ProfileFolderPickerPresentation.resolve(
            folders: [first, second],
            searchText: ""
        )

        #expect(
            presentation.movedHighlight(from: .unfiled, offset: 1) ==
                .folder(first.id)
        )
        #expect(
            presentation.movedHighlight(from: .folder(first.id), offset: 1) ==
                .folder(second.id)
        )
        #expect(
            presentation.movedHighlight(from: .folder(second.id), offset: 1) ==
                .folder(second.id)
        )
        #expect(
            !ProfileFolderPickerKeyboardCommitPolicy.permitsCommit(
                searchText: "  ",
                didMoveHighlight: false
            )
        )
        #expect(
            ProfileFolderPickerKeyboardCommitPolicy.permitsCommit(
                searchText: "",
                didMoveHighlight: true
            )
        )
        #expect(
            ProfileFolderPickerKeyboardCommitPolicy.permitsCommit(
                searchText: "Alpha",
                didMoveHighlight: false
            )
        )
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
}
