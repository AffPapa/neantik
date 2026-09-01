import Testing
@testable import NeAntik

struct UXDraftProtectionTests {
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
