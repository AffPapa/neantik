import Foundation

/// Manifest requests only. A signature, the absence of warnings, or this
/// assessment cannot establish granted rights or publisher trust.
enum ExtensionPermissionRisk: String, CaseIterable, Identifiable, Sendable {
    case allSites, debugger, nativeMessaging, proxy, privacy, cookies, history, clipboard
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .allSites: NSLocalizedString("risk.allSites", tableName: "Pages", bundle: .main, value: "Запрашивается доступ ко всем сайтам: расширение может читать или менять страницы в пределах выданных прав.", comment: "")
        case .debugger: NSLocalizedString("risk.debugger", tableName: "Pages", bundle: .main, value: "Запрашивается отладочный доступ: он может давать широкие возможности наблюдения и управления вкладками.", comment: "")
        case .nativeMessaging: NSLocalizedString("risk.nativeMessaging", tableName: "Pages", bundle: .main, value: "Запрашивается связь с отдельной программой на Mac. Возможности зависят от установленного native host.", comment: "")
        case .proxy: NSLocalizedString("risk.proxy", tableName: "Pages", bundle: .main, value: "Запрашивается управление прокси браузера. Оно может конфликтовать с выбранным маршрутом профиля.", comment: "")
        case .privacy: NSLocalizedString("risk.privacy", tableName: "Pages", bundle: .main, value: "Запрашивается изменение настроек приватности. Проверяй фактическую политику профиля после установки.", comment: "")
        case .cookies: NSLocalizedString("risk.cookies", tableName: "Pages", bundle: .main, value: "Запрашивается доступ к cookies на разрешённых сайтах, включая данные сеанса.", comment: "")
        case .history: NSLocalizedString("risk.history", tableName: "Pages", bundle: .main, value: "Запрашивается доступ к истории посещений этого профиля.", comment: "")
        case .clipboard: NSLocalizedString("risk.clipboard", tableName: "Pages", bundle: .main, value: "Запрашивается чтение буфера обмена Mac, который используется и другими приложениями.", comment: "")
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
