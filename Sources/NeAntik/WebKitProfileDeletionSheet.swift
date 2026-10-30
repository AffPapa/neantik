import SwiftUI

struct WebKitProfileDeletionRequest: Identifiable {
    let id: UUID
    let name: String
    let snapshot: BrowserProfile?
}

/// Full WebKit store removal has no Trash/undo guarantee. Keep the user in a
/// single progress/recovery surface until the non-cancellable API settles.
struct WebKitProfileDeletionSheet: View {
    let request: WebKitProfileDeletionRequest
    @ObservedObject var store: ProfileStore
    @ObservedObject var processes: BrowserProcessManager
    let cleanupCredentials: @MainActor (UUID) throws -> Void
    let completed: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var finished = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Удаление профиля WebKit").font(.title2.bold())
            Text(request.name).font(.headline).lineLimit(2)
            Text("macOS удалит отдельное хранилище этого профиля: cookies, входы и данные сайтов. Сохранённые вкладки и запись профиля также будут удалены. Вернуть эти данные из Корзины нельзя. Для обратимого скрытия выбери архив.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                if busy {
                    HStack { ProgressView().controlSize(.small); Text("Удаляем профиль… Дождись завершения.") }
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if finished {
                    Label("Удаление завершено", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Окна и загрузки профиля должны быть закрыты. Если удаление уже начиналось, продолжится незавершённый этап. После сбоя профиль останется заблокированным до безопасного завершения.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button(finished ? "Закрыть" : "Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                if !finished {
                    Button(errorMessage == nil ? "Удалить без возможности отмены" : "Продолжить удаление", role: .destructive) { remove() }
                        .disabled(busy)
                }
            }
        }
        .padding(24).frame(minWidth: 480, idealWidth: 580, maxWidth: 680)
        .interactiveDismissDisabled(busy)
        .onDisappear { task?.cancel() }
    }

    private func remove() {
        guard !busy else { return }
        busy = true; errorMessage = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                try await processes.deleteClosedWebKitProfile(profileID: request.id, expected: request.snapshot,
                    store: store, afterCommit: cleanupCredentials)
                finished = true; completed()
            } catch is CancellationError {
                errorMessage = "Операция отменена до начала удаления."
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
