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
            Text(NSLocalizedString("page.644", tableName: "Pages", bundle: .main, value: "Очистить кэш", comment: "")).font(.title2.bold())
            Text(profile.name).font(.headline).lineLimit(2)
            Text(NSLocalizedString("page.712", tableName: "Pages", bundle: .main, value: "Удаляются только HTTP Cache и Code Cache закрытого профиля. Cookies, данные сайтов, вкладки, Service Worker и расширения сохраняются.", comment: ""))
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                if busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(recovering ? NSLocalizedString("page.713", tableName: "Pages", bundle: .main, value: "Возвращаем оставшийся кэш…", comment: "") : clearing ? NSLocalizedString("page.714", tableName: "Pages", bundle: .main, value: "Очищаем кэш…", comment: "") : NSLocalizedString("page.715", tableName: "Pages", bundle: .main, value: "Считаем объём кэша…", comment: ""))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else if let estimate {
                    LabeledContent(completed ? NSLocalizedString("page.716", tableName: "Pages", bundle: .main, value: "Удалённый объём", comment: "") : NSLocalizedString("page.717", tableName: "Pages", bundle: .main, value: "Объём кэша", comment: ""), value: ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file))
                    Text(completed ? NSLocalizedString("page.718", tableName: "Pages", bundle: .main, value: "Очистка завершена. При следующем запуске браузер создаст кэш заново.", comment: "") : String(format: NSLocalizedString("page.719", tableName: "Pages", bundle: .main, value: "%@ файлов. Перед удалением объём и безопасность проверятся повторно.", comment: ""), String(describing: estimate.files)))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(NSLocalizedString("page.720", tableName: "Pages", bundle: .main, value: "Проверка кэша недоступна.", comment: "")).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let recoveryMessage { Text(recoveryMessage).fixedSize(horizontal: false, vertical: true) }
            Text(NSLocalizedString("page.721", tableName: "Pages", bundle: .main, value: "Кэш не является резервной копией. После очистки первая загрузка страниц может быть медленнее.", comment: ""))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if busy {
                    Button(NSLocalizedString("page.722", tableName: "Pages", bundle: .main, value: "Отменить", comment: "")) { task?.cancel() }
                        .help(NSLocalizedString("page.723", tableName: "Pages", bundle: .main, value: "До удаления операция отменяется. Если удаление уже началось, дождись результата: уже удалённый кэш не восстанавливается.", comment: ""))
                }
                if recoveryAvailable {
                    Button(NSLocalizedString("page.724", tableName: "Pages", bundle: .main, value: "Вернуть оставшийся кэш", comment: "")) { perform(clear: false, recover: true) }
                        .disabled(busy)
                        .help(NSLocalizedString("page.725", tableName: "Pages", bundle: .main, value: "Проверяется журнал незавершённой операции. Уже удалённые байты не восстанавливаются; данные сайтов не меняются.", comment: ""))
                }
                Spacer()
                Button(NSLocalizedString("page.637", tableName: "Pages", bundle: .main, value: "Закрыть", comment: "")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                if !completed {
                    Button(NSLocalizedString("page.644", tableName: "Pages", bundle: .main, value: "Очистить кэш", comment: "")) { perform(clear: true) }
                        .disabled(busy || estimate == nil || estimate?.files == 0)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(minWidth: 480, idealWidth: 560, maxWidth: 680)
        .task { perform(clear: false) }
        .interactiveDismissDisabled(busy)
        .onDisappear { requestID = nil; task?.cancel() }
    }

    private func perform(clear: Bool, recover: Bool = false) {
        guard !busy else { return }
        guard let updateActivity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return }
        let id = UUID(); requestID = id
        busy = true; clearing = clear; recovering = recover; errorMessage = nil; recoveryMessage = nil
        let operation = ProfileCacheMaintenance(browserData: paths.browserDataDirectory(for: profile.id))
        task = Task { @MainActor in
            defer { ApplicationUpdateAdmission.shared.finishActivity(updateActivity) }
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
                        ? String(format: NSLocalizedString("page.726", tableName: "Pages", bundle: .main, value: "Незавершённая операция закрыта. Вернулось папок кэша: %@. Уже удалённые байты не восстанавливаются; данные сайтов сохранены.", comment: ""), String(describing: recovery.restoredRoots))
                        : NSLocalizedString("page.727", tableName: "Pages", bundle: .main, value: "Незавершённая операция отменена. Папки кэша возвращены без удаления данных.", comment: "")
                }
            } catch is CancellationError {
                if requestID == id { errorMessage = NSLocalizedString("page.728", tableName: "Pages", bundle: .main, value: "Операция отменена до удаления кэша.", comment: "") }
            } catch {
                if requestID == id {
                    estimate = nil; errorMessage = error.localizedDescription
                    recoveryAvailable = (error as? ProfileCacheError) == .rollbackRequired || (error as? ProfileCacheError) == .partiallyRemoved
                }
            }
        }
    }
}
