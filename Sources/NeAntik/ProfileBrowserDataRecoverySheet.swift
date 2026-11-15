import SwiftUI

/// Recovery is available without selecting a profile: pending metadata is
/// deliberately unreadable. The service authenticates the journal and obtains
/// fresh process/metadata authority instead of trusting the view's preview.
struct ProfileBrowserDataRecoverySheet: View {
    let service: ProfileBrowserDataBackupService
    let didRecover: @MainActor (BrowserDataRestoreTransaction.Result) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: BrowserDataRestoreTransaction.RecoveryPreview?
    @State private var checking = true
    @State private var busy = false
    @State private var complete = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(NSLocalizedString("page.216", tableName: "Pages", bundle: .main, value: "Завершить восстановление", comment: "")).font(.title2.bold())
            Text(NSLocalizedString("page.233", tableName: "Pages", bundle: .main, value: "NeAntik проверит журнал и сохранённые данные. До подтверждённой замены он вернёт прежние данные; после неё завершит восстановление копии. Направление определяется записанным решением операции.", comment: ""))
                .fixedSize(horizontal: false, vertical: true)
            Text(NSLocalizedString("page.234", tableName: "Pages", bundle: .main, value: "Закрой браузерные окна этого профиля и другие версии NeAntik. Не удаляй и не перемещай файлы данных.", comment: ""))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if checking || busy { ProgressView(checking ? NSLocalizedString("page.235", tableName: "Pages", bundle: .main, value: "Проверка журнала…", comment: "") : NSLocalizedString("page.236", tableName: "Pages", bundle: .main, value: "Завершение операции…", comment: "")) }
            if let message {
                Label(message, systemImage: complete ? "checkmark.circle" : "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button(complete ? NSLocalizedString("page.217", tableName: "Pages", bundle: .main, value: "Готово", comment: "") : NSLocalizedString("page.218", tableName: "Pages", bundle: .main, value: "Закрыть", comment: "")) { dismiss() }
                    .disabled(busy).keyboardShortcut(.cancelAction)
                if !complete {
                    Button(NSLocalizedString("page.216", tableName: "Pages", bundle: .main, value: "Завершить восстановление", comment: "")) { recover() }
                        .disabled(checking || busy || preview == nil).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 600, maxWidth: 720)
        .interactiveDismissDisabled(busy)
        .task {
            defer { checking = false }
            do { preview = try await service.inspectPendingRecovery() }
            catch {
                message = NSLocalizedString("page.237", tableName: "Pages", bundle: .main, value: "Журнал не удалось подтвердить. Данные не изменены. Сохрани отдельную копию закрытого workspace и обратись в поддержку.", comment: "")
            }
        }
    }

    private func recover() {
        guard !busy, let preview else { return }
        guard let updateActivity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { ApplicationUpdateAdmission.shared.finishActivity(updateActivity) }
            defer { busy = false }
            var recovered = false
            do {
                let result = try await service.recoverPending(expected: preview)
                recovered = true
                try await didRecover(result)
                complete = true
                message = result.restored ? NSLocalizedString("page.238", tableName: "Pages", bundle: .main, value: "Копия восстановлена. Список профилей доступен.", comment: "") : NSLocalizedString("page.239", tableName: "Pages", bundle: .main, value: "Прежние данные возвращены. Список профилей доступен.", comment: "")
            } catch {
                if recovered {
                    complete = true
                    message = NSLocalizedString("page.240", tableName: "Pages", bundle: .main, value: "Операция завершена, но список не обновился. Перезапусти NeAntik перед запуском профиля.", comment: "")
                } else {
                    message = NSLocalizedString("page.241", tableName: "Pages", bundle: .main, value: "Восстановление не завершено. Данные сохранены; проверь движок и закрой другие версии NeAntik. Если ошибка повторится, сохрани закрытый workspace и обратись в поддержку.", comment: "")
                }
            }
        }
    }
}
