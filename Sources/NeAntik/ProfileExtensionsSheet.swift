import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A closed-profile metadata view. Chromium remains the authority for actions
/// and effective permissions; this view never rewrites browser preferences.
struct ProfileExtensionsSheet: View {
    let profile: BrowserProfile
    let paths: AppPaths
    @ObservedObject var processes: BrowserProcessManager
    let validateSnapshot: @MainActor () async throws -> Bool
    let manageInBrowser: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ProfileExtensionSnapshot?
    @State private var selectedID: String?
    @State private var query = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var package: CRXPackageInspection?
    @State private var packageBusy = false
    @State private var packageError: String?
    @State private var packageTask: Task<Void, Never>?
    @State private var packageRequestID: UUID?
    @State private var showPackage = false
    @State private var packageURL: URL?
    @State private var preparationBusy = false
    @State private var preparationError: String?
    @State private var preparedPackage: PreparedCRXPackage?
    @State private var retainedPackage: RetainedCRXPackage?
    @State private var preparationTask: Task<Void, Never>?

    private var records: [ProfileExtensionRecord] {
        guard let snapshot else { return [] }
        return snapshot.records.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
    private var selected: ProfileExtensionRecord? { records.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Расширения профиля").font(.title2.bold())
                    Text(profile.name).font(.headline).lineLimit(2)
                }
                Spacer()
                Button("Обновить", systemImage: "arrow.clockwise", action: refresh).disabled(busy)
            }
            Text("Список из сохранённых настроек закрытого профиля. Установка, переключатели и удаление доступны в браузере.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Проверить файл CRX…", systemImage: "checkmark.shield", action: inspectPackage)
                    .disabled(packageBusy)
                    .help("Проверяет подпись, содержимое архива и запрошенные разрешения без установки расширения.")
                if packageBusy {
                    ProgressView().controlSize(.small)
                    Button("Отменить проверку") { packageRequestID = nil; packageTask?.cancel(); packageBusy = false }
                }
                Spacer()
            }
            if let packageError {
                Label(packageError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if busy {
                HStack { ProgressView().controlSize(.small); Text("Читаем список расширений…") }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let snapshot {
                if snapshot.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Нет расширений в сохранённых настройках").font(.headline)
                        Text("Открой управление в браузере, чтобы установить расширение или проверить список.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    TextField("Поиск по названию или ID", text: $query)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Поиск расширений")
                    HStack(alignment: .top, spacing: 16) {
                        List(selection: $selectedID) {
                            ForEach(records) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name).font(.headline).lineLimit(2)
                                    Text([record.version.map { "Версия \($0)" }, stateText(record.state)].compactMap { $0 }.joined(separator: " · "))
                                        .foregroundStyle(.secondary).font(.subheadline)
                                }.padding(.vertical, 4).tag(record.id)
                            }
                        }.frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                        ScrollView {
                            if let selected { details(selected) }
                            else { Text(records.isEmpty ? "Ничего не найдено" : "Выбери расширение слева").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 210, idealHeight: 290, maxHeight: 400)
                }
                if snapshot.omittedRecords > 0 {
                    Text("Некоторые записи не удалось распознать: \(snapshot.omittedRecords). Проверь их в браузере.")
                        .foregroundStyle(.secondary)
                }
                if snapshot.packageCount > 0 {
                    Text("Папок пакетов на диске: \(snapshot.packageCount). Они могут оставаться после удаления и не доказывают, что расширение установлено.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Text("В браузере: меню ⋮ → Расширения → Управление расширениями. Или вставь этот адрес в адресную строку:")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Копировать адрес") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("chrome://extensions/", forType: .string)
                }.help("Копирует chrome://extensions/ без данных профиля.")
            }
            Divider()
            HStack {
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Открыть браузер", systemImage: "arrow.up.forward.app", action: manageInBrowser)
                    .keyboardShortcut(.defaultAction).disabled(busy)
                    .help("Откроется пустая вкладка в этом профиле. Перейди к расширениям через меню или вставь скопированный адрес. Стартовая страница и сеть не изменятся.")
            }
        }
        .padding(24).frame(minWidth: 680, idealWidth: 800, maxWidth: 980, minHeight: 330)
        .task { refresh() }
        .onDisappear { requestID = nil; task?.cancel(); packageRequestID = nil; packageTask?.cancel(); preparationTask?.cancel() }
        .sheet(isPresented: $showPackage) {
            if let package {
                CRXPackagePreview(inspection: package, busy: preparationBusy, error: preparationError, prepared: preparedPackage,
                                  retained: retainedPackage, prepare: { preparePackage(unpack: true) },
                                  retain: { preparePackage(unpack: false) }, reveal: revealRetainedPackage,
                                  cancel: { preparationTask?.cancel() })
            }
        }
    }

    private func details(_ record: ProfileExtensionRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.name).font(.headline)
            Text(record.id).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            LabeledContent("Сохранённый статус", value: stateText(record.state))
            LabeledContent("Источник установки", value: sourceText(record.source))
            if let version = record.version { LabeledContent("Версия", value: version) }
            if let manifest = record.manifestVersion { LabeledContent("Manifest", value: String(manifest)) }
            if record.conflictingMetadata {
                Text("Сохранённые записи расходятся. Актуальный статус проверь в браузере.").foregroundStyle(.orange)
            } else if record.metadataNeedsBrowser {
                Text("Название или сведения отсутствуют в сохранённых настройках. Проверь их в браузере.").foregroundStyle(.secondary)
            }
            Divider()
            Text("Запрошенные разрешения").font(.headline)
            permissionList(record.permissions, empty: "В сохранённом manifest разрешения не указаны.")
            if !record.optionalPermissions.isEmpty {
                Text("Необязательные разрешения").font(.headline)
                permissionList(record.optionalPermissions, empty: "Нет")
            }
            Text("Это запросы из manifest, а не список выданных прав. Они не подтверждают безопасность расширения; фактический доступ смотри в Chromium.")
                .font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionList(_ values: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if values.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private func stateText(_ state: ProfileExtensionRecord.State) -> String {
        switch state { case .enabled: "Включено"; case .disabled: "Отключено"; case .unknown: "Уточни в браузере" }
    }
    private func sourceText(_ source: ProfileExtensionRecord.Source) -> String {
        switch source { case .unpacked: "Папка разработчика"; case .packaged: "Пакет"; case .other: "Другой способ"; case .unknown: "Не указан" }
    }

    private func refresh() {
        task?.cancel()
        guard let updateActivity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return }
        let id = UUID(); requestID = id
        busy = true; errorMessage = nil; snapshot = nil
        let browserData = paths.browserDataDirectory(for: profile.id)
        task = Task { @MainActor in
            defer { ApplicationUpdateAdmission.shared.finishActivity(updateActivity) }
            defer { if requestID == id { busy = false; task = nil } }
            do {
                guard try await validateSnapshot() else { throw BrowserProfileRevisionConflictError(profileID: profile.id) }
                try Task.checkCancellation()
                let result = try await processes.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
                    try authority.validate(browserData: browserData)
                    let result = try ProfileExtensionInventory.scan(browserData: browserData)
                    try authority.validate(browserData: browserData)
                    return result
                }
                guard requestID == id else { return }
                guard try await validateSnapshot() else { throw BrowserProfileRevisionConflictError(profileID: profile.id) }
                snapshot = result
                if !result.records.contains(where: { $0.id == selectedID }) { selectedID = result.records.first?.id }
            } catch is CancellationError {
                if requestID == id { errorMessage = "Чтение отменено. Обнови список, чтобы повторить." }
            } catch {
                if requestID == id { errorMessage = error.localizedDescription }
            }
        }
    }

    private func inspectPackage() {
        let panel = NSOpenPanel()
        panel.title = "Проверить пакет расширения"
        panel.message = "Проверка не устанавливает и не запускает расширение. Выбери файл CRX3 от разработчика."
        panel.allowedContentTypes = [UTType(filenameExtension: "crx") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let updateActivity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return }
        packageTask?.cancel()
        let id = UUID(); packageRequestID = id; packageBusy = true; packageError = nil; package = nil
        packageTask = Task { @MainActor in
            defer { ApplicationUpdateAdmission.shared.finishActivity(updateActivity) }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                if packageRequestID == id { packageBusy = false; packageTask = nil }
            }
            let worker = Task.detached(priority: .userInitiated) { try CRXPackageInspection.read(url) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard packageRequestID == id else { return }
                package = result; packageURL = url; preparedPackage = nil; retainedPackage = nil; preparationError = nil; showPackage = true
            } catch is CancellationError { }
            catch {
                guard packageRequestID == id else { return }
                // Never surface an OS error containing a selected private path.
                packageError = (error as? CRXPackageInspectionError)?.localizedDescription
                    ?? CRXPackageInspectionError.unsafeFile.localizedDescription
            }
        }
    }

    private func preparePackage(unpack: Bool) {
        guard !preparationBusy, let url = packageURL, let expected = package else { return }
        guard let updateActivity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return }
        preparationBusy = true; preparationError = nil
        preparationTask = Task { @MainActor in
            defer { ApplicationUpdateAdmission.shared.finishActivity(updateActivity) }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; preparationBusy = false; preparationTask = nil }
            do {
                guard try await validateSnapshot() else { throw CRXPreparationError.changed }
                let browserData = paths.browserDataDirectory(for: profile.id)
                let result = try await processes.withVerifiedStoppedProfileMaintenance(profile: profile) { authority -> (PreparedCRXPackage?, RetainedCRXPackage?) in
                    try authority.validate(browserData: browserData)
                    let captured = try CRXPackageInspection.capture(url)
                    if unpack {
                        return (try CRXPackagePreparation.prepare(captured, expected: expected, browserData: browserData,
                            validate: { try authority.validate(browserData: browserData) }), Optional<RetainedCRXPackage>.none)
                    }
                    return (Optional<PreparedCRXPackage>.none,
                            try CRXPackagePreparation.retainPacked(captured, expected: expected, browserData: browserData,
                                validate: { try authority.validate(browserData: browserData) }))
                }
                guard try await validateSnapshot() else { throw CRXPreparationError.retained }
                // Once published, cancellation must not pretend no data were written.
                if let prepared = result.0 { preparedPackage = prepared }
                if let retained = result.1 { retainedPackage = retained }
            } catch is CancellationError {
                preparationError = "Подготовка отменена. Расширение не установлено."
            } catch {
                preparationError = (error as? CRXPreparationError)?.localizedDescription
                    ?? (error as? CRXPackageInspectionError)?.localizedDescription
                    ?? "Не удалось подготовить расширение. Закрой профиль и проверь доступ к его данным."
            }
        }
    }

    private func revealRetainedPackage() {
        guard !preparationBusy, let retainedPackage else { return }
        guard let activity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return }
        preparationBusy = true; preparationError = nil
        preparationTask = Task { @MainActor in
            defer {
                ApplicationUpdateAdmission.shared.finishActivity(activity)
                preparationBusy = false; preparationTask = nil
            }
            let worker = Task.detached(priority: .userInitiated) { try retainedPackage.validateForReveal() }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard try await validateSnapshot() else { throw CRXPreparationError.changed }
                NSWorkspace.shared.activateFileViewerSelecting([retainedPackage.originalCRX])
            } catch is CancellationError { }
            catch {
                preparationError = "Сохранённый CRX изменился или недоступен. Выбери исходный файл и проверь его заново."
            }
        }
    }

}

private struct CRXPackagePreview: View {
    let inspection: CRXPackageInspection
    let busy: Bool
    let error: String?
    let prepared: PreparedCRXPackage?
    let retained: RetainedCRXPackage?
    let prepare: () -> Void
    let retain: () -> Void
    let reveal: () -> Void
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Проверка пакета расширения").font(.title2.bold())
            Label("Подпись разработчика и целостность архива проверены", systemImage: "checkmark.shield")
            Text("Это не проверка безопасности автора или кода. Расширение не установлено и не запускалось.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Название", value: inspection.name)
                    if inspection.localizedName { Text("Название задано ключом перевода; увидишь его после загрузки в Chromium.").foregroundStyle(.secondary) }
                    LabeledContent("Версия", value: inspection.version)
                    LabeledContent("Manifest", value: String(inspection.manifestVersion))
                    if inspection.manifestVersion == 2 { Text("Manifest V2: совместимость с текущим Chromium этой проверкой не подтверждена.").foregroundStyle(.orange) }
                    Text("ID: \(inspection.extensionID)").font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                    Text("SHA-256: \(inspection.packageSHA256)").font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Записей: \(inspection.entryCount) · Объём без сжатия: \(ByteCountFormatter.string(fromByteCount: Int64(inspection.expandedBytes), countStyle: .file))")
                        .foregroundStyle(.secondary)
                    Divider()
                    permissions("Запрошенные разрешения", inspection.permissions)
                    permissions("Необязательные разрешения", inspection.optionalPermissions)
                    if retained != nil { retainedInstructions }
                    if let prepared { preparedInstructions(prepared) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 480)
            Text("Фактически выданные права и возможность установки определяет Chromium. Для управления открой chrome://extensions/ в нужном профиле.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small); Button("Отменить подготовку", action: cancel) }
                else {
                    if retained == nil {
                        Button("Подготовить исходный CRX", action: retain)
                            .help("Сохранит проверенный подписанный файл без изменений. Установка выполняется отдельно в Chromium.")
                    }
                    if prepared == nil && inspection.manifestVersion == 3 {
                        Button("Подготовить распакованную папку", action: prepare)
                            .help("Альтернатива для режима разработчика. Создаст папку с файлами расширения в закрытом профиле.")
                    }
                }
                Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }.padding(24).frame(width: 650).interactiveDismissDisabled(busy)
    }
    private var retainedInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("Исходный CRX сохранён без изменений", systemImage: "doc.badge.checkmark")
            Text("В нужном профиле открой chrome://extensions/, включи режим разработчика и перетащи CRX из Finder на страницу. Перед установкой проверь название и запрошенные разрешения. Chromium может отказать в установке несовместимого пакета.")
            Button("Показать проверенный CRX в Finder", action: reveal).disabled(busy)
            Text("Расширение ещё не установлено. Подпись подтверждает целостность файла, а не безопасность его кода.")
                .font(.subheadline).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func preparedInstructions(_ prepared: PreparedCRXPackage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("Папка подготовлена. Расширение ещё не установлено", systemImage: "folder.badge.checkmark")
            Text("Открой этот профиль → chrome://extensions/ → Режим разработчика → Загрузить распакованное расширение. В выборе папки нажми ⌘⇧G и вставь скопированный путь.")
            if prepared.manifestKeyAdded { Text("В manifest добавлен публичный ключ подписи, чтобы Chromium сохранил ID. Исходный CRX сохранён рядом.").foregroundStyle(.secondary) }
            Button("Копировать путь к папке") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prepared.payload.path, forType: .string)
            }
            Text("Папка нужна для повторных запусков: не перемещай и не удаляй её. Разрешения и удаление расширения — в Chromium.").font(.subheadline).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func permissions(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if values.isEmpty { Text("Не указаны в manifest").foregroundStyle(.secondary) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}
