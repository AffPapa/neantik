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
                    Text(NSLocalizedString("page.001", tableName: "Pages", bundle: .main, value: "Расширения профиля", comment: "")).font(.title2.bold())
                    Text(profile.name).font(.headline).lineLimit(2)
                }
                Spacer()
                Button(NSLocalizedString("page.002", tableName: "Pages", bundle: .main, value: "Обновить", comment: ""), systemImage: "arrow.clockwise", action: refresh).disabled(busy)
            }
            Text(NSLocalizedString("page.003", tableName: "Pages", bundle: .main, value: "Список из сохранённых настроек закрытого профиля. Установка, переключатели и удаление доступны в браузере.", comment: ""))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if profile.proxy != nil || profile.privacyPolicy.restrictsUserExtensions {
                Label(NSLocalizedString("page.004", tableName: "Pages", bundle: .main, value: "В этом режиме настроено отключение обычных расширений профиля; их данные не удаляются. Компоненты браузера и системные интеграции могут оставаться.", comment: ""), systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(NSLocalizedString("page.005", tableName: "Pages", bundle: .main, value: "Проверить файл CRX…", comment: ""), systemImage: "checkmark.shield", action: inspectPackage)
                    .disabled(packageBusy)
                    .help(NSLocalizedString("page.006", tableName: "Pages", bundle: .main, value: "Проверяет подпись, содержимое архива и запрошенные разрешения без установки расширения.", comment: ""))
                if packageBusy {
                    ProgressView().controlSize(.small)
                    Button(NSLocalizedString("page.007", tableName: "Pages", bundle: .main, value: "Отменить проверку", comment: "")) { packageRequestID = nil; packageTask?.cancel(); packageBusy = false }
                }
                Spacer()
            }
            if let packageError {
                Label(packageError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if busy {
                HStack { ProgressView().controlSize(.small); Text(NSLocalizedString("page.008", tableName: "Pages", bundle: .main, value: "Читаем список расширений…", comment: "")) }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let snapshot {
                if snapshot.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                        Text(NSLocalizedString("page.009", tableName: "Pages", bundle: .main, value: "Нет расширений в сохранённых настройках", comment: "")).font(.headline)
                        Text(NSLocalizedString("page.010", tableName: "Pages", bundle: .main, value: "Открой управление в браузере, чтобы установить расширение или проверить список.", comment: ""))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    TextField(NSLocalizedString("page.011", tableName: "Pages", bundle: .main, value: "Поиск по названию или ID", comment: ""), text: $query)
                        .textFieldStyle(.roundedBorder).accessibilityLabel(NSLocalizedString("page.012", tableName: "Pages", bundle: .main, value: "Поиск расширений", comment: ""))
                    HStack(alignment: .top, spacing: 16) {
                        List(selection: $selectedID) {
                            ForEach(records) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name).font(.headline).lineLimit(2)
                                    Text([record.version.map { String(format: NSLocalizedString("page.013", tableName: "Pages", bundle: .main, value: "Версия %@", comment: ""), String(describing: $0)) }, stateText(record.state)].compactMap { $0 }.joined(separator: " · "))
                                        .foregroundStyle(.secondary).font(.subheadline)
                                }.padding(.vertical, 4).tag(record.id)
                            }
                        }.frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                        ScrollView {
                            if let selected { details(selected) }
                            else { Text(records.isEmpty ? NSLocalizedString("page.014", tableName: "Pages", bundle: .main, value: "Ничего не найдено", comment: "") : NSLocalizedString("page.015", tableName: "Pages", bundle: .main, value: "Выбери расширение слева", comment: "")).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 210, idealHeight: 290, maxHeight: 400)
                }
                if snapshot.omittedRecords > 0 {
                    Text(String(format: NSLocalizedString("page.016", tableName: "Pages", bundle: .main, value: "Некоторые записи не удалось распознать: %@. Проверь их в браузере.", comment: ""), String(describing: snapshot.omittedRecords)))
                        .foregroundStyle(.secondary)
                }
                if snapshot.packageCount > 0 {
                    Text(String(format: NSLocalizedString("page.017", tableName: "Pages", bundle: .main, value: "Папок пакетов на диске: %@. Они могут оставаться после удаления и не доказывают, что расширение установлено.", comment: ""), String(describing: snapshot.packageCount)))
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Text(NSLocalizedString("page.018", tableName: "Pages", bundle: .main, value: "В браузере: меню ⋮ → Расширения → Управление расширениями. Или вставь этот адрес в адресную строку:", comment: ""))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(NSLocalizedString("page.019", tableName: "Pages", bundle: .main, value: "Копировать адрес", comment: "")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("chrome://extensions/", forType: .string)
                }.help(NSLocalizedString("page.020", tableName: "Pages", bundle: .main, value: "Копирует chrome://extensions/ без данных профиля.", comment: ""))
            }
            Divider()
            HStack {
                Button(NSLocalizedString("page.021", tableName: "Pages", bundle: .main, value: "Закрыть", comment: "")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(NSLocalizedString("page.022", tableName: "Pages", bundle: .main, value: "Открыть браузер", comment: ""), systemImage: "arrow.up.forward.app", action: manageInBrowser)
                    .keyboardShortcut(.defaultAction).disabled(busy)
                    .help(NSLocalizedString("page.023", tableName: "Pages", bundle: .main, value: "Откроется пустая вкладка в этом профиле. Перейди к расширениям через меню или вставь скопированный адрес. Стартовая страница и сеть не изменятся.", comment: ""))
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
            LabeledContent(NSLocalizedString("page.024", tableName: "Pages", bundle: .main, value: "Сохранённый статус", comment: ""), value: stateText(record.state))
            LabeledContent(NSLocalizedString("page.025", tableName: "Pages", bundle: .main, value: "Источник установки", comment: ""), value: sourceText(record.source))
            if let version = record.version { LabeledContent(NSLocalizedString("page.026", tableName: "Pages", bundle: .main, value: "Версия", comment: ""), value: version) }
            if let locale = record.nameLocale {
                Text(String(format: NSLocalizedString("page.027", tableName: "Pages", bundle: .main, value: "Название из файлов расширения, язык %@. В браузере оно может быть переведено иначе.", comment: ""), String(describing: locale)))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let manifest = record.manifestVersion { LabeledContent("Manifest", value: String(manifest)) }
            if record.conflictingMetadata {
                Text(NSLocalizedString("page.028", tableName: "Pages", bundle: .main, value: "Сохранённые записи расходятся. Актуальный статус проверь в браузере.", comment: "")).foregroundStyle(.orange)
            } else if record.metadataNeedsBrowser {
                Text(NSLocalizedString("page.029", tableName: "Pages", bundle: .main, value: "Название или сведения отсутствуют в сохранённых настройках. Проверь их в браузере.", comment: "")).foregroundStyle(.secondary)
            }
            Divider()
            Text(NSLocalizedString("page.030", tableName: "Pages", bundle: .main, value: "Запрошенные разрешения", comment: "")).font(.headline)
            permissionList(record.permissions, empty: NSLocalizedString("page.031", tableName: "Pages", bundle: .main, value: "В сохранённом manifest разрешения не указаны.", comment: ""))
            if !record.optionalPermissions.isEmpty {
                Text(NSLocalizedString("page.032", tableName: "Pages", bundle: .main, value: "Необязательные разрешения", comment: "")).font(.headline)
                permissionList(record.optionalPermissions, empty: NSLocalizedString("page.033", tableName: "Pages", bundle: .main, value: "Нет", comment: ""))
            }
            ExtensionPermissionWarnings(requested: record.permissions, optional: record.optionalPermissions)
            Text(NSLocalizedString("page.034", tableName: "Pages", bundle: .main, value: "Это запросы из manifest, а не список выданных прав. Они не подтверждают безопасность расширения; фактический доступ смотри в Chromium.", comment: ""))
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
        switch state { case .enabled: NSLocalizedString("page.035", tableName: "Pages", bundle: .main, value: "Включено", comment: ""); case .disabled: NSLocalizedString("page.036", tableName: "Pages", bundle: .main, value: "Отключено", comment: ""); case .unknown: NSLocalizedString("page.037", tableName: "Pages", bundle: .main, value: "Уточни в браузере", comment: "") }
    }
    private func sourceText(_ source: ProfileExtensionRecord.Source) -> String {
        switch source { case .unpacked: NSLocalizedString("page.038", tableName: "Pages", bundle: .main, value: "Папка разработчика", comment: ""); case .packaged: NSLocalizedString("page.039", tableName: "Pages", bundle: .main, value: "Пакет", comment: ""); case .other: NSLocalizedString("page.040", tableName: "Pages", bundle: .main, value: "Другой способ", comment: ""); case .unknown: NSLocalizedString("page.041", tableName: "Pages", bundle: .main, value: "Не указан", comment: "") }
    }

    private func refresh() {
        guard profile.engine == .chromium else { errorMessage = NSLocalizedString("page.042", tableName: "Pages", bundle: .main, value: "Расширения WebKit пока не поддерживаются.", comment: ""); return }
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
                if requestID == id { errorMessage = NSLocalizedString("page.043", tableName: "Pages", bundle: .main, value: "Чтение отменено. Обнови список, чтобы повторить.", comment: "") }
            } catch {
                if requestID == id { errorMessage = error.localizedDescription }
            }
        }
    }

    private func inspectPackage() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("userDialog.018", tableName: "Errors", bundle: .main, value: "Проверить пакет расширения", comment: "")
        panel.message = NSLocalizedString("userDialog.019", tableName: "Errors", bundle: .main, value: "Проверка не устанавливает и не запускает расширение. Выбери файл CRX3 от разработчика.", comment: "")
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
                preparationError = NSLocalizedString("page.044", tableName: "Pages", bundle: .main, value: "Подготовка отменена. Расширение не установлено.", comment: "")
            } catch {
                preparationError = (error as? CRXPreparationError)?.localizedDescription
                    ?? (error as? CRXPackageInspectionError)?.localizedDescription
                    ?? NSLocalizedString("page.045", tableName: "Pages", bundle: .main, value: "Не удалось подготовить расширение. Закрой профиль и проверь доступ к его данным.", comment: "")
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
                preparationError = NSLocalizedString("page.046", tableName: "Pages", bundle: .main, value: "Сохранённый CRX изменился или недоступен. Выбери исходный файл и проверь его заново.", comment: "")
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
            Text(NSLocalizedString("page.047", tableName: "Pages", bundle: .main, value: "Проверка пакета расширения", comment: "")).font(.title2.bold())
            Label(NSLocalizedString("page.048", tableName: "Pages", bundle: .main, value: "Подпись разработчика и целостность архива проверены", comment: ""), systemImage: "checkmark.shield")
            Text(NSLocalizedString("page.049", tableName: "Pages", bundle: .main, value: "Это не проверка безопасности автора или кода. Расширение не установлено и не запускалось.", comment: ""))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent(NSLocalizedString("page.050", tableName: "Pages", bundle: .main, value: "Название", comment: ""), value: inspection.name)
                    if inspection.localizedName { Text(NSLocalizedString("page.051", tableName: "Pages", bundle: .main, value: "Название задано ключом перевода; увидишь его после загрузки в Chromium.", comment: "")).foregroundStyle(.secondary) }
                    LabeledContent(NSLocalizedString("page.026", tableName: "Pages", bundle: .main, value: "Версия", comment: ""), value: inspection.version)
                    LabeledContent("Manifest", value: String(inspection.manifestVersion))
                    if inspection.manifestVersion == 2 { Text(NSLocalizedString("page.052", tableName: "Pages", bundle: .main, value: "Manifest V2: совместимость с текущим Chromium этой проверкой не подтверждена.", comment: "")).foregroundStyle(.orange) }
                    Text("ID: \(inspection.extensionID)").font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                    Text("SHA-256: \(inspection.packageSHA256)").font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: NSLocalizedString("page.053", tableName: "Pages", bundle: .main, value: "Записей: %@ · Объём без сжатия: %@", comment: ""), String(describing: inspection.entryCount), String(describing: ByteCountFormatter.string(fromByteCount: Int64(inspection.expandedBytes), countStyle: .file))))
                        .foregroundStyle(.secondary)
                    Divider()
                    permissions(NSLocalizedString("page.030", tableName: "Pages", bundle: .main, value: "Запрошенные разрешения", comment: ""), inspection.permissions)
                    permissions(NSLocalizedString("page.032", tableName: "Pages", bundle: .main, value: "Необязательные разрешения", comment: ""), inspection.optionalPermissions)
                    ExtensionPermissionWarnings(requested: inspection.permissions, optional: inspection.optionalPermissions)
                    if retained != nil { retainedInstructions }
                    if let prepared { preparedInstructions(prepared) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 480)
            Text(NSLocalizedString("page.054", tableName: "Pages", bundle: .main, value: "Фактически выданные права и возможность установки определяет Chromium. Для управления открой chrome://extensions/ в нужном профиле.", comment: ""))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small); Button(NSLocalizedString("page.055", tableName: "Pages", bundle: .main, value: "Отменить подготовку", comment: ""), action: cancel) }
                else {
                    if retained == nil {
                        Button(NSLocalizedString("page.056", tableName: "Pages", bundle: .main, value: "Подготовить исходный CRX", comment: ""), action: retain)
                            .help(NSLocalizedString("page.057", tableName: "Pages", bundle: .main, value: "Сохранит проверенный подписанный файл без изменений. Установка выполняется отдельно в Chromium.", comment: ""))
                    }
                    if prepared == nil && inspection.manifestVersion == 3 {
                        Button(NSLocalizedString("page.058", tableName: "Pages", bundle: .main, value: "Подготовить распакованную папку", comment: ""), action: prepare)
                            .help(NSLocalizedString("page.059", tableName: "Pages", bundle: .main, value: "Альтернатива для режима разработчика. Создаст папку с файлами расширения в закрытом профиле.", comment: ""))
                    }
                }
                Spacer(); Button(NSLocalizedString("page.021", tableName: "Pages", bundle: .main, value: "Закрыть", comment: "")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }.padding(24).frame(width: 650).interactiveDismissDisabled(busy)
    }
    private var retainedInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label(NSLocalizedString("page.060", tableName: "Pages", bundle: .main, value: "Исходный CRX сохранён без изменений", comment: ""), systemImage: "doc.badge.checkmark")
            Text(NSLocalizedString("page.061", tableName: "Pages", bundle: .main, value: "В нужном профиле открой chrome://extensions/, включи режим разработчика и перетащи CRX из Finder на страницу. Перед установкой проверь название и запрошенные разрешения. Chromium может отказать в установке несовместимого пакета.", comment: ""))
            Button(NSLocalizedString("page.062", tableName: "Pages", bundle: .main, value: "Показать проверенный CRX в Finder", comment: ""), action: reveal).disabled(busy)
            Text(NSLocalizedString("page.063", tableName: "Pages", bundle: .main, value: "Расширение ещё не установлено. Подпись подтверждает целостность файла, а не безопасность его кода.", comment: ""))
                .font(.subheadline).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func preparedInstructions(_ prepared: PreparedCRXPackage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label(NSLocalizedString("page.064", tableName: "Pages", bundle: .main, value: "Папка подготовлена. Расширение ещё не установлено", comment: ""), systemImage: "folder.badge.checkmark")
            Text(NSLocalizedString("page.065", tableName: "Pages", bundle: .main, value: "Открой этот профиль → chrome://extensions/ → Режим разработчика → Загрузить распакованное расширение. В выборе папки нажми ⌘⇧G и вставь скопированный путь.", comment: ""))
            if prepared.manifestKeyAdded { Text(NSLocalizedString("page.066", tableName: "Pages", bundle: .main, value: "В manifest добавлен публичный ключ подписи, чтобы Chromium сохранил ID. Исходный CRX сохранён рядом.", comment: "")).foregroundStyle(.secondary) }
            Button(NSLocalizedString("page.067", tableName: "Pages", bundle: .main, value: "Копировать путь к папке", comment: "")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prepared.payload.path, forType: .string)
            }
            Text(NSLocalizedString("page.068", tableName: "Pages", bundle: .main, value: "Папка нужна для повторных запусков: не перемещай и не удаляй её. Разрешения и удаление расширения — в Chromium.", comment: "")).font(.subheadline).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func permissions(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if values.isEmpty { Text(NSLocalizedString("page.069", tableName: "Pages", bundle: .main, value: "Не указаны в manifest", comment: "")).foregroundStyle(.secondary) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}

private struct ExtensionPermissionWarnings: View {
    let requested: [String]
    let optional: [String]

    var body: some View {
        let requiredRisks = ExtensionPermissionRiskAssessment.warnings(for: requested)
        let optionalRisks = ExtensionPermissionRiskAssessment.warnings(for: optional)
        if !requiredRisks.isEmpty || !optionalRisks.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label(NSLocalizedString("page.070", tableName: "Pages", bundle: .main, value: "Возможности, требующие внимания", comment: ""), systemImage: "exclamationmark.shield")
                    .font(.subheadline.weight(.semibold))
                ForEach(requiredRisks) { risk in
                    Text(risk.explanation).font(.subheadline)
                }
                ForEach(optionalRisks) { risk in
                    Text(NSLocalizedString("page.071", tableName: "Pages", bundle: .main, value: "Необязательное право · ", comment: "") + risk.explanation).font(.subheadline)
                }
                Text(NSLocalizedString("page.072", tableName: "Pages", bundle: .main, value: "Это запрошенные возможности, а не доказательство выданных прав или вредоносности. Отсутствие предупреждения не гарантирует безопасность.", comment: ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
        }
    }
}
