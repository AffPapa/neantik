import AppKit
import SwiftUI

@MainActor
final class HelpNavigation: ObservableObject {
    @Published var topic: HelpTopic = .profiles
}

struct HelpLink: View {
    let topic: HelpTopic
    @EnvironmentObject private var navigation: HelpNavigation
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button {
            navigation.topic = topic
            openWindow(id: "help")
        } label: {
            Label("Справка", systemImage: "questionmark.circle")
        }
        .help("Справка: \(topic.title)")
        .accessibilityLabel("Справка: \(topic.title)")
    }
}

struct NeAntikHelpCommands: Commands {
    @ObservedObject var navigation: HelpNavigation
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Справка NeAntik") { openWindow(id: "help") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            Button("Подключить MCP к AI…") {
                navigation.topic = .mcp
                openWindow(id: "help")
            }
        }
    }
}

struct NeAntikHelpWindow: View {
    @ObservedObject var navigation: HelpNavigation
    let connection: MCPConnectionConfiguration
    @State private var search = ""
    @State private var configurationFormat = 0
    @State private var copied = false
    @FocusState private var searchFocused: Bool

    private var topics: [HelpTopic] { HelpTopic.matching(search) }
    private var selected: HelpTopic? { topics.contains(navigation.topic) ? navigation.topic : topics.first }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Найти в справке", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Поиск в справке")
                    .focused($searchFocused)
                if topics.isEmpty {
                    Text("Ничего не найдено").font(.headline)
                    Button("Очистить поиск") { search = "" }
                } else {
                    List(selection: Binding<HelpTopic?>(get: { selected }, set: { if let topic = $0 { navigation.topic = topic } })) {
                        ForEach(topics) { topic in
                            Text(topic.title)
                                .font(.system(size: 14))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 6)
                                .help(topic.title)
                                .tag(topic)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .padding(16)
            .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            if let topic = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(topic.title).font(.title2.bold())
                        Text(topic.introduction).font(.body)
                        if topic == .mcp { connectionPanel }
                        ForEach(Array(topic.sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(section.title).font(.headline)
                                Text(section.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: 740, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .id(topic)
                .frame(minWidth: 460)
            } else {
                Text("Попробуй другой запрос: прокси, снимок, клавиатура или MCP.")
                    .padding(24).frame(minWidth: 460, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 740, minHeight: 480)
        .onChange(of: navigation.topic) { _, _ in search = ""; copied = false }
        .onChange(of: configurationFormat) { _, _ in copied = false }
        .toolbar {
            Button("Найти в справке") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
        }
    }

    private var connectionPanel: some View {
        GroupBox("Настройка этого workspace") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Скопируй блок в настройки клиента, сохранив остальные серверы. Он содержит локальные пути этого приложения.")
                Picker("Формат клиента", selection: $configurationFormat) {
                    Text("Claude Desktop / JSON").tag(0)
                    Text("Codex / TOML").tag(1)
                }.pickerStyle(.segmented)
                Text(configurationFormat == 0 ? connection.claudeJSON : connection.codexTOML)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Настройка скопирована" : "Скопировать настройку MCP") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(configurationFormat == 0 ? connection.claudeJSON : connection.codexTOML, forType: .string)
                }
                Text("Чтение названий и тегов — осознанный доступ выбранного AI-клиента. Этот блок не включает пароли или данные сайтов.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}
