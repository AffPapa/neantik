import Foundation

enum MCPClient: String, CaseIterable, Identifiable {
    case claudeDesktop, chatGPTCodex, claudeCode, grokCLI, cursor, vscode, geminiCLI
    var id: Self { self }
    var title: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .chatGPTCodex: "ChatGPT Desktop / Codex"
        case .claudeCode: "Claude Code"
        case .grokCLI: "Grok CLI"
        case .cursor: "Cursor"
        case .vscode: "VS Code / Copilot"
        case .geminiCLI: "Gemini CLI"
        }
    }
    var steps: String {
        switch self {
        case .claudeDesktop: "Settings → Developer → Edit Config. Добавь JSON к остальным mcpServers, сохрани и полностью перезапусти Claude."
        case .chatGPTCodex: "ChatGPT Desktop: Settings → MCP servers → Add server → STDIO. Либо добавь TOML к ~/.codex/config.toml. Перезапусти клиент; проверь codex mcp list. Web-чат не читает этот файл."
        case .claudeCode: "Выполни команду добавления в Terminal на этом Mac. Затем claude mcp list; внутри чата — /mcp."
        case .grokCLI: "Выполни команду добавления в Terminal на этом Mac. Затем grok mcp doctor neantik; внутри чата — /mcps. Grok web требует другого транспорта."
        case .cursor: "Добавь JSON в ~/.cursor/mcp.json или .cursor/mcp.json проекта. Открой настройки MCP, включи NeAntik и выбери его инструменты в агентном чате."
        case .vscode: "Добавь JSON в .vscode/mcp.json. Command Palette → MCP: List Servers → NeAntik → Start. Выбери инструменты в агентном чате. Сервер должен запускаться на Mac, не в удалённом Linux-контейнере."
        case .geminiCLI: "Добавь JSON к ~/.gemini/settings.json. trust:false сохраняет подтверждения клиента. Перезапусти Gemini CLI; проверь gemini mcp list или /mcp."
        }
    }
    var source: URL {
        let value: String
        switch self {
        case .claudeDesktop: value = "https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop"
        case .chatGPTCodex: value = "https://learn.chatgpt.com/docs/extend/mcp?surface=cli"
        case .claudeCode: value = "https://code.claude.com/docs/en/mcp"
        case .grokCLI: value = "https://docs.x.ai/build/features/mcp-servers"
        case .cursor: value = "https://cursor.com/docs/mcp"
        case .vscode: value = "https://code.visualstudio.com/docs/agents/reference/mcp-configuration"
        case .geminiCLI: value = "https://geminicli.com/docs/tools/mcp-server/"
        }
        return URL(string: value)!
    }
}

extension MCPConnectionConfiguration {
    func configuration(for client: MCPClient) -> String {
        if client == .chatGPTCodex { return codexTOML + "default_tools_approval_mode = \"writes\"\n" }
        if client == .claudeCode || client == .grokCLI {
            let prefix = client == .claudeCode ? "claude mcp add --transport stdio --scope user neantik -- " : "grok mcp add neantik -- "
            return prefix + ([executable.path] + arguments).map(Self.shellLiteral).joined(separator: " ")
        }
        var server: [String: Any] = ["command": executable.path, "args": arguments]
        if client == .vscode { server["type"] = "stdio" }
        if client == .geminiCLI { server["trust"] = false }
        let object = [client == .vscode ? "servers" : "mcpServers": ["neantik": server]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    /// Generated commands are never executed by NeAntik. Every argv element is
    /// a shell literal, including spaces/quotes in a user's chosen app path.
    private static func shellLiteral(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
