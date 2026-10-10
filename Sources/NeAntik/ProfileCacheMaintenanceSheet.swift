import SwiftUI

struct ProfileCacheMaintenanceSheet: View {
    let profile: BrowserProfile
    let paths: AppPaths
    @ObservedObject var processes: BrowserProcessManager
    let validateSnapshot: @MainActor () async throws -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var estimate: ProfileCacheEstimate?
    @State private var busy = false
    @State private var clearing = false
    @State private var completed = false
    @State private var recovering = false
    @State private var recoveryAvailable = false
    @State private var recoveryMessage: String?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Очистить кэш").font(.title2.bold())
            Text(profile.name).font(.headline).lineLimit(2)
            Text("Удаляются только HTTP Cache и Code Cache закрытого профиля. Cookies, данные сайтов, вкладки, Service Worker и расширения сохраняются.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                if busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(recovering ? "Возвращаем оставшийся кэш…" : clearing ? "Очищаем кэш…" : "Считаем объём кэша…")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else if let estimate {
                    LabeledContent(completed ? "Удалённый объём" : "Объём кэша", value: ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file))
                    Text(completed ? "Очистка завершена. При следующем запуске браузер создаст кэш заново." : "\(estimate.files) файлов. Перед удалением объём и безопасность проверятся повторно.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Проверка кэша недоступна.").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let recoveryMessage { Text(recoveryMessage).fixedSize(horizontal: false, vertical: true) }
            Text("Кэш не является резервной копией. После очистки первая загрузка страниц может быть медленнее.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if busy { Button("Отменить") { task?.cancel() } }
                if recoveryAvailable {
                    Button("Вернуть оставшийся кэш") { perform(clear: false, recover: true) }
                        .disabled(busy)
                        .help("Проверяется журнал незавершённой операции. Уже удалённые байты не восстанавливаются; данные сайтов не меняются.")
                }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                if !completed {
                    Button("Очистить кэш") { perform(clear: true) }
                        .disabled(busy || estimate == nil || estimate?.files == 0)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(minWidth: 480, idealWidth: 560, maxWidth: 680)
        .task { perform(clear: false) }
        .onDisappear { requestID = nil; task?.cancel() }
    }

    private func perform(clear: Bool, recover: Bool = false) {
        guard !busy else { return }
        let id = UUID(); requestID = id
        busy = true; clearing = clear; recovering = recover; errorMessage = nil; recoveryMessage = nil
        let operation = ProfileCacheMaintenance(browserData: paths.browserDataDirectory(for: profile.id))
        task = Task { @MainActor in
            defer { if requestID == id { busy = false; task = nil } }
            do {
                guard try await validateSnapshot() else { throw BrowserProfileRevisionConflictError(profileID: profile.id) }
                try Task.checkCancellation()
                let result = try await processes.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
                    var operation = operation
                    operation.authority = authority
                    if recover {
                        let recovery = try operation.recover()
                        return (try operation.estimate(), Optional(recovery))
                    }
                    return (clear ? try operation.clear() : try operation.estimate(), Optional<ProfileCacheRecoveryResult>.none)
                }
                guard requestID == id else { return }
                estimate = result.0; completed = clear; recoveryAvailable = false
                if let recovery = result.1 {
                    recoveryMessage = recovery.cacheMayAlreadyBeRemoved
                        ? "Незавершённая операция закрыта. Вернулось папок кэша: \(recovery.restoredRoots). Уже удалённые байты не восстанавливаются; данные сайтов сохранены."
                        : "Незавершённая операция отменена. Папки кэша возвращены без удаления данных."
                }
            } catch is CancellationError {
                if requestID == id { errorMessage = "Операция отменена до удаления кэша." }
            } catch {
                if requestID == id {
                    estimate = nil; errorMessage = error.localizedDescription
                    recoveryAvailable = (error as? ProfileCacheError) == .rollbackRequired || (error as? ProfileCacheError) == .partiallyRemoved
                }
            }
        }
    }
}
