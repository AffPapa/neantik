import Testing
@testable import NeAntik

struct UXDraftProtectionTests {
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
