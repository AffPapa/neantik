import Testing
@testable import NeAntik

struct NeAntikShortcutCatalogTests {
    @Test func referenceSearchFindsTitleCategoryAndChord() {
        #expect(NeAntikShortcut.editSelectedNote.matchesSearch("ЗАМЕТКУ"))
        #expect(NeAntikShortcut.newFolder.matchesSearch("рабочее пространство"))
        #expect(NeAntikShortcut.focusSelectedProfile.matchesSearch("Shift Return"))
        #expect(NeAntikShortcut.toggleInspector.matchesSearch("⌘I"))
        #expect(NeAntikShortcut.allCases.allSatisfy { $0.matchesSearch(" \n ") })
        #expect(!NeAntikShortcut.newFolder.matchesSearch("несуществующая команда"))
        #expect(!NeAntikShortcut.editSelectedNote.matchesSearch("заметку Shift"))
    }

    @Test func everyCommandExplainsContextWithoutUserData() {
        #expect(NeAntikShortcut.allCases.allSatisfy { !$0.availability.isEmpty })
        #expect(NeAntikShortcut.focusSelectedProfile.availability.contains("запущенного"))
        #expect(NeAntikShortcut.editSelectedProfile.availability.contains("перехода"))
        #expect(NeAntikShortcut.newProfile.availability.contains("диалог"))
    }

    @Test func plusSeparatedReturnChordsRequireExactModifiers() {
        #expect(NeAntikShortcut.toggleSelectedProfile.matchesSearch("Command+Return"))
        #expect(NeAntikShortcut.focusSelectedProfile.matchesSearch("shift+command+return"))
        #expect(!NeAntikShortcut.focusSelectedProfile.matchesSearch("Command+Return"))
        #expect(!NeAntikShortcut.toggleSelectedProfile.matchesSearch("Shift+Command+Return"))
        #expect(!NeAntikShortcut.toggleSelectedProfile.matchesSearch("Option+Command+Return"))
        #expect(!NeAntikShortcut.newProfile.matchesSearch("Command+Return"))
        #expect(NeAntikShortcut.newProfile.matchesSearch("Command+N"))
        #expect(!NeAntikShortcut.newFolder.matchesSearch("Command+N"))
        #expect(NeAntikShortcut.focusSelectedProfile.matchesSearch("браузера Shift+Command+Return"))
        #expect(!NeAntikShortcut.focusSelectedProfile.matchesSearch("заметку Shift+Command+Return"))
    }
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

    @Test func accessibilityChordsUseSpokenKeyNames() {
        #expect(
            NeAntikShortcut.toggleSelectedProfile.accessibilityChord ==
                "Command, Return"
        )
        #expect(
            NeAntikShortcut.focusSelectedProfile.accessibilityChord ==
                "Shift, Command, Return"
        )
        #expect(
            NeAntikShortcut.editSelectedNote.accessibilityChord ==
                "Option, Command, N"
        )
    }
}
