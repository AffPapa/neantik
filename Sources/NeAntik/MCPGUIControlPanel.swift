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
        GroupBox(NSLocalizedString("page.680", tableName: "Pages", bundle: .main, value: "Окна WebKit через AI", comment: "")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(NSLocalizedString("page.681", tableName: "Pages", bundle: .main, value: "Оставь NeAntik открытым. Включи доступ и попроси AI запустить профиль WebKit. Здесь появится запрос — выбери доступные профили и разреши подключение.", comment: ""))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(control.isEnabled ? NSLocalizedString("page.682", tableName: "Pages", bundle: .main, value: "Отключить доступ WebKit", comment: "") : NSLocalizedString("page.683", tableName: "Pages", bundle: .main, value: "Включить доступ WebKit", comment: "")) {
                    Task { if control.isEnabled { await control.disable() } else { await control.enable() } }
                }.disabled(control.isChanging)
                    .accessibilityLabel(Text(control.isEnabled ? NSLocalizedString("page.682", tableName: "Pages", bundle: .main, value: "Отключить доступ WebKit", comment: "") : NSLocalizedString("page.683", tableName: "Pages", bundle: .main, value: "Включить доступ WebKit", comment: "")))
                    .accessibilityIdentifier("mcp-gui-enable-toggle")
                    .help(NSLocalizedString("page.684", tableName: "Pages", bundle: .main, value: "Включает запросы доступа к профилям WebKit. Разрешение выдаётся отдельно каждому подключению и только на выбранные профили.", comment: ""))
                if control.isChanging { ProgressView().controlSize(.small) }
                if let message = control.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                ForEach(control.clients) { client in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("page.685", tableName: "Pages", bundle: .main, value: "Подключение %@", comment: ""), String(describing: String(client.id.uuidString.prefix(8))))) .font(.headline)
                        if client.isPending {
                            Text(NSLocalizedString("page.686", tableName: "Pages", bundle: .main, value: "Ожидает разрешения. Если открыто несколько AI-клиентов, разрешай только ожидаемый запрос.", comment: "")).font(.callout)
                            if profiles.isEmpty { Text(NSLocalizedString("page.687", tableName: "Pages", bundle: .main, value: "Сначала создай профиль с движком WebKit.", comment: "")).font(.callout) }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(profiles) { profile in
                                        Toggle(profile.name, isOn: Binding(get: { selections[client.id, default: []].contains(profile.id) }, set: { selected in
                                            if selected { selections[client.id, default: []].insert(profile.id) }
                                            else { selections[client.id]?.remove(profile.id) }
                                        })).toggleStyle(.checkbox)
                                            .accessibilityLabel(Text(String(format: NSLocalizedString("page.688", tableName: "Pages", bundle: .main, value: "Доступ к профилю %@", comment: ""), String(describing: profile.name))))
                                            .accessibilityIdentifier("mcp-gui-profile-\(client.id.uuidString)-\(profile.id.uuidString)")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 160)
                            Button(NSLocalizedString("page.689", tableName: "Pages", bundle: .main, value: "Разрешить выбранные профили", comment: "")) {
                                control.approve(client.id, profiles: selections[client.id, default: []])
                            }.disabled(selections[client.id, default: []].isEmpty || selections[client.id, default: []].count > 64)
                                .accessibilityLabel(NSLocalizedString("page.689", tableName: "Pages", bundle: .main, value: "Разрешить выбранные профили", comment: ""))
                                .accessibilityIdentifier("mcp-gui-approve-\(client.id.uuidString)")
                                .help(NSLocalizedString("page.690", tableName: "Pages", bundle: .main, value: "Только это подключение получит право запускать выбранные профили и закрывать свои окна.", comment: ""))
                        } else {
                            Text(String(format: NSLocalizedString("page.691", tableName: "Pages", bundle: .main, value: "Разрешено профилей: %@. Можно закрывать только окна, запущенные этим подключением.", comment: ""), String(describing: client.approvedProfiles?.count ?? 0))).font(.callout)
                        }
                        Button(client.isPending ? NSLocalizedString("page.692", tableName: "Pages", bundle: .main, value: "Отклонить", comment: "") : NSLocalizedString("page.693", tableName: "Pages", bundle: .main, value: "Отозвать доступ", comment: "")) { control.revoke(client.id) }
                            .accessibilityLabel(Text(client.isPending ? NSLocalizedString("page.694", tableName: "Pages", bundle: .main, value: "Отклонить подключение", comment: "") : NSLocalizedString("page.695", tableName: "Pages", bundle: .main, value: "Отозвать доступ подключения", comment: "")))
                            .accessibilityIdentifier("mcp-gui-revoke-\(client.id.uuidString)")
                            .help(NSLocalizedString("page.696", tableName: "Pages", bundle: .main, value: "Прекращает управление через это подключение. Открытые окна остаются у тебя.", comment: ""))
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(NSLocalizedString("page.697", tableName: "Pages", bundle: .main, value: "Отключение AI не закрывает окна. Повторное подключение требует нового разрешения. Содержимое страниц, cookies и пароли через этот канал не читаются.", comment: ""))
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        .onChange(of: control.clients.map(\.id)) { _, ids in selections = selections.filter { ids.contains($0.key) } }
    }
}
