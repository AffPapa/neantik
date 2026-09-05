import SwiftUI

struct NeAntikSettingsView: View {
    @ObservedObject var preferences: WorkspacePreferenceStore
    @State private var shortcutQuery = ""

    private var matchingShortcuts: [NeAntikShortcut] {
        NeAntikShortcut.allCases.filter { $0.matchesSearch(shortcutQuery) }
    }

    var body: some View {
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

                densityPreview

                Text(
                    "NeAntik запоминает только плотность. Поиск, фильтры и " +
                        "выбор профиля остаются контекстными."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

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
                TextField("Найти команду, клавиши или раздел", text: $shortcutQuery)
                    .accessibilityLabel("Поиск сочетаний клавиш")
                if matchingShortcuts.isEmpty {
                    Text("Сочетания не найдены")
                    Button("Очистить поиск") { shortcutQuery = "" }
                }
                ForEach(NeAntikShortcutCategory.allCases) { category in
                    if matchingShortcuts.contains(where: { $0.category == category }) {
                        shortcutGroup(category)
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
                Text("Если команда недоступна, закрой диалог и вернись в главное окно. Состояние команды всегда видно в меню; ввод текста не запускает глобальные действия.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .navigationTitle("Настройки NeAntik")
    }

    private func shortcutGroup(
        _ category: NeAntikShortcutCategory
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ForEach(
                matchingShortcuts.filter {
                    $0.category == category
                }
            ) { shortcut in
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
                .font(.caption)
                .padding(.vertical, preferences.rowDensity == .compact ? 5 : 11)
                .padding(.horizontal, 8)
                if index == 1 { Divider() }
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Пример плотности: \(preferences.rowDensity.title). Демонстрационные данные.")
    }
}
