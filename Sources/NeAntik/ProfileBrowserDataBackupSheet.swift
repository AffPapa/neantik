import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProfileBrowserDataBackupMode: String, Sendable { case export, restore }
struct ProfileBrowserDataBackupRequest: Identifiable {
    let profile: BrowserProfile
    let mode: ProfileBrowserDataBackupMode
    var id: String { profile.id.uuidString + mode.rawValue }
}

/// Available only through the application composition's qualified capability.
/// The worker owns cancellation and durable recovery; dismissing a view never
/// means an already activated restore was rolled back.
struct ProfileBrowserDataBackupSheet: View {
    let request: ProfileBrowserDataBackupRequest
    let service: ProfileBrowserDataBackupService
    let didRestore: @MainActor () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var complete = false
    @State private var message: String?
    @State private var needsRecovery = false
    @State private var recoveryPreview: BrowserDataRestoreTransaction.RecoveryPreview?
    @State private var recoveryBlocked = false
    @State private var task: Task<Void, Never>?
    @FocusState private var passwordFocused: Bool
    private var restoring: Bool { request.mode == .restore }
    private var canConfirm: Bool {
        file != nil && !busy && !complete && !recoveryBlocked && (12...1024).contains(password.utf8.count) &&
            (restoring || password == confirmation)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(restoring ? NSLocalizedString("page.200", tableName: "Pages", bundle: .main, value: "Восстановить данные профиля", comment: "") : NSLocalizedString("page.201", tableName: "Pages", bundle: .main, value: "Создать копию данных профиля", comment: "")).font(.title2.bold())
            LabeledContent(NSLocalizedString("page.202", tableName: "Pages", bundle: .main, value: "Профиль", comment: ""), value: request.profile.name).font(.body)
            Text(restoring
                 ? NSLocalizedString("page.203", tableName: "Pages", bundle: .main, value: "Данные сайтов этого профиля будут заменены содержимым копии. Настройки профиля, прокси и папки сохранятся.", comment: "")
                 : NSLocalizedString("page.204", tableName: "Pages", bundle: .main, value: "Зашифрованный файл содержит данные сайтов закрытого профиля. Настройки профиля, прокси и папки экспортируются отдельно.", comment: ""))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(restoring ? NSLocalizedString("page.205", tableName: "Pages", bundle: .main, value: "Выбрать копию…", comment: "") : NSLocalizedString("page.206", tableName: "Pages", bundle: .main, value: "Выбрать место…", comment: "")) { chooseFile() }.disabled(busy || complete)
                Text(file?.lastPathComponent ?? NSLocalizedString("page.207", tableName: "Pages", bundle: .main, value: "Файл не выбран", comment: "")).lineLimit(2).textSelection(.enabled)
                Spacer()
            }
            SecureField(restoring ? NSLocalizedString("page.208", tableName: "Pages", bundle: .main, value: "Пароль копии", comment: "") : NSLocalizedString("page.209", tableName: "Pages", bundle: .main, value: "Пароль: от 12 байт", comment: ""), text: $password)
                .focused($passwordFocused).textFieldStyle(.roundedBorder).disabled(busy || complete)
            if !restoring {
                SecureField(NSLocalizedString("page.210", tableName: "Pages", bundle: .main, value: "Повтори пароль", comment: ""), text: $confirmation).textFieldStyle(.roundedBorder).disabled(busy || complete)
                Text(NSLocalizedString("page.211", tableName: "Pages", bundle: .main, value: "Сохрани пароль отдельно: восстановить его из копии нельзя.", comment: ""))
                    .font(.body).foregroundStyle(.secondary)
            }
            Text(NSLocalizedString("page.212", tableName: "Pages", bundle: .main, value: "Копия совместима с этим Mac, исходным профилем и точной версией движка. После восстановления сайт может попросить войти снова. Перенос сохранённых паролей и авторизации на другой Mac не поддерживается.", comment: ""))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if busy { ProgressView(restoring ? NSLocalizedString("page.213", tableName: "Pages", bundle: .main, value: "Проверка и восстановление данных…", comment: "") : NSLocalizedString("page.214", tableName: "Pages", bundle: .main, value: "Создание зашифрованной копии…", comment: "")) }
            if let message {
                Label(message, systemImage: complete ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(complete ? .green : .primary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if busy { Button(NSLocalizedString("page.215", tableName: "Pages", bundle: .main, value: "Остановить операцию", comment: "")) { task?.cancel() } }
                if needsRecovery { Button(NSLocalizedString("page.216", tableName: "Pages", bundle: .main, value: "Завершить восстановление", comment: "")) { perform(recovery: true) }.disabled(busy) }
                Spacer()
                Button(complete ? NSLocalizedString("page.217", tableName: "Pages", bundle: .main, value: "Готово", comment: "") : NSLocalizedString("page.218", tableName: "Pages", bundle: .main, value: "Закрыть", comment: "")) { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
                if !complete && !needsRecovery && !recoveryBlocked {
                    Button(restoring ? NSLocalizedString("page.219", tableName: "Pages", bundle: .main, value: "Восстановить данные", comment: "") : NSLocalizedString("page.220", tableName: "Pages", bundle: .main, value: "Создать копию", comment: "")) { perform() }
                        .disabled(!canConfirm).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 600, maxWidth: 720)
        .interactiveDismissDisabled(busy)
        .onAppear { passwordFocused = true }
        .onDisappear { task?.cancel(); password = ""; confirmation = "" }
    }
    private func chooseFile() {
        if restoring {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "nabackup") ?? .data]
            if panel.runModal() == .OK { file = panel.url }
        } else {
            // NSSavePanel appends the allowed type's extension itself.
            let panel = NSSavePanel(); panel.nameFieldStringValue = "NeAntik-profile"
            panel.allowedContentTypes = [UTType(filenameExtension: "nabackup") ?? .data]
            if panel.runModal() == .OK { file = panel.url }
        }
        passwordFocused = true
    }
    private func perform(recovery: Bool = false) {
        guard !busy, recovery || canConfirm, let file else { return }
        let expectedRecovery = recoveryPreview
        guard !recovery || expectedRecovery != nil else { return }
        guard let updateActivity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return }
        busy = true; message = nil
        let password = password, profile = request.profile
        task = Task { @MainActor in
            defer { ApplicationUpdateAdmission.shared.finishActivity(updateActivity) }
            defer { busy = false; task = nil }
            var dataOperationCompleted = false
            do {
                if recovery {
                    let result = try await service.recoverPending(expected: expectedRecovery)
                    dataOperationCompleted = true
                    try await didRestore()
                    complete = true; needsRecovery = false
                    message = result.restored ? NSLocalizedString("page.221", tableName: "Pages", bundle: .main, value: "Восстановление завершено.", comment: "") : NSLocalizedString("page.222", tableName: "Pages", bundle: .main, value: "Незавершённая замена отменена. Прежние данные профиля сохранены.", comment: "")
                } else if restoring {
                    _ = try await service.restore(profileID: profile.id, expectedRevision: profile.revision, archive: file, password: password)
                    dataOperationCompleted = true
                    try await didRestore(); complete = true; message = NSLocalizedString("page.223", tableName: "Pages", bundle: .main, value: "Данные профиля восстановлены. Теперь можно запустить браузер.", comment: "")
                } else {
                    let manifest = try await service.export(profileID: profile.id, expectedRevision: profile.revision, destination: file, password: password)
                    complete = true; message = String(format: NSLocalizedString("page.224", tableName: "Pages", bundle: .main, value: "Копия сохранена: %@ файлов и папок.", comment: ""), String(describing: manifest.entries.count))
                }
                self.password = ""; confirmation = ""
            } catch {
                // Never label an activated operation simply 'cancelled'. The
                // authenticated journal decides recovery, including roll-forward.
                if dataOperationCompleted {
                    complete = true; needsRecovery = false; self.password = ""; confirmation = ""
                    message = NSLocalizedString("page.225", tableName: "Pages", bundle: .main, value: "Операция с данными завершена, но список не обновился. Перезапусти NeAntik перед запуском профиля.", comment: "")
                    return
                }
                let pending = await service.pendingRecoveryRequired()
                if pending { recoveryPreview = try? await service.inspectPendingRecovery() }
                else { recoveryPreview = nil }
                needsRecovery = recoveryPreview?.context.profileID == profile.id
                recoveryBlocked = pending && !needsRecovery
                if recoveryBlocked {
                    message = NSLocalizedString("page.226", tableName: "Pages", bundle: .main, value: "В NeAntik есть другое или неподтверждённое восстановление. Закрой это окно и перезапусти NeAntik: он проверит журнал перед запуском профилей. Не удаляй файлы данных.", comment: "")
                }
                else if needsRecovery { message = NSLocalizedString("page.227", tableName: "Pages", bundle: .main, value: "Операция не завершена. Закрой другие версии NeAntik и заверши восстановление этого профиля.", comment: "") }
                else if error is CancellationError { message = NSLocalizedString("page.228", tableName: "Pages", bundle: .main, value: "Операция остановлена до завершения. Проверь выбранный файл перед повторной попыткой.", comment: "") }
                else if let value = error as? EncryptedBackupError {
                    switch value {
                    case .authenticationFailed: message = NSLocalizedString("page.229", tableName: "Pages", bundle: .main, value: "Не удалось подтвердить копию. Проверь пароль и целостность файла.", comment: "")
                    case .passwordLength: message = NSLocalizedString("page.230", tableName: "Pages", bundle: .main, value: "Пароль должен содержать от 12 до 1024 байт UTF-8.", comment: "")
                    default: message = NSLocalizedString("page.231", tableName: "Pages", bundle: .main, value: "Формат или размер копии не поддерживается. Выбери исходный файл NeAntik.", comment: "")
                    }
                } else if error as? BrowserDataBackupStorageError == .incompatibleContext {
                    message = NSLocalizedString("page.232", tableName: "Pages", bundle: .main, value: "Копия относится к другому профилю, Mac или движку. Данные не заменены.", comment: "")
                } else { message = error.localizedDescription }
            }
        }
    }
}
