import Testing
@testable import NeAntik

struct UXDraftProtectionTests {
    @Test
    func profileCountAnnouncementsAvoidIncorrectRussianDeclension() {
        for count in [0, 1, 4, 11, 21] {
            #expect(ProfileFilteredCountPresentation(visibleCount: count, totalCount: count)
                .announcement == "Профилей в списке: \(count)")
        }
        #expect(ProfileFilteredCountPresentation(visibleCount: 1, totalCount: 4)
            .announcement == "Профилей по текущим фильтрам: 1. Всего: 4")
    }

    @Test
    func folderDraftKeepsInvalidInputAndIgnoresNormalizedNoOp() {
        #expect(!ProfileFolderNameValidation.hasChanges(name: "", initialName: ""))
        #expect(!ProfileFolderNameValidation.hasChanges(name: "  Работа  ", initialName: "Работа"))
        #expect(ProfileFolderNameValidation.hasChanges(name: "работа", initialName: "Работа"))
        #expect(ProfileFolderNameValidation.hasChanges(name: "", initialName: "Работа"))
        #expect(ProfileFolderNameValidation.hasChanges(name: "Новая", initialName: ""))
        #expect(ProfileFolderNameValidation.hasChanges(name: String(repeating: "a", count: 65), initialName: ""))
    }

    @Test
    func noteFooterDoesNotOfferUnavailableSaveShortcut() {
        let draft = ProfileNoteDraftSnapshot(note: "Заметка")
        #expect(draft.statusText(currentNote: " Заметка ").contains("Нет изменений"))
        #expect(draft.statusText(currentNote: "Следующий шаг").contains("⌘Return"))
        #expect(draft.statusText(currentNote: "").contains("⌘Return"))
        let invalid = String(repeating: "a", count: BrowserProfile.maximumNoteLength + 1)
        #expect(!draft.statusText(currentNote: invalid).contains("⌘Return"))
        #expect(draft.statusText(currentNote: invalid).contains("Исправь"))
    }

    @Test
    func noteSaveRequiresValidMeaningfulChange() {
        let draft = ProfileNoteDraftSnapshot(note: "Заметка")
        #expect(!draft.canSave(currentNote: "Заметка"))
        #expect(!draft.hasUnsavedChanges(currentNote: "  Заметка  "))
        #expect(!draft.canSave(currentNote: "  Заметка  "))
        #expect(draft.canSave(currentNote: "Следующий шаг"))
        #expect(draft.canSave(currentNote: ""))
        #expect(!draft.canSave(currentNote: String(repeating: "a", count: BrowserProfile.maximumNoteLength + 1)))
        #expect(!ProfileNoteDraftSnapshot(note: "").canSave(currentNote: ""))
    }
    @Test
    func noteDraftOnlyRequiresConfirmationAfterARealChange() {
        let draft = ProfileNoteDraftSnapshot(note: "Следующий шаг")

        #expect(!draft.hasUnsavedChanges(currentNote: "Следующий шаг"))
        #expect(draft.hasUnsavedChanges(currentNote: "Следующий шаг!"))
        #expect(!draft.hasUnsavedChanges(currentNote: "Следующий шаг"))
    }

    @Test
    func bulkProxyDraftProtectsTextAndEveryPersistentOption() {
        let draft = BulkProxyImportDraftSnapshot(
            text: "proxy.example:8080",
            baseName: "Прокси",
            kind: .http,
            order: .automatic
        )

        #expect(
            !draft.hasUnsavedChanges(
                text: "proxy.example:8080",
                baseName: "Прокси",
                kind: .http,
                order: .automatic
            )
        )
        #expect(
            draft.hasUnsavedChanges(
                text: "other.example:8080",
                baseName: "Прокси",
                kind: .http,
                order: .automatic
            )
        )
        #expect(
            draft.hasUnsavedChanges(
                text: "proxy.example:8080",
                baseName: "TikTok",
                kind: .http,
                order: .automatic
            )
        )
        #expect(
            draft.hasUnsavedChanges(
                text: "proxy.example:8080",
                baseName: "Прокси",
                kind: .https,
                order: .automatic
            )
        )
        #expect(
            draft.hasUnsavedChanges(
                text: "proxy.example:8080",
                baseName: "Прокси",
                kind: .http,
                order: .credentialsFirst
            )
        )
    }
}
