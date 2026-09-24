import Foundation

struct ProfileSnapshotSaveSummary: Equatable, Sendable {
    let savedProfileCount: Int
    let skippedRunningProfileCount: Int

    var announcement: String {
        var message = "Сохранены настройки " +
            Self.countPhrase(savedProfileCount) + "."
        if skippedRunningProfileCount > 0 {
            message += " Запущенные профили не включены: " +
                Self.countPhrase(skippedRunningProfileCount) + "."
        }
        message += " BrowserData и cookies не сохраняются. Хранятся последние 3 snapshot."
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
