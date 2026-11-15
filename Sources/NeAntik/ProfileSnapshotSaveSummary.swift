import Foundation

struct ProfileSnapshotSaveSummary: Equatable, Sendable {
    let savedProfileCount: Int
    let skippedRunningProfileCount: Int

    var statusMessage: String {
        var message = "Сохранены настройки " +
            Self.countPhrase(savedProfileCount) + "."
        if skippedRunningProfileCount > 0 {
            message += " Запущенные профили не включены: " +
                Self.countPhrase(skippedRunningProfileCount) + "."
        }
        message += " BrowserData и cookies не сохраняются. Хранятся последние 3 snapshot."
        return message
    }

    func localizedStatusMessage(bundle: Bundle = .main) -> String {
        let template = bundle.localizedString(forKey: "snapshot.saved", value: "", table: nil)
        guard !template.isEmpty, template != "snapshot.saved" else { return statusMessage }
        let savedTemplate = savedProfileCount == 1
            ? bundle.localizedString(forKey: "snapshot.saved.one", value: template, table: nil)
            : template
        var message = String(format: savedTemplate, savedProfileCount)
        if skippedRunningProfileCount > 0 {
            message += String(format: bundle.localizedString(
                forKey: "snapshot.skipped", value: " Running profiles excluded: %ld.", table: nil
            ), skippedRunningProfileCount)
        }
        message += bundle.localizedString(
            forKey: "snapshot.exclusions",
            value: " BrowserData and cookies are not saved. The last 3 snapshots are retained.", table: nil
        )
        return message
    }

    private static func countPhrase(_ count: Int) -> String {
        let remainder100 = count % 100
        let remainder10 = count % 10
        let noun: String
        if (11...14).contains(remainder100) {
            noun = "профилей"
        } else if remainder10 == 1 {
            noun = "профиль"
        } else if (2...4).contains(remainder10) {
            noun = "профиля"
        } else {
            noun = "профилей"
        }
        return String(count) + " " + noun
    }
}

/// Fixed system notices; names and other user-provided text are not localization keys.
enum WorkspaceSuccessMessage: String, CaseIterable {
    case profilesExported = "Экспортировано настроек профилей: %ld."
    case bookmarksImported = "Профиль создан. Закладок: %ld."
    case profilesImported = "Импортировано профилей: %ld."
    case snapshotRestored = "Создано профилей из снимка: %ld, с отдельными данными и новой конфигурацией среды."
    case diagnosticsSaved = "Безопасная диагностика сохранена."
    case encryptedExported = "Зашифрованный экспорт сохранён: %ld профилей."
    case encryptedImported = "Импортировано профилей из зашифрованного файла: %ld."

    func localized(count: Int = 0, bundle: Bundle = .main) -> String {
        var format = bundle.localizedString(forKey: rawValue, value: rawValue, table: nil)
        if self == .encryptedExported, count == 1 {
            format = bundle.localizedString(forKey: "workspace.encryptedExport.one", value: format, table: nil)
        }
        return self == .diagnosticsSaved ? format : String(format: format, count)
    }
}
