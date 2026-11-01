import Foundation
import Testing
@testable import NeAntik

struct HelpContentTests {
    @Test func profileHelpExplainsDisposableDataRetention() {
        #expect(!HelpTopic.profiles.introduction.contains("постоянная сессия"))
        let section = HelpTopic.profiles.sections.first { $0.title == "Одноразовый сеанс" }
        #expect(section?.text.contains("удаляет данные сайтов") == true)
        #expect(section?.text.contains("скачанные файлы и экспорт сохраняются") == true)
        #expect(section?.text.contains("повторный запуск блокируется") == true)
        #expect(HelpTopic.matching("Одноразовый сеанс").contains(.profiles))
    }
    @Test func searchFindsTasksInsideArticles() {
        #expect(HelpTopic.matching("429").contains(.proxy))
        #expect(HelpTopic.matching("СНИМОК").contains(.storage))
        #expect(HelpTopic.matching("nextCursor").contains(.mcp))
        #expect(HelpTopic.matching("  ") == HelpTopic.allCases)
        #expect(HelpTopic.matching("nonexistent-synthetic-term").isEmpty)
    }

    @Test func proxyHelpMatchesAvailableWebKitRoute() {
        let proxyHelp = HelpTopic.mcp.sections.map(\.text).joined(separator: " ")
        if !BrowserEngine.webkit.isAvailableInBuild {
            #expect(proxyHelp.contains("WebKit-профили в этом выпуске не запускаются"))
            #expect(proxyHelp.contains("не подтверждает маршрут окна"))
            #expect(!HelpTopic.mcp.sections.map(\.title).contains("WebKit через AI"))
        } else if WebKitProxyFeature.launchEnabled {
            #expect(proxyHelp.contains("профиль с прокси использует отдельный встроенный runtime"))
            #expect(proxyHelp.contains("не подтверждают фактический маршрут окна"))
        } else {
            #expect(proxyHelp.contains("WebKit-профиль с прокси не запускается"))
            #expect(proxyHelp.contains("прямое подключение вместо прокси не используется"))
        }
        #expect(!proxyHelp.contains("настройки применяются к отдельному хранилищу сайтов"))
    }

    @Test func mcpHelpRecommendsLocalProxyCredentialEntry() {
        let text = HelpTopic.mcp.sections.map(\.text).joined(separator: " ")
        #expect(text.contains("Безопаснее передавать через MCP только тип, адрес и порт прокси"))
        #expect(text.contains("логин и пароль вводить в локальном редакторе профиля NeAntik"))
        #expect(text.contains("username/password и строки с логином/паролем отклоняются"))
        #expect(!text.contains("profile_set_proxy принимает отдельные поля kind/host/port/username/password"))
        let examples = HelpTopic.mcp.sections.first { $0.title == "Примеры для чата" }?.text ?? ""
        #expect(examples.contains("через MCP только по типу, адресу и порту"))
        #expect(examples.contains("Логин и пароль я введу локально в NeAntik"))
        #expect(!examples.contains("из моих настроек"))
    }

    @Test func chromiumOnlyHelpDoesNotOfferWebKitLaunch() {
        guard !BrowserEngine.webkit.isAvailableInBuild else { return }
        let profiles = HelpTopic.profiles.sections
        #expect(profiles.contains { $0.title == "Движок браузера" && $0.text.contains("не запускает и не дублирует") })
        #expect(!profiles.contains { $0.title == "Chromium или WebKit" || $0.title == "Загрузки в WebKit" })
        #expect(!HelpTopic.mcp.sections.contains { $0.title == "WebKit через AI" })
    }

    @Test func copiedConfigurationUsesExactResolvedWorkspaceAndEscapesClientFormats() throws {
        let executable = URL(fileURLWithPath: "/private/tmp/NeAntik \"QA\".app/Contents/MacOS/NeAntik")
        let root = URL(fileURLWithPath: "/private/tmp/neantik-legacy \"root\"", isDirectory: true)
        let configuration = MCPConnectionConfiguration(executable: executable, dataRoot: root)
        let json = try #require(JSONSerialization.jsonObject(with: Data(configuration.claudeJSON.utf8)) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: Any])
        let server = try #require(servers["neantik"] as? [String: Any])
        let command = try #require(server["command"] as? String)
        let args = try #require(server["args"] as? [String])
        #expect(command == executable.path)
        #expect(NeAntikLaunchIntent.parse(arguments: [command] + args).mode == .mcpManagement(dataRoot: root))
        #expect(configuration.codexTOML.contains("\\\"QA\\\""))
        #expect(configuration.codexTOML.contains("\\\"root\\\""))
        #expect(!configuration.codexTOML.contains("password"))
    }
}
