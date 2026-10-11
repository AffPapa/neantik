import AppKit
import SwiftUI

/// A closed-profile metadata view. Chromium remains the authority for actions
/// and effective permissions; this view never rewrites browser preferences.
struct ProfileExtensionsSheet: View {
    let profile: BrowserProfile
    let paths: AppPaths
    @ObservedObject var processes: BrowserProcessManager
    let validateSnapshot: @MainActor () async throws -> Bool
    let manageInBrowser: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ProfileExtensionSnapshot?
    @State private var selectedID: String?
    @State private var query = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID: UUID?

    private var records: [ProfileExtensionRecord] {
        guard let snapshot else { return [] }
        return snapshot.records.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
    private var selected: ProfileExtensionRecord? { records.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Расширения профиля").font(.title2.bold())
                    Text(profile.name).font(.headline).lineLimit(2)
                }
                Spacer()
                Button("Обновить", systemImage: "arrow.clockwise", action: refresh).disabled(busy)
            }
            Text("Список из сохранённых настроек закрытого профиля. Установка, переключатели и удаление доступны в браузере.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if busy {
                HStack { ProgressView().controlSize(.small); Text("Читаем список расширений…") }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let snapshot {
                if snapshot.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Нет расширений в сохранённых настройках").font(.headline)
                        Text("Открой управление в браузере, чтобы установить расширение или проверить список.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    TextField("Поиск по названию или ID", text: $query)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Поиск расширений")
                    HStack(alignment: .top, spacing: 16) {
                        List(selection: $selectedID) {
                            ForEach(records) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name).font(.headline).lineLimit(2)
                                    Text([record.version.map { "Версия \($0)" }, stateText(record.state)].compactMap { $0 }.joined(separator: " · "))
                                        .foregroundStyle(.secondary).font(.subheadline)
                                }.padding(.vertical, 4).tag(record.id)
                            }
                        }.frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                        ScrollView {
                            if let selected { details(selected) }
                            else { Text(records.isEmpty ? "Ничего не найдено" : "Выбери расширение слева").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 210, idealHeight: 290, maxHeight: 400)
                }
                if snapshot.omittedRecords > 0 {
                    Text("Некоторые записи не удалось распознать: \(snapshot.omittedRecords). Проверь их в браузере.")
                        .foregroundStyle(.secondary)
                }
                if snapshot.packageCount > 0 {
                    Text("Папок пакетов на диске: \(snapshot.packageCount). Они могут оставаться после удаления и не доказывают, что расширение установлено.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Text("В браузере: меню ⋮ → Расширения → Управление расширениями. Или вставь этот адрес в адресную строку:")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Копировать адрес") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("chrome://extensions/", forType: .string)
                }.help("Копирует chrome://extensions/ без данных профиля.")
            }
            Divider()
            HStack {
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Открыть браузер", systemImage: "arrow.up.forward.app", action: manageInBrowser)
                    .keyboardShortcut(.defaultAction).disabled(busy)
                    .help("Откроется пустая вкладка в этом профиле. Перейди к расширениям через меню или вставь скопированный адрес. Стартовая страница и сеть не изменятся.")
            }
        }
        .padding(24).frame(minWidth: 680, idealWidth: 800, maxWidth: 980, minHeight: 330)
        .task { refresh() }
        .onDisappear { requestID = nil; task?.cancel() }
    }

    private func details(_ record: ProfileExtensionRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.name).font(.headline)
            Text(record.id).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            LabeledContent("Сохранённый статус", value: stateText(record.state))
            LabeledContent("Источник установки", value: sourceText(record.source))
            if let version = record.version { LabeledContent("Версия", value: version) }
            if let manifest = record.manifestVersion { LabeledContent("Manifest", value: String(manifest)) }
            if record.conflictingMetadata {
                Text("Сохранённые записи расходятся. Актуальный статус проверь в браузере.").foregroundStyle(.orange)
            } else if record.metadataNeedsBrowser {
                Text("Название или сведения отсутствуют в сохранённых настройках. Проверь их в браузере.").foregroundStyle(.secondary)
            }
            Divider()
            Text("Запрошенные разрешения").font(.headline)
            permissionList(record.permissions, empty: "В сохранённом manifest разрешения не указаны.")
            if !record.optionalPermissions.isEmpty {
                Text("Необязательные разрешения").font(.headline)
                permissionList(record.optionalPermissions, empty: "Нет")
            }
            Text("Это запросы из manifest, а не список выданных прав. Они не подтверждают безопасность расширения; фактический доступ смотри в Chromium.")
                .font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionList(_ values: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if values.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private func stateText(_ state: ProfileExtensionRecord.State) -> String {
        switch state { case .enabled: "Включено"; case .disabled: "Отключено"; case .unknown: "Уточни в браузере" }
    }
    private func sourceText(_ source: ProfileExtensionRecord.Source) -> String {
        switch source { case .unpacked: "Папка разработчика"; case .packaged: "Пакет"; case .other: "Другой способ"; case .unknown: "Не указан" }
    }

    private func refresh() {
        task?.cancel()
        let id = UUID(); requestID = id
        busy = true; errorMessage = nil; snapshot = nil
        let browserData = paths.browserDataDirectory(for: profile.id)
        task = Task { @MainActor in
            defer { if requestID == id { busy = false; task = nil } }
            do {
                guard try await validateSnapshot() else { throw BrowserProfileRevisionConflictError(profileID: profile.id) }
                try Task.checkCancellation()
                let result = try await processes.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
                    try authority.validate(browserData: browserData)
                    let result = try ProfileExtensionInventory.scan(browserData: browserData)
                    try authority.validate(browserData: browserData)
                    return result
                }
                guard requestID == id else { return }
                guard try await validateSnapshot() else { throw BrowserProfileRevisionConflictError(profileID: profile.id) }
                snapshot = result
                if !result.records.contains(where: { $0.id == selectedID }) { selectedID = result.records.first?.id }
            } catch is CancellationError {
                if requestID == id { errorMessage = "Чтение отменено. Обнови список, чтобы повторить." }
            } catch {
                if requestID == id { errorMessage = error.localizedDescription }
            }
        }
    }
}
