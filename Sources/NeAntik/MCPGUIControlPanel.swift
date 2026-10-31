import SwiftUI

/// No remembered blanket grants: each live connection is approved separately.
struct MCPGUIControlPanel: View {
    @ObservedObject var control: MCPGUIControlCoordinator
    @ObservedObject var store: ProfileStore
    @State private var selections: [UUID: Set<UUID>] = [:]
    private var profiles: [BrowserProfile] {
        store.hasTrustedMetadata ? store.profiles.filter { $0.engine == .webkit && !$0.isArchived } : []
    }
    var body: some View {
        GroupBox("Окна WebKit через AI") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Оставь NeAntik открытым. Включи доступ и попроси AI запустить профиль WebKit. Здесь появится запрос — выбери доступные профили и разреши подключение.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(control.isEnabled ? "Отключить доступ WebKit" : "Включить доступ WebKit") {
                    Task { if control.isEnabled { await control.disable() } else { await control.enable() } }
                }.disabled(control.isChanging)
                    .accessibilityLabel(Text(control.isEnabled ? "Отключить доступ WebKit" : "Включить доступ WebKit"))
                    .accessibilityIdentifier("mcp-gui-enable-toggle")
                    .help("Включает запросы доступа к профилям WebKit. Разрешение выдаётся отдельно каждому подключению и только на выбранные профили.")
                if control.isChanging { ProgressView().controlSize(.small) }
                if let message = control.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                ForEach(control.clients) { client in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Подключение \(String(client.id.uuidString.prefix(8)))") .font(.headline)
                        if client.isPending {
                            Text("Ожидает разрешения. Если открыто несколько AI-клиентов, разрешай только ожидаемый запрос.").font(.callout)
                            if profiles.isEmpty { Text("Сначала создай профиль с движком WebKit.").font(.callout) }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(profiles) { profile in
                                        Toggle(profile.name, isOn: Binding(get: { selections[client.id, default: []].contains(profile.id) }, set: { selected in
                                            if selected { selections[client.id, default: []].insert(profile.id) }
                                            else { selections[client.id]?.remove(profile.id) }
                                        })).toggleStyle(.checkbox)
                                            .accessibilityLabel(Text("Доступ к профилю \(profile.name)"))
                                            .accessibilityIdentifier("mcp-gui-profile-\(client.id.uuidString)-\(profile.id.uuidString)")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 160)
                            Button("Разрешить выбранные профили") {
                                control.approve(client.id, profiles: selections[client.id, default: []])
                            }.disabled(selections[client.id, default: []].isEmpty || selections[client.id, default: []].count > 64)
                                .accessibilityLabel("Разрешить выбранные профили")
                                .accessibilityIdentifier("mcp-gui-approve-\(client.id.uuidString)")
                                .help("Только это подключение получит право запускать выбранные профили и закрывать свои окна.")
                        } else {
                            Text("Разрешено профилей: \(client.approvedProfiles?.count ?? 0). Можно закрывать только окна, запущенные этим подключением.").font(.callout)
                        }
                        Button(client.isPending ? "Отклонить" : "Отозвать доступ") { control.revoke(client.id) }
                            .accessibilityLabel(Text(client.isPending ? "Отклонить подключение" : "Отозвать доступ подключения"))
                            .accessibilityIdentifier("mcp-gui-revoke-\(client.id.uuidString)")
                            .help("Прекращает управление через это подключение. Открытые окна остаются у тебя.")
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Отключение AI не закрывает окна. Повторное подключение требует нового разрешения. Содержимое страниц, cookies и пароли через этот канал не читаются.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        .onChange(of: control.clients.map(\.id)) { _, ids in selections = selections.filter { ids.contains($0.key) } }
    }
}
