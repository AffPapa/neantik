import SwiftUI

struct NeAntikSettingsView: View {
    @ObservedObject var preferences: WorkspacePreferenceStore
    @State private var shortcutQuery = ""
    @State private var showsShortcutReference = false
    @FocusState private var shortcutSearchIsFocused: Bool

    private var matchingShortcuts: [NeAntikShortcut] {
        NeAntikShortcut.allCases.filter { $0.matchesSearch(shortcutQuery) }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            settingsForm
                .onAppear { revealShortcutReference(using: scrollProxy) }
                .onChange(of: preferences.shortcutReferenceRequest) { _, _ in
                    revealShortcutReference(using: scrollProxy)
                }
        }
        .frame(width: 560, height: 520)
        .navigationTitle("Настройки NeAntik")
    }

    private var settingsForm: some View {
        let shortcuts = matchingShortcuts
        return Form {
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
            }

            Section("Обезличенная статистика") {
                Toggle("Помогать улучшать NeAntik", isOn: $preferences.telemetryEnabled)
                Text("Передаются только агрегированные события: запуски, количество рабочих мест и прокси. URL, cookies, имена профилей, прокси и отпечатки не передаются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Сочетания клавиш") {
                HStack {
                    Button {
                        showsShortcutReference = true
                        shortcutSearchIsFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("Найти сочетание клавиш")
                    .help("Найти сочетание клавиш (⌘F)")

                    TextField("Найти команду, клавиши или раздел", text: $shortcutQuery)
                        .labelsHidden()
                        .accessibilityLabel("Поиск сочетаний клавиш")
                        .focused($shortcutSearchIsFocused)
                        .onChange(of: shortcutQuery) { _, query in
                            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                showsShortcutReference = true
                            }
                        }
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
                .id("shortcutSearch")
                DisclosureGroup("Справочник команд", isExpanded: $showsShortcutReference) {
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
                        "Сочетания работают в активном NeAntik и не переназначаются. " +
                            "В поиске Escape сначала очищает запрос, затем снимает фокус."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(NeAntikDisclosureStyle())
            }
        }
        .formStyle(.grouped)
    }

    private func revealShortcutReference(using scrollProxy: ScrollViewProxy) {
        guard preferences.consumeShortcutReferenceRequest() else { return }
        showsShortcutReference = true
        scrollProxy.scrollTo("shortcutSearch", anchor: .top)
        shortcutSearchIsFocused = true
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
