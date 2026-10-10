import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProfileBrowserDataBackupMode: String, Sendable { case export, restore }
struct ProfileBrowserDataBackupRequest: Identifiable {
    let profile: BrowserProfile
    let mode: ProfileBrowserDataBackupMode
    var id: String { profile.id.uuidString + mode.rawValue }
}

/// Development-only GUI until signed-manager device-scope qualification.
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
    @State private var task: Task<Void, Never>?
    @FocusState private var passwordFocused: Bool
    private var restoring: Bool { request.mode == .restore }
    private var canConfirm: Bool {
        file != nil && !busy && !complete && (12...1024).contains(password.utf8.count) &&
            (restoring || password == confirmation)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(restoring ? "Восстановить данные профиля" : "Создать копию данных профиля").font(.title2.bold())
            LabeledContent("Профиль", value: request.profile.name).font(.body)
            Text(restoring
                 ? "Данные сайтов этого профиля будут заменены содержимым копии. Настройки профиля, прокси и папки сохранятся."
                 : "Зашифрованный файл содержит данные сайтов закрытого профиля. Настройки профиля, прокси и папки экспортируются отдельно.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(restoring ? "Выбрать копию…" : "Выбрать место…") { chooseFile() }.disabled(busy || complete)
                Text(file?.lastPathComponent ?? "Файл не выбран").lineLimit(2).textSelection(.enabled)
                Spacer()
            }
            SecureField(restoring ? "Пароль копии" : "Пароль: от 12 байт", text: $password)
                .focused($passwordFocused).textFieldStyle(.roundedBorder).disabled(busy || complete)
            if !restoring {
                SecureField("Повтори пароль", text: $confirmation).textFieldStyle(.roundedBorder).disabled(busy || complete)
                Text("Сохрани пароль отдельно: восстановить его из копии нельзя.")
                    .font(.body).foregroundStyle(.secondary)
            }
            Text("Копия совместима с этим Mac, исходным профилем и точной версией движка. Перенос сохранённых паролей и авторизации на другой Mac не поддерживается.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if busy { ProgressView(restoring ? "Проверка и восстановление данных…" : "Создание зашифрованной копии…") }
            if let message {
                Label(message, systemImage: complete ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(complete ? .green : .primary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if busy { Button("Остановить операцию") { task?.cancel() } }
                if needsRecovery { Button("Завершить восстановление") { perform(recovery: true) }.disabled(busy) }
                Spacer()
                Button(complete ? "Готово" : "Закрыть") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
                if !complete && !needsRecovery {
                    Button(restoring ? "Восстановить данные" : "Создать копию") { perform() }
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
            let panel = NSSavePanel(); panel.nameFieldStringValue = "NeAntik-profile.nabackup"
            panel.allowedContentTypes = [UTType(filenameExtension: "nabackup") ?? .data]
            if panel.runModal() == .OK { file = panel.url }
        }
        passwordFocused = true
    }
    private func perform(recovery: Bool = false) {
        guard !busy, recovery || canConfirm, let file else { return }
        busy = true; message = nil
        let password = password, profile = request.profile
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            var dataOperationCompleted = false
            do {
                if recovery {
                    let result = try await service.recoverPending()
                    dataOperationCompleted = true
                    try await didRestore()
                    complete = true; needsRecovery = false
                    message = result.restored ? "Восстановление завершено." : "Незавершённая замена отменена. Прежние данные профиля сохранены."
                } else if restoring {
                    _ = try await service.restore(profileID: profile.id, expectedRevision: profile.revision, archive: file, password: password)
                    dataOperationCompleted = true
                    try await didRestore(); complete = true; message = "Данные профиля восстановлены. Теперь можно запустить браузер."
                } else {
                    let manifest = try await service.export(profileID: profile.id, expectedRevision: profile.revision, destination: file, password: password)
                    complete = true; message = "Копия сохранена: \(manifest.entries.count) файлов и папок."
                }
                self.password = ""; confirmation = ""
            } catch {
                // Never label an activated operation simply 'cancelled'. The
                // authenticated journal decides recovery, including roll-forward.
                if dataOperationCompleted {
                    complete = true; needsRecovery = false; self.password = ""; confirmation = ""
                    message = "Операция с данными завершена, но список не обновился. Перезапусти NeAntik перед запуском профиля."
                    return
                }
                needsRecovery = await service.pendingRecoveryRequired()
                if needsRecovery { message = "Операция не завершена. Данные сохранены; закрой другие версии NeAntik и заверши восстановление." }
                else if error is CancellationError { message = "Операция остановлена до завершения. Проверь выбранный файл перед повторной попыткой." }
                else if let value = error as? EncryptedBackupError {
                    switch value {
                    case .authenticationFailed: message = "Не удалось подтвердить копию. Проверь пароль и целостность файла."
                    case .passwordLength: message = "Пароль должен содержать от 12 до 1024 байт UTF-8."
                    default: message = "Формат или размер копии не поддерживается. Выбери исходный файл NeAntik."
                    }
                } else if error as? BrowserDataBackupStorageError == .incompatibleContext {
                    message = "Копия относится к другому профилю, Mac или движку. Данные не заменены."
                } else { message = error.localizedDescription }
            }
        }
    }
}
