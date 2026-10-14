import SwiftUI

/// WebKit exposes completion, not a reliable cache byte count or Chromium's
/// recovery journal. Present only the guarantee this operation can provide.
struct WebKitCacheMaintenanceSheet: View {
    let profile: BrowserProfile
    @ObservedObject var processes: BrowserProcessManager
    let validateSnapshot: @MainActor () async throws -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var completed = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Очистить кэш WebKit").font(.title2.bold())
            Text(profile.name).font(.headline).lineLimit(2)
            Text("Удаляются временные HTTP-файлы загруженных страниц из памяти и с диска. Cookies, сохранённые входы, данные сайтов, Service Worker и список предыдущих вкладок не входят в очистку.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                if busy {
                    HStack { ProgressView().controlSize(.small); Text("Очищаем кэш… Дождись завершения.") }
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if completed {
                    Label("Очистка завершена", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Точный объём кэша WebKit не измеряется. Профиль должен быть закрыт; первая загрузка страниц после очистки может быть медленнее.")
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
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                if !completed {
                    Button("Очистить кэш") { clear() }.keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
        .padding(24).frame(minWidth: 480, idealWidth: 560, maxWidth: 680)
        .interactiveDismissDisabled(busy)
        .onDisappear { task?.cancel() }
    }

    private func clear() {
        guard !busy, let activity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return }
        busy = true; errorMessage = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil; ApplicationUpdateAdmission.shared.finishActivity(activity) }
            do {
                guard try await validateSnapshot() else { throw BrowserProfileRevisionConflictError(profileID: profile.id) }
                try Task.checkCancellation()
                try await processes.clearWebKitCache(profile: profile)
                completed = true
            } catch is CancellationError {
                // The manager returns cancellation only before native dispatch.
                errorMessage = "Операция отменена до начала очистки."
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
