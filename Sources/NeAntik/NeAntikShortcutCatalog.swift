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

extension NeAntikShortcut {
    /// Reference text, not a second authorization model: menu state remains authoritative.
    var availability: String {
        switch self {
        case .newProfile, .newFolder, .findProfiles:
            "В главном окне, когда не открыт диалог"
        case .settings:
            "В активном приложении NeAntik"
        case .shortcutReference:
            "В главном окне, когда не открыт диалог"
        case .toggleSelectedProfile:
            "Для выбранного профиля; доступность запуска определяется проверками"
        case .focusSelectedProfile:
            "Только для выбранного запущенного профиля"
        case .editSelectedProfile:
            "Для выбранного профиля вне перехода запуска или остановки"
        case .editSelectedNote, .toggleInspector, .duplicateProfile:
            "Когда выбран профиль в главном окне"
        }
    }

    func matchesSearch(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        let searchable = [title, category.title, displayChord,
                          accessibilityChord, chordIdentifier, availability]
            .joined(separator: " ")
        return terms.allSatisfy {
            searchable.localizedStandardContains(String($0))
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
    case focusSelectedProfile
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
        case .toggleSelectedProfile, .focusSelectedProfile,
             .editSelectedProfile,
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
        case .focusSelectedProfile: "Показать окно браузера"
        case .editSelectedProfile: "Изменить профиль"
        case .editSelectedNote: "Изменить заметку"
        case .toggleInspector: "Показать или скрыть сведения"
        case .duplicateProfile: "Создать похожий"
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .toggleSelectedProfile, .focusSelectedProfile:
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
        case .newFolder, .focusSelectedProfile:
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
        case .toggleSelectedProfile, .focusSelectedProfile:
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

    var accessibilityChord: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        switch self {
        case .toggleSelectedProfile, .focusSelectedProfile:
            parts.append("Return")
        default:
            parts.append(String(keyEquivalent.character).uppercased())
        }
        return parts.joined(separator: ", ")
    }
}
