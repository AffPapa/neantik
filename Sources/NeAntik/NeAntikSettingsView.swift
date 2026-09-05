import SwiftUI

struct NeAntikSettingsView: View {
    @ObservedObject var preferences: WorkspacePreferenceStore
    @State private var shortcutQuery = ""
    @FocusState private var shortcutSearchIsFocused: Bool

    private var matchingShortcuts: [NeAntikShortcut] {
        NeAntikShortcut.allCases.filter { $0.matchesSearch(shortcutQuery) }
    }

    var body: some View {
        let shortcuts = matchingShortcuts
        Form {
            Section("Интерфейс") {
                Picker("Плотность списка", selection: $preferences.rowDensity) {
                    ForEach(ProfileRowDensity.allCases) { density in
                        Label(density.title, systemImage: density.systemImage)
                            .tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint(
                    "Изменение сразу применяется к списку профилей"
                )

                DisclosureGroup("Предпросмотр плотности") {
                    densityPreview
                }

                Button("Вернуть удобную плотность") {
                    preferences.resetInterface()
                }
                .disabled(preferences.rowDensity == .comfortable)
                .help("Меняет только плотность списка. Профили, заметки и прокси не затрагиваются.")
                Text("Сброс меняет только плотность — данные профилей останутся прежними.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Сочетания клавиш") {
                HStack {
                    Button {
                        shortcutSearchIsFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("Найти сочетание клавиш")
                    .help("Найти сочетание клавиш (⌘F)")

                    TextField("Найти команду, клавиши или раздел", text: $shortcutQuery)
                        .accessibilityLabel("Поиск сочетаний клавиш")
                        .focused($shortcutSearchIsFocused)
                        .onExitCommand {
                            if shortcutQuery.isEmpty {
                                shortcutSearchIsFocused = false
                            } else {
                                shortcutQuery = ""
                            }
                        }
                    if !shortcutQuery.isEmpty {
                        Button {
                            clearShortcutSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Очистить поиск сочетаний клавиш")
                        .help("Очистить поиск")
                    }
                }
                if shortcuts.isEmpty {
                    Text("Сочетания не найдены")
                    Text("Попробуй название команды или клавиши.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Очистить поиск", action: clearShortcutSearch)
                } else if !shortcutQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Найдено сочетаний: \(shortcuts.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(NeAntikShortcutCategory.allCases) { category in
                    let group = shortcuts.filter { $0.category == category }
                    if !group.isEmpty {
                        shortcutGroup(category, shortcuts: group)
                    }
                }

                Text(
                    "Сочетания фиксированы, видны в меню и работают только " +
                        "в активном NeAntik. Опасные действия не имеют " +
                        "горячих клавиш. Escape закрывает диалоги; в поиске " +
                        "сначала очищает запрос, затем освобождает фокус."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .navigationTitle("Настройки NeAntik")
    }

    private func clearShortcutSearch() {
        shortcutQuery = ""
        shortcutSearchIsFocused = true
    }

    private func shortcutGroup(
        _ category: NeAntikShortcutCategory,
        shortcuts: [NeAntikShortcut]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ForEach(shortcuts) { shortcut in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(shortcut.title)
                        Spacer(minLength: 16)
                        Text(shortcut.displayChord)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityLabel(
                                "Сочетание: \(shortcut.accessibilityChord)"
                            )
                    }
                    Text(shortcut.availability)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }

    private var densityPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(1...2, id: \.self) { index in
                HStack {
                    Image(systemName: "folder")
                    Text("Пример профиля \(index)")
                    Spacer()
                    Text("Остановлен").foregroundStyle(.secondary)
                }
                .font(.body)
                .padding(.vertical, preferences.rowDensity.verticalPadding)
                .padding(.horizontal, 8)
                .frame(minHeight: preferences.rowDensity.minimumRowHeight)
                if index == 1 { Divider() }
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Пример плотности: \(preferences.rowDensity.title). Демонстрационные данные.")
    }
}
