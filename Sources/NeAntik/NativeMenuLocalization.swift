import AppKit

/// Localizes the AppKit menu tree SwiftUI creates for a package-built app.
///
/// `ru.lproj` makes the bundle correctly advertise Russian, but the generated
/// SwiftUI main menu can still arrive in English on newer macOS toolchains.
/// Titles are changed in place; selectors, shortcuts, validation and standard
/// responder-chain behavior remain native.
@MainActor
enum NativeMenuLocalization {
    private static let exactTitles: [String: String] = [
        "File": "Файл",
        "Edit": "Правка",
        "View": "Вид",
        "Window": "Окно",
        "Help": "Справка",
        "Services": "Службы",
        "Settings…": "Настройки…",
        "Services Settings…": "Настройки служб…",
        "Hide Others": "Скрыть остальные",
        "Show All": "Показать все",
        "Close": "Закрыть",
        "Close All": "Закрыть все",
        "Undo": "Отменить",
        "Redo": "Повторить",
        "Cut": "Вырезать",
        "Copy": "Копировать",
        "Paste": "Вставить",
        "Delete": "Удалить",
        "Select All": "Выбрать все",
        "AutoFill": "Автозаполнение",
        "Contact…": "Контакт…",
        "Passwords…": "Пароли…",
        "Credit Card…": "Банковская карта…",
        "Start Dictation…": "Начать диктовку…",
        "Emoji & Symbols": "Эмодзи и символы",
        "Show Tab Bar": "Показать панель вкладок",
        "Show All Tabs": "Показать все вкладки",
        "Enter Full Screen": "Перейти в полноэкранный режим",
        "Minimize": "Свернуть",
        "Minimize All": "Свернуть все",
        "Zoom": "Масштаб",
        "Zoom All": "Масштабировать все",
        "Fill": "Заполнить",
        "Center": "По центру",
        "Move & Resize": "Переместить и изменить размер",
        "Halves": "Половины",
        "Left": "Слева",
        "Right": "Справа",
        "Top": "Сверху",
        "Bottom": "Снизу",
        "Quarters": "Четверти",
        "Top Left": "Сверху слева",
        "Top Right": "Сверху справа",
        "Bottom Left": "Снизу слева",
        "Bottom Right": "Снизу справа",
        "Arrange": "Упорядочить",
        "Left & Right": "Слева и справа",
        "Left & Quarters": "Слева и четверти",
        "Right & Left": "Справа и слева",
        "Right & Quarters": "Справа и четверти",
        "Top & Bottom": "Сверху и снизу",
        "Top & Quarters": "Сверху и четверти",
        "Bottom & Top": "Снизу и сверху",
        "Bottom & Quarters": "Снизу и четверти",
        "Return to Previous Size": "Вернуть прежний размер",
        "Full Screen Tile": "Разместить в полноэкранном режиме",
        "Bring All to Front": "Все окна — на передний план",
        "Arrange in Front": "Упорядочить окна",
        "Remove Window from Set": "Убрать окно из набора",
        "Show Previous Tab": "Показать предыдущую вкладку",
        "Show Next Tab": "Показать следующую вкладку",
        "Move Tab to New Window": "Переместить вкладку в новое окно",
        "Merge All Windows": "Объединить все окна",
    ]

    static func apply() {
        guard let menu = NSApp.mainMenu else { return }
        let appName = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String ?? "NeAntik"
        localize(menu, appName: appName)
    }

    static func applyAfterMenuCreation() {
        Task { @MainActor in
            await Task.yield()
            apply()
        }
    }

    static func localizedTitle(
        _ title: String,
        appName: String
    ) -> String {
        if title == "About \(appName)" {
            return "О приложении \(appName)"
        }
        if title == "Hide \(appName)" {
            return "Скрыть \(appName)"
        }
        if title == "Quit \(appName)" {
            return "Завершить \(appName)"
        }
        if title == "\(appName) Help" {
            return "Справка \(appName)"
        }
        if title == "Send \(appName) Feedback to Apple" {
            return "Отправить отзыв о \(appName) в Apple"
        }
        return exactTitles[title] ?? title
    }

    private static func localize(_ menu: NSMenu, appName: String) {
        for item in menu.items {
            item.title = localizedTitle(item.title, appName: appName)
            if let submenu = item.submenu {
                localize(submenu, appName: appName)
            }
        }
    }
}
