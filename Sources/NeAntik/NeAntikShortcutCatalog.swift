import SwiftUI

enum NeAntikShortcutCategory: String, CaseIterable, Identifiable {
    case workspace
    case profile

    var id: Self { self }

    var title: String {
        switch self {
        case .workspace: "Рабочее пространство"
        case .profile: "Выбранный профиль"
        }
    }
}

/// One fixed, menu-backed shortcut catalog for the app and its Settings pane.
///
/// Shortcuts stay local to the focused NeAntik window. Destructive operations,
/// proxy credentials and release actions intentionally have no shortcut.
enum NeAntikShortcut: String, CaseIterable, Identifiable {
    case newProfile
    case newFolder
    case findProfiles
    case settings
    case shortcutReference
    case toggleSelectedProfile
    case editSelectedProfile
    case editSelectedNote
    case toggleInspector
    case duplicateProfile

    var id: Self { self }

    var category: NeAntikShortcutCategory {
        switch self {
        case .newProfile, .newFolder, .findProfiles, .settings,
             .shortcutReference:
            .workspace
        case .toggleSelectedProfile, .editSelectedProfile,
             .editSelectedNote, .toggleInspector, .duplicateProfile:
            .profile
        }
    }

    var title: String {
        switch self {
        case .newProfile: "Новый профиль"
        case .newFolder: "Новая папка"
        case .findProfiles: "Найти профиль"
        case .settings: "Открыть настройки"
        case .shortcutReference: "Показать сочетания клавиш"
        case .toggleSelectedProfile: "Запустить или остановить"
        case .editSelectedProfile: "Изменить профиль"
        case .editSelectedNote: "Изменить заметку"
        case .toggleInspector: "Показать или скрыть сведения"
        case .duplicateProfile: "Создать похожий"
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .toggleSelectedProfile:
            .return
        case .newProfile, .editSelectedNote:
            "n"
        case .newFolder:
            "n"
        case .findProfiles:
            "f"
        case .settings:
            ","
        case .shortcutReference:
            "/"
        case .editSelectedProfile:
            "e"
        case .toggleInspector:
            "i"
        case .duplicateProfile:
            "d"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .newFolder:
            [.command, .shift]
        case .editSelectedProfile, .editSelectedNote:
            [.command, .option]
        default:
            [.command]
        }
    }

    var displayChord: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch self {
        case .toggleSelectedProfile:
            result += "↩"
        default:
            result += String(keyEquivalent.character).uppercased()
        }
        return result
    }

    var chordIdentifier: String {
        [
            modifiers.contains(.control) ? "control" : nil,
            modifiers.contains(.option) ? "option" : nil,
            modifiers.contains(.shift) ? "shift" : nil,
            modifiers.contains(.command) ? "command" : nil,
            String(keyEquivalent.character).lowercased(),
        ]
        .compactMap { $0 }
        .joined(separator: "+")
    }
}
