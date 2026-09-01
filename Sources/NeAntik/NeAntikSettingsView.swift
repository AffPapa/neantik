import SwiftUI

struct NeAntikSettingsView: View {
    @ObservedObject var preferences: WorkspacePreferenceStore

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
            }

            Section("Сочетания клавиш") {
                ForEach(NeAntikShortcutCategory.allCases) { category in
                    shortcutGroup(category)
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

    private func shortcutGroup(
        _ category: NeAntikShortcutCategory
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
                .font(.headline)

            ForEach(
                NeAntikShortcut.allCases.filter {
                    $0.category == category
                }
            ) { shortcut in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(shortcut.title)
                    Spacer(minLength: 16)
                    Text(shortcut.displayChord)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Сочетание: \(shortcut.accessibilityChord)"
                        )
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}
