import Foundation

/// Manifest requests only. A signature, the absence of warnings, or this
/// assessment cannot establish granted rights or publisher trust.
enum ExtensionPermissionRisk: String, CaseIterable, Identifiable, Sendable {
    case allSites, debugger, nativeMessaging, proxy, privacy, cookies, history, clipboard
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .allSites: "Запрашивается доступ ко всем сайтам: расширение может читать или менять страницы в пределах выданных прав."
        case .debugger: "Запрашивается отладочный доступ: он может давать широкие возможности наблюдения и управления вкладками."
        case .nativeMessaging: "Запрашивается связь с отдельной программой на Mac. Возможности зависят от установленного native host."
        case .proxy: "Запрашивается управление прокси браузера. Оно может конфликтовать с выбранным маршрутом профиля."
        case .privacy: "Запрашивается изменение настроек приватности. Проверяй фактическую политику профиля после установки."
        case .cookies: "Запрашивается доступ к cookies на разрешённых сайтах, включая данные сеанса."
        case .history: "Запрашивается доступ к истории посещений этого профиля."
        case .clipboard: "Запрашивается чтение буфера обмена Mac, который используется и другими приложениями."
        }
    }
}

enum ExtensionPermissionRiskAssessment {
    static func warnings(for requests: [String]) -> [ExtensionPermissionRisk] {
        let values = Set(requests)
        var risks: Set<ExtensionPermissionRisk> = []
        if !values.isDisjoint(with: ["<all_urls>", "*://*/*", "https://*/*", "http://*/*"]) {
            risks.insert(.allSites)
        }
        for (permission, risk) in [
            ("debugger", ExtensionPermissionRisk.debugger),
            ("nativeMessaging", .nativeMessaging), ("proxy", .proxy),
            ("privacy", .privacy), ("cookies", .cookies),
            ("history", .history), ("clipboardRead", .clipboard)
        ] where values.contains(permission) { risks.insert(risk) }
        return ExtensionPermissionRisk.allCases.filter { risks.contains($0) }
    }
}
