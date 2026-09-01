import Testing
@testable import NeAntik

struct NeAntikShortcutCatalogTests {
    @Test func everyShortcutHasOneUniqueChord() {
        let identifiers = NeAntikShortcut.allCases.map(\.chordIdentifier)

        #expect(Set(identifiers).count == identifiers.count)
        #expect(!identifiers.contains("command+q"))
        #expect(!identifiers.contains("command+w"))
    }

    @Test func frequentProfileActionsUseFixedMenuBackedShortcuts() {
        #expect(
            NeAntikShortcut.toggleSelectedProfile.displayChord == "⌘↩"
        )
        #expect(
            NeAntikShortcut.focusSelectedProfile.displayChord == "⇧⌘↩"
        )
        #expect(NeAntikShortcut.toggleInspector.displayChord == "⌘I")
        #expect(NeAntikShortcut.editSelectedNote.displayChord == "⌥⌘N")
        #expect(NeAntikShortcut.shortcutReference.displayChord == "⌘/")
    }

    @Test func noDestructiveActionAppearsInShortcutCatalog() {
        let titles = NeAntikShortcut.allCases.map(\.title).joined(separator: " ")

        #expect(!titles.localizedCaseInsensitiveContains("удал"))
        #expect(!titles.localizedCaseInsensitiveContains("принуд"))
        #expect(!titles.localizedCaseInsensitiveContains("архив"))
    }
}
