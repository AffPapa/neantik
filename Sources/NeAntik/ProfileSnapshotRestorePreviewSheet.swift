import SwiftUI

struct ProfileSnapshotRestorePreviewSheet: View {
    let preview: ProfileSnapshotRestorePreview
    var isRestoring = false
    let onCancel: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Проверка восстановления")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Snapshot от \(preview.snapshotDate.formatted(date: .long, time: .shortened))")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Профилей будет добавлено")
                    Text(preview.profileCount.formatted())
                        .monospacedDigit()
                }
                GridRow {
                    Text("Папок будет использовано")
                    Text(preview.folderCount.formatted())
                        .monospacedDigit()
                }
                GridRow {
                    Text("Существующих папок совпадёт")
                    Text(preview.reusedFolderCount.formatted())
                        .monospacedDigit()
                }
                GridRow {
                    Text("Новых папок будет создано")
                    Text(preview.newFolderCount.formatted())
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Сводка восстановления профиля")
            .accessibilityValue(preview.accessibilitySummary)

            Text("Будут добавлены новые профили. Существующие профили и данные браузера не изменятся. Для новых профилей создаются новые identity.")
            Text("Заметки, cookies, данные браузера, identity seeds и пароли из Связки ключей macOS не восстанавливаются.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Отменить восстановление профиля")
                    .accessibilityHint(
                        "Закроет просмотр. Профили и папки не изменятся."
                    )
                Spacer()
                Button(action: onRestore) {
                    if isRestoring {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Восстанавливаем…")
                        }
                    } else {
                        Text("Восстановить")
                    }
                }
                .disabled(isRestoring)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(
                    isRestoring
                        ? "Восстанавливаем профили из снимка"
                        : "Восстановить профили из снимка"
                )
                .accessibilityHint(
                    isRestoring
                        ? "Идёт восстановление. Подожди завершения операции."
                        : "Добавит профили из snapshot в текущий список"
                )
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
    }
}
