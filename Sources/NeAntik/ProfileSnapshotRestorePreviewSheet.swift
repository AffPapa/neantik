import SwiftUI

struct ProfileSnapshotRestorePreviewSheet: View {
    let preview: ProfileSnapshotRestorePreview
    var isRestoring = false
    let onCancel: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("page.663", tableName: "Pages", bundle: .main, value: "Добавление настроек из снимка", comment: ""))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text(String(format: NSLocalizedString("page.664", tableName: "Pages", bundle: .main, value: "Снимок настроек от %@", comment: ""), String(describing: preview.snapshotDate.formatted(date: .long, time: .shortened))))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text(NSLocalizedString("page.665", tableName: "Pages", bundle: .main, value: "Профилей будет добавлено", comment: ""))
                    Text(preview.profileCount.formatted())
                        .monospacedDigit()
                }
                GridRow {
                    Text(NSLocalizedString("page.666", tableName: "Pages", bundle: .main, value: "Папок будет использовано", comment: ""))
                    Text(preview.folderCount.formatted())
                        .monospacedDigit()
                }
                GridRow {
                    Text(NSLocalizedString("page.667", tableName: "Pages", bundle: .main, value: "Существующих папок совпадёт", comment: ""))
                    Text(preview.reusedFolderCount.formatted())
                        .monospacedDigit()
                }
                GridRow {
                    Text(NSLocalizedString("page.668", tableName: "Pages", bundle: .main, value: "Новых папок будет создано", comment: ""))
                    Text(preview.newFolderCount.formatted())
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NSLocalizedString("page.669", tableName: "Pages", bundle: .main, value: "Сводка добавления новых профилей", comment: ""))
            .accessibilityValue(preview.accessibilitySummary)

            Text(NSLocalizedString("page.670", tableName: "Pages", bundle: .main, value: "Будут добавлены новые профили. Существующие профили и данные браузера не изменятся. Для новых профилей создаются новые identity.", comment: ""))
            Text(NSLocalizedString("page.671", tableName: "Pages", bundle: .main, value: "Заметки, cookies, данные браузера, identity seeds и пароли из Связки ключей macOS не восстанавливаются.", comment: ""))
                .foregroundStyle(.secondary)

            HStack {
                Button(NSLocalizedString("page.632", tableName: "Pages", bundle: .main, value: "Отмена", comment: ""), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRestoring)
                    .accessibilityLabel(NSLocalizedString("page.672", tableName: "Pages", bundle: .main, value: "Отменить добавление профилей", comment: ""))
                    .accessibilityHint(
                        NSLocalizedString("page.673", tableName: "Pages", bundle: .main, value: "Закроет просмотр. Профили и папки не изменятся.", comment: "")
                    )
                Spacer()
                Button(action: onRestore) {
                    if isRestoring {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(NSLocalizedString("page.674", tableName: "Pages", bundle: .main, value: "Добавляем…", comment: ""))
                        }
                    } else {
                        Text(NSLocalizedString("page.675", tableName: "Pages", bundle: .main, value: "Добавить новые профили", comment: ""))
                    }
                }
                .disabled(isRestoring)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(
                    isRestoring
                        ? NSLocalizedString("page.676", tableName: "Pages", bundle: .main, value: "Добавляем новые профили из снимка настроек", comment: "")
                        : NSLocalizedString("page.677", tableName: "Pages", bundle: .main, value: "Добавить новые профили из снимка настроек", comment: "")
                )
                .accessibilityHint(
                    isRestoring
                        ? NSLocalizedString("page.678", tableName: "Pages", bundle: .main, value: "Сохраняем новые профили и папки. Подожди завершения операции.", comment: "")
                        : NSLocalizedString("page.679", tableName: "Pages", bundle: .main, value: "Добавит новые профили с новыми identity. Данные сайтов не переносятся.", comment: "")
                )
            }
        }
        .interactiveDismissDisabled(isRestoring)
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
    }
}
