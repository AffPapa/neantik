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
            Text("Завершить восстановление").font(.title2.bold())
            Text("NeAntik проверит журнал и сохранённые данные. До подтверждённой замены он вернёт прежние данные; после неё завершит восстановление копии. Направление определяется записанным решением операции.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Закрой браузерные окна этого профиля и другие версии NeAntik. Не удаляй и не перемещай файлы данных.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if checking || busy { ProgressView(checking ? "Проверка журнала…" : "Завершение операции…") }
            if let message {
                Label(message, systemImage: complete ? "checkmark.circle" : "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button(complete ? "Готово" : "Закрыть") { dismiss() }
                    .disabled(busy).keyboardShortcut(.cancelAction)
                if !complete {
                    Button("Завершить восстановление") { recover() }
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
                message = "Журнал не удалось подтвердить. Данные не изменены. Сохрани отдельную копию закрытого workspace и обратись в поддержку."
            }
        }
    }

    private func recover() {
        guard !busy, preview != nil else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            var recovered = false
            do {
                let result = try await service.recoverPending()
                recovered = true
                try await didRecover(result)
                complete = true
                message = result.restored ? "Копия восстановлена. Список профилей доступен." : "Прежние данные возвращены. Список профилей доступен."
            } catch {
                if recovered {
                    complete = true
                    message = "Операция завершена, но список не обновился. Перезапусти NeAntik перед запуском профиля."
                } else {
                    message = "Восстановление не завершено. Данные сохранены; проверь движок и закрой другие версии NeAntik. Если ошибка повторится, сохрани закрытый workspace и обратись в поддержку."
                }
            }
        }
    }
}
