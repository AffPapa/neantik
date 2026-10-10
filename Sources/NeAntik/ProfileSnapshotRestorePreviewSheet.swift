import SwiftUI

struct ProfileSnapshotRestorePreviewSheet: View {
    let preview: ProfileSnapshotRestorePreview
    var isRestoring = false
    let onCancel: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Добавление настроек из снимка")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Снимок настроек от \(preview.snapshotDate.formatted(date: .long, time: .shortened))")
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
            .accessibilityLabel("Сводка добавления новых профилей")
            .accessibilityValue(preview.accessibilitySummary)

            Text("Будут добавлены новые профили. Существующие профили и данные браузера не изменятся. Для новых профилей создаются новые identity.")
            Text("Заметки, cookies, данные браузера, identity seeds и пароли из Связки ключей macOS не восстанавливаются.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRestoring)
                    .accessibilityLabel("Отменить добавление профилей")
                    .accessibilityHint(
                        "Закроет просмотр. Профили и папки не изменятся."
                    )
                Spacer()
                Button(action: onRestore) {
                    if isRestoring {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Добавляем…")
                        }
                    } else {
                        Text("Добавить новые профили")
                    }
                }
                .disabled(isRestoring)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(
                    isRestoring
                        ? "Добавляем новые профили из снимка настроек"
                        : "Добавить новые профили из снимка настроек"
                )
                .accessibilityHint(
                    isRestoring
                        ? "Сохраняем новые профили и папки. Подожди завершения операции."
                        : "Добавит новые профили с новыми identity. Данные сайтов не переносятся."
                )
            }
        }
        .interactiveDismissDisabled(isRestoring)
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
    }
}
