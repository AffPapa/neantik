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
            Text(NSLocalizedString("page.698", tableName: "Pages", bundle: .main, value: "Удаление профиля WebKit", comment: "")).font(.title2.bold())
            Text(request.name).font(.headline).lineLimit(2)
            Text(NSLocalizedString("page.699", tableName: "Pages", bundle: .main, value: "macOS удалит отдельное хранилище этого профиля: cookies, входы и данные сайтов. Сохранённые вкладки и запись профиля также будут удалены. Вернуть эти данные из Корзины нельзя. Для обратимого скрытия выбери архив.", comment: ""))
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                if busy {
                    HStack { ProgressView().controlSize(.small); Text(NSLocalizedString("page.700", tableName: "Pages", bundle: .main, value: "Удаляем профиль… Дождись завершения.", comment: "")) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if finished {
                    Label(NSLocalizedString("page.701", tableName: "Pages", bundle: .main, value: "Удаление завершено", comment: ""), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(NSLocalizedString("page.702", tableName: "Pages", bundle: .main, value: "Окна и загрузки профиля должны быть закрыты. Если удаление уже начиналось, продолжится незавершённый этап. После сбоя профиль останется заблокированным до безопасного завершения.", comment: ""))
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
                Button(finished ? NSLocalizedString("page.637", tableName: "Pages", bundle: .main, value: "Закрыть", comment: "") : NSLocalizedString("page.632", tableName: "Pages", bundle: .main, value: "Отмена", comment: "")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                if !finished {
                    Button(errorMessage == nil ? NSLocalizedString("page.703", tableName: "Pages", bundle: .main, value: "Удалить без возможности отмены", comment: "") : NSLocalizedString("page.704", tableName: "Pages", bundle: .main, value: "Продолжить удаление", comment: ""), role: .destructive) { remove() }
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
                errorMessage = NSLocalizedString("page.705", tableName: "Pages", bundle: .main, value: "Операция отменена до начала удаления.", comment: "")
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
