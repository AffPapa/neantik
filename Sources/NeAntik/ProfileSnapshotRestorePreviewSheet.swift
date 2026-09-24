import SwiftUI

struct ProfileSnapshotRestorePreviewSheet: View {
    let preview: ProfileSnapshotRestorePreview
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

            Text("Будут добавлены новые профили. Существующие профили и данные браузера не изменятся. Для новых профилей создаются новые identity.")
            Text("Заметки, cookies, данные браузера, identity seeds и пароли из Связки ключей macOS не восстанавливаются.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Восстановить", action: onRestore)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Добавит профили из snapshot в текущий список")
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
    }
}
