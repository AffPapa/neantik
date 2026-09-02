import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct AccessibilityAnnouncementGate<Value: Equatable> {
    private(set) var lastValue: Value?

    init() {
        lastValue = nil
    }

    mutating func shouldAnnounce(_ value: Value) -> Bool {
        guard lastValue != value else { return false }
        lastValue = value
        return true
    }

    mutating func reset() {
        lastValue = nil
    }
}

enum BulkProxyImportAccessibilityAnnouncement: Equatable {
    case validationFailed
    case ready(Int)
    case created(Int)
    case creationFailed

    var message: String {
        switch self {
        case .validationFailed:
            "Список прокси не готов. Проверь сообщение под полем."
        case let .ready(count):
            "Готово к созданию профилей: \(count)."
        case let .created(count):
            "Создано профилей: \(count)."
        case .creationFailed:
            "Не удалось создать профили. Проверь сообщение в окне."
        }
    }
}

struct BulkProxyImportDraftSnapshot: Equatable, Sendable {
    let text: String
    let baseName: String
    let kind: ProxyKind
    let order: ProxyImportOrder

    func hasUnsavedChanges(
        text: String,
        baseName: String,
        kind: ProxyKind,
        order: ProxyImportOrder
    ) -> Bool {
        self.text != text ||
            self.baseName != baseName ||
            self.kind != kind ||
            self.order != order
    }
}

enum BulkProxyImportRowIssue: Equatable, Sendable {
    case invalid
    case ambiguous
    case tooLong
    case unsupportedAuthentication

    var message: String {
        switch self {
        case .invalid:
            "Проверь адрес, порт и формат."
        case .ambiguous:
            "Выбери порядок полей в параметрах."
        case .tooLong:
            "Строка слишком длинная."
        case .unsupportedAuthentication:
            "SOCKS5 поддерживается только без логина и пароля."
        }
    }

    static func resolve(_ error: Error) -> Self {
        switch error as? ProxyImportError {
        case .ambiguous:
            .ambiguous
        case .tooLong:
            .tooLong
        case .socksAuthenticationUnsupported:
            .unsupportedAuthentication
        default:
            .invalid
        }
    }
}

struct BulkProxyImportPreviewRow: Identifiable, Equatable, Sendable {
    let lineNumber: Int
    let draft: ProxyImportDraft?
    let issue: BulkProxyImportRowIssue?

    var id: Int { lineNumber }

    var safeSummary: String? {
        guard let draft else { return nil }
        return "\(draft.configuration.kind.title) · " +
            "\(draft.configuration.displayEndpoint) · " +
            (draft.configuration.username.isEmpty
                ? "без авторизации"
                : "с авторизацией")
    }
}

struct BulkProxyImportPreview: Equatable, Sendable {
    static let empty = BulkProxyImportPreview(rows: [])

    let rows: [BulkProxyImportPreviewRow]

    var drafts: [ProxyImportDraft] {
        rows.compactMap(\.draft)
    }

    var issueLineNumbers: [Int] {
        rows.compactMap { $0.issue == nil ? nil : $0.lineNumber }
    }

    var hasIssues: Bool {
        !issueLineNumbers.isEmpty
    }

    var isReady: Bool {
        !rows.isEmpty && !hasIssues
    }
}

enum BulkProxyImportParser {
    static let maximumEntries = 100
    static let maximumInputBytes = 512 * 1_024

    static func parse(
        _ input: String,
        kind: ProxyKind,
        order: ProxyImportOrder
    ) throws -> [ProxyImportDraft] {
        let preview = try preview(input, kind: kind, order: order)
        if let firstIssueLine = preview.issueLineNumbers.first {
            throw BulkProxyImportError.invalidLine(firstIssueLine)
        }
        return preview.drafts
    }

    static func preview(
        _ input: String,
        kind: ProxyKind,
        order: ProxyImportOrder
    ) throws -> BulkProxyImportPreview {
        guard input.utf8.count <= maximumInputBytes else {
            throw BulkProxyImportError.tooLarge
        }
        let lines = input.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        )
        let nonEmpty = lines.enumerated().compactMap { index, value in
            let line = String(value).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return line.isEmpty ? nil : (index + 1, line)
        }
        guard !nonEmpty.isEmpty else {
            throw BulkProxyImportError.empty
        }
        guard nonEmpty.count <= maximumEntries else {
            throw BulkProxyImportError.tooMany
        }

        let rows = nonEmpty.map { lineNumber, line in
            do {
                let draft = try ProxyImportParser.parse(
                    line,
                    kind: kind,
                    order: order
                )
                return BulkProxyImportPreviewRow(
                    lineNumber: lineNumber,
                    draft: draft,
                    issue: nil
                )
            } catch {
                return BulkProxyImportPreviewRow(
                    lineNumber: lineNumber,
                    draft: nil,
                    issue: .resolve(error)
                )
            }
        }
        return BulkProxyImportPreview(rows: rows)
    }

    static func profileName(base: String, index: Int) -> String? {
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BrowserProfile.isValidName(clean), index >= 1 else {
            return nil
        }
        let suffix = " \(index)"
        return BrowserProfile.nameByAppendingSuffix(suffix, to: clean)
    }
}

enum BulkProxyImportError: LocalizedError, Equatable {
    case empty
    case tooMany
    case tooLarge
    case invalidLine(Int)
    case rollbackFailed([UUID])

    var errorDescription: String? {
        switch self {
        case .empty:
            "Вставь хотя бы одну строку прокси."
        case .tooMany:
            "За один раз можно создать не больше \(BulkProxyImportParser.maximumEntries) профилей."
        case .tooLarge:
            "Список прокси слишком большой."
        case let .invalidLine(line):
            "Не удалось распознать строку \(line). Пароль в ошибке не показывается."
        case .rollbackFailed:
            "Импорт остановлен, но часть данных Связки ключей не удалось очистить. Профили не созданы; обратись в поддержку, не передавая пароль."
        }
    }
}

enum ProxyImportFileReadError: LocalizedError, Equatable {
    case unsupportedFile
    case tooLarge
    case invalidEncoding
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            "Выбери обычный текстовый файл, а не папку или ссылку."
        case .tooLarge:
            "Файл больше 512 КиБ. Раздели список на несколько файлов."
        case .invalidEncoding:
            "Файл должен быть сохранён в UTF-8."
        case .unreadable:
            "Не удалось безопасно прочитать выбранный файл."
        }
    }
}

enum ProxyImportFileReader {
    static func readText(from url: URL) throws -> String {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ProxyImportFileReadError.unsupportedFile
            }
            throw ProxyImportFileReadError.unreadable
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ProxyImportFileReadError.unreadable
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ProxyImportFileReadError.unsupportedFile
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= BulkProxyImportParser.maximumInputBytes
        else {
            throw ProxyImportFileReadError.tooLarge
        }

        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        )
        var data = Data()
        do {
            while data.count <= BulkProxyImportParser.maximumInputBytes {
                guard let chunk = try handle.read(
                    upToCount: min(
                        64 * 1_024,
                        BulkProxyImportParser.maximumInputBytes + 1 -
                            data.count
                    )
                ), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            throw ProxyImportFileReadError.unreadable
        }
        guard data.count <= BulkProxyImportParser.maximumInputBytes else {
            throw ProxyImportFileReadError.tooLarge
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data.removeFirst(3)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProxyImportFileReadError.invalidEncoding
        }
        return text
    }
}

extension BulkProxyImportError: ProfileCredentialCleanupRecoveryProviding {
    var profileIDsRequiringCredentialCleanup: [UUID] {
        guard case let .rollbackFailed(profileIDs) = self else {
            return []
        }
        return profileIDs
    }
}

private actor BulkProfileCredentialStager {
    struct Ticket: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Session: Sendable {
        let lease: PrivateFileGuardLease
        let profileIDs: [UUID]
    }

    private let paths: AppPaths
    private let keychain: KeychainStore
    private var sessions: [Ticket: Session] = [:]

    init(paths: AppPaths, keychain: KeychainStore) {
        self.paths = paths
        self.keychain = keychain
    }

    func stage(
        profiles: [BrowserProfile],
        drafts: [ProxyImportDraft]
    ) async throws -> Ticket {
        let paths = paths
        let keychain = keychain
        let stagingTask = Task.detached(priority: .userInitiated) {
            try Self.stageSynchronously(
                profiles: profiles,
                drafts: drafts,
                paths: paths,
                keychain: keychain
            )
        }
        let session = try await withTaskCancellationHandler {
            try await stagingTask.value
        } onCancel: {
            stagingTask.cancel()
        }
        let ticket = Ticket(id: UUID())
        sessions[ticket] = session
        return ticket
    }

    private nonisolated static func stageSynchronously(
        profiles: [BrowserProfile],
        drafts: [ProxyImportDraft],
        paths: AppPaths,
        keychain: KeychainStore
    ) throws -> Session {
        let lease = try paths.acquireBulkCredentialImportGuard()
        var attemptedProfileIDs: [UUID] = []
        do {
            for (profile, draft) in zip(profiles, drafts)
            where !draft.password.isEmpty {
                try Task.checkCancellation()
                try paths.withProcessLockGuard(for: profile.id) {
                    guard try paths.privateFileEntryKind(
                        paths.profileDirectory(for: profile.id)
                    ) == .missing,
                    try paths.privateFileEntryKind(
                        paths.profileDeletionTombstone(for: profile.id)
                    ) == .missing,
                    try paths.privateFileEntryKind(
                        paths.profileCredentialStagingMarker(for: profile.id)
                    ) == .missing else {
                        throw NeAntikError.invalidProfile
                    }
                    try paths.createPrivateFileExclusively(
                        Data("bulk-keychain-stage-v1".utf8),
                        at: paths.profileCredentialStagingMarker(
                            for: profile.id
                        )
                    )
                    attemptedProfileIDs.append(profile.id)
                    try keychain.saveProxyPassword(
                        draft.password,
                        profileID: profile.id
                    )
                }
                try Task.checkCancellation()
            }
        } catch {
            let operationError = error
            let failed = cleanup(
                profileIDs: attemptedProfileIDs,
                lease: lease,
                paths: paths,
                keychain: keychain
            )
            if !failed.isEmpty {
                throw BulkProxyImportError.rollbackFailed(failed)
            }
            throw operationError
        }
        return Session(
            lease: lease,
            profileIDs: attemptedProfileIDs
        )
    }

    func commit(_ ticket: Ticket) async {
        guard let session = sessions.removeValue(forKey: ticket) else {
            return
        }
        let paths = paths
        await Task.detached(priority: .utility) {
            for profileID in session.profileIDs {
                try? paths.withProcessLockGuard(for: profileID) {
                    try paths.removeCredentialStagingMarker(for: profileID)
                }
            }
            session.lease.release()
        }.value
    }

    func rollback(_ ticket: Ticket) async throws {
        guard let session = sessions.removeValue(forKey: ticket) else {
            return
        }
        let paths = paths
        let keychain = keychain
        let failed = await Task.detached(priority: .userInitiated) {
            Self.cleanup(
                profileIDs: session.profileIDs,
                lease: session.lease,
                paths: paths,
                keychain: keychain
            )
        }.value
        guard failed.isEmpty else {
            throw BulkProxyImportError.rollbackFailed(failed)
        }
    }

    private nonisolated static func cleanup(
        profileIDs: [UUID],
        lease: PrivateFileGuardLease,
        paths: AppPaths,
        keychain: KeychainStore
    ) -> [UUID] {
        defer { lease.release() }
        var failed: [UUID] = []
        for profileID in profileIDs.reversed() {
            do {
                try paths.withProcessLockGuard(for: profileID) {
                    try keychain.deleteProxyPassword(profileID: profileID)
                    try paths.removeCredentialStagingMarker(for: profileID)
                }
            } catch {
                // The durable marker intentionally remains. A later trusted
                // startup will retry cleanup while metadata proves the profile
                // was never committed.
                failed.append(profileID)
            }
        }
        return failed
    }
}

@MainActor
enum BulkProfileImporter {
    static func create(
        drafts: [ProxyImportDraft],
        baseName: String,
        store: ProfileStore,
        keychain: KeychainStore,
        targetFolderID: UUID? = nil
    ) async throws -> [BrowserProfile] {
        guard !drafts.isEmpty else {
            throw BulkProxyImportError.empty
        }
        guard drafts.count <= BulkProxyImportParser.maximumEntries else {
            throw BulkProxyImportError.tooMany
        }
        try store.validateInsertionCapacity(
            forAdditionalProfileCount: drafts.count
        )

        let profiles = try drafts.enumerated().map { offset, draft in
            guard let name = BulkProxyImportParser.profileName(
                base: baseName,
                index: offset + 1
            ) else {
                throw NeAntikError.invalidProfile
            }
            return BrowserProfile(
                name: name,
                proxy: draft.configuration
            )
        }
        let credentialStager = BulkProfileCredentialStager(
            paths: store.paths,
            keychain: keychain
        )
        let ticket = try await credentialStager.stage(
            profiles: profiles,
            drafts: drafts
        )
        let inserted: [BrowserProfile]
        do {
            try Task.checkCancellation()
            if let targetFolderID {
                inserted = try store.insertNewProfiles(
                    profiles,
                    toFolderID: targetFolderID,
                    afterPersist: { _ in }
                )
            } else {
                inserted = try store.insertNewProfiles(
                    profiles,
                    afterPersist: { _ in }
                )
            }
        } catch {
            let operationError = error
            do {
                try await credentialStager.rollback(ticket)
            } catch {
                throw error
            }
            throw operationError
        }
        // Metadata and profile directories are now committed. Marker cleanup
        // is best-effort: if it is interrupted, trusted startup cleanup sees
        // the active profile and removes only the stale marker, never its key.
        await credentialStager.commit(ticket)
        return inserted
    }
}

struct PendingProxyFileReplacement: Identifiable, Equatable, Sendable {
    let id = UUID()
    let fileName: String
    let text: String
}

enum BulkProxyFileReplacementPolicy {
    static func requiresConfirmation(existingText: String) -> Bool {
        !existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BulkProxyInputSelection {
    static func range(lineNumber: Int, in text: String) -> NSRange? {
        guard lineNumber > 0 else { return nil }
        let source = text as NSString
        var currentLine = 1
        var location = 0
        while currentLine < lineNumber, location < source.length {
            let lineRange = source.lineRange(
                for: NSRange(location: location, length: 0)
            )
            location = NSMaxRange(lineRange)
            currentLine += 1
        }
        guard currentLine == lineNumber, location < source.length else {
            return nil
        }
        return source.lineRange(
            for: NSRange(location: location, length: 0)
        )
    }
}

struct BulkProxyImportView: View {
    @Environment(\.dismiss) private var dismiss

    let targetFolderName: String?
    let onCreate: ([ProxyImportDraft], String) async throws -> Void
    private let initialDraft: BulkProxyImportDraftSnapshot

    @State private var text = ""
    @State private var baseName = "Прокси"
    @State private var kind: ProxyKind = .http
    @State private var order: ProxyImportOrder = .automatic
    @State private var preview = BulkProxyImportPreview.empty
    @State private var inputMessage: String?
    @State private var creationError: String?
    @State private var isCreating = false
    @State private var showsOptions = false
    @State private var showingFileImporter = false
    @State private var importedFileName: String?
    @State private var showingDiscardConfirmation = false
    @State private var pendingFileReplacement: PendingProxyFileReplacement?
    @FocusState private var proxyInputIsFocused: Bool
    @State private var announcementGate =
        AccessibilityAnnouncementGate<
            BulkProxyImportAccessibilityAnnouncement
        >()

    init(
        targetFolderName: String? = nil,
        initialText: String = "",
        initialBaseName: String = "Прокси",
        initialKind: ProxyKind = .http,
        initialOrder: ProxyImportOrder = .automatic,
        showsOptionsInitially: Bool = false,
        onCreate: @escaping ([ProxyImportDraft], String) async throws -> Void
    ) {
        self.targetFolderName = targetFolderName
        _text = State(initialValue: initialText)
        _baseName = State(initialValue: initialBaseName)
        _kind = State(initialValue: initialKind)
        _order = State(initialValue: initialOrder)
        _showsOptions = State(initialValue: showsOptionsInitially)
        initialDraft = BulkProxyImportDraftSnapshot(
            text: initialText,
            baseName: initialBaseName,
            kind: initialKind,
            order: initialOrder
        )
        self.onCreate = onCreate
    }

    private var hasUnsavedChanges: Bool {
        initialDraft.hasUnsavedChanges(
            text: text,
            baseName: baseName,
            kind: kind,
            order: order
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Создать профили из прокси")
                    .font(.headline)
                    .accessibilityHeading(.h1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section("Прокси — по одному на строку") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(
                            "Вставь список или выбери текстовый файл. " +
                                "Каждая непустая строка станет отдельным " +
                                "постоянным профилем."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Из файла…", systemImage: "doc.text") {
                            showingFileImporter = true
                        }
                        .controlSize(.small)
                        .accessibilityHint(
                            "Выбирает локальный UTF-8 файл размером до 512 КиБ"
                        )
                    }

                    if let importedFileName {
                        Label(
                            "Загружен файл: \(importedFileName)",
                            systemImage: "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(
                                "example.com:8080\n" +
                                    "login:password@example.com:8080"
                            )
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }

                        TextEditor(text: $text)
                            .font(.body.monospaced())
                            .frame(minHeight: 190)
                            .scrollContentBackground(.hidden)
                            .focused($proxyInputIsFocused)
                            .privacySensitive()
                            .accessibilityLabel("Список прокси")
                    }

                    Text(
                        "Доступность прокси будет автоматически проверяться " +
                            "перед каждым запуском профиля. Эта проверка не " +
                            "подтверждает маршрут Chromium."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if isCreating {
                        statusLabel(
                            "Создаём \(profileCountTitle(preview.drafts.count))…",
                            systemImage: "hourglass",
                            color: .accentColor
                        )
                    } else if let creationError {
                        statusLabel(
                            creationError,
                            systemImage: "xmark.octagon.fill",
                            color: .red
                        )
                    } else {
                        previewStatus
                    }

                    previewRows
                }

                Section {
                    Button {
                        showsOptions.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Image(
                                systemName: showsOptions
                                    ? "chevron.down"
                                    : "chevron.right"
                            )
                            .font(.caption.weight(.semibold))
                            Text("Параметры")
                                .fontWeight(.semibold)
                            Spacer()
                            Text(optionsSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 32,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Параметры импорта")
                    .accessibilityValue(
                        showsOptions ? "Развёрнуто" : "Свёрнуто"
                    )
                    .accessibilityHint(
                        showsOptions
                            ? "Скрывает параметры импорта"
                            : "Показывает параметры импорта"
                    )

                    if showsOptions {
                        TextField("Основа названия", text: $baseName)

                        LabeledContent("Будут названы") {
                            Text("\(previewName)…")
                        }

                        LabeledContent("Папка") {
                            Text(targetFolderName ?? "Без папки")
                        }

                        Picker("Тип прокси", selection: $kind) {
                            ForEach(ProxyKind.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }

                        Picker("Порядок полей", selection: $order) {
                            ForEach(ProxyImportOrder.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }

                        Text(
                            "Обычно достаточно автоматического порядка. " +
                                "Измени его только для неоднозначных строк."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)

            Divider()
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) {
                    requestDismiss()
                }
                .disabled(isCreating)
                .keyboardShortcut(.cancelAction)
                Button(createButtonTitle) {
                    create()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isCreating || !preview.isReady || !baseNameIsValid
                )
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 500, idealWidth: 620, minHeight: 500)
        .interactiveDismissDisabled(isCreating || hasUnsavedChanges)
        .alert(
            "Отменить импорт?",
            isPresented: $showingDiscardConfirmation
        ) {
            Button("Продолжить редактирование", role: .cancel) {}
            Button("Отменить импорт", role: .destructive) {
                dismiss()
            }
        } message: {
            Text("Вставленный список и параметры импорта будут потеряны.")
        }
        .alert(item: $pendingFileReplacement) { replacement in
            Alert(
                title: Text("Заменить вставленный список?"),
                message: Text(
                    "Файл «\(replacement.fileName)» заменит весь текущий список прокси."
                ),
                primaryButton: .destructive(Text("Заменить")) {
                    applyFileReplacement(replacement)
                },
                secondaryButton: .cancel(Text("Оставить текущий"))
            )
        }
        .onAppear {
            refreshPreview()
            Task { @MainActor in
                await Task.yield()
                proxyInputIsFocused = true
            }
        }
        .onChange(of: text) { _, _ in refreshPreview() }
        .onChange(of: kind) { _, _ in refreshPreview() }
        .onChange(of: order) { _, _ in refreshPreview() }
        .onChange(of: baseName) { _, _ in validateBaseName() }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.plainText, .commaSeparatedText],
            allowsMultipleSelection: false,
            onCompletion: importProxyFile
        )
        .onDisappear {
            text = ""
            preview = .empty
        }
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            showingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func importProxyFile(_ result: Result<[URL], Error>) {
        do {
            let url = try result.get().first
            guard let url else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            let replacement = PendingProxyFileReplacement(
                fileName: url.lastPathComponent,
                text: try ProxyImportFileReader.readText(from: url)
            )
            if BulkProxyFileReplacementPolicy.requiresConfirmation(
                existingText: text
            ) {
                pendingFileReplacement = replacement
            } else {
                applyFileReplacement(replacement)
            }
        } catch let error as CocoaError where error.code == .userCancelled {
            return
        } catch {
            preview = .empty
            importedFileName = nil
            inputMessage = error.localizedDescription
            creationError = nil
            announce(.validationFailed)
        }
    }

    private func applyFileReplacement(
        _ replacement: PendingProxyFileReplacement
    ) {
        text = replacement.text
        importedFileName = replacement.fileName
        inputMessage = nil
        creationError = nil
        refreshPreview()
        proxyInputIsFocused = true
    }

    private var baseNameIsValid: Bool {
        BulkProxyImportParser.profileName(base: baseName, index: 1) != nil
    }

    private var previewName: String {
        BulkProxyImportParser.profileName(base: baseName, index: 1)
            ?? "Прокси 1"
    }

    private var optionsSummary: String {
        "\(kind.title) · \(previewName)… · " +
            (targetFolderName ?? "Без папки")
    }

    private var createButtonTitle: String {
        if preview.hasIssues {
            return "Исправь \(issueCountTitle(preview.issueLineNumbers.count))"
        }
        guard !preview.drafts.isEmpty else {
            return "Создать профили"
        }
        return "Создать \(profileCountTitle(preview.drafts.count))"
    }

    @ViewBuilder
    private var previewStatus: some View {
        if !baseNameIsValid {
            statusLabel(
                "Проверь основу названия в параметрах.",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        } else if let inputMessage {
            statusLabel(
                inputMessage,
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        } else if preview.hasIssues {
            statusLabel(
                "Готово: \(profileCountTitle(preview.drafts.count)) · " +
                    issueStatusTitle(preview.issueLineNumbers.count),
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        } else if preview.isReady {
            statusLabel(
                "Распознано: \(profileCountTitle(preview.drafts.count))",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        }
    }

    @ViewBuilder
    private var previewRows: some View {
        if !preview.rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let validLimit = preview.hasIssues ? 3 : 6
                ForEach(Array(validPreviewRows.prefix(validLimit))) { row in
                    previewRow(row)
                }

                if validPreviewRows.count > validLimit {
                    Text(
                        "И ещё распознано: " +
                            profileCountTitle(
                                validPreviewRows.count - validLimit
                            )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !issuePreviewRows.isEmpty {
                    Divider()
                    Text("Исправь строки")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(issuePreviewRows) { row in
                        previewRow(row)
                    }
                }
            }
            .padding(.top, 2)
            .privacySensitive()
        }
    }

    private var validPreviewRows: [BulkProxyImportPreviewRow] {
        preview.rows.filter { $0.issue == nil }
    }

    private var issuePreviewRows: [BulkProxyImportPreviewRow] {
        preview.rows.filter { $0.issue != nil }
    }

    @ViewBuilder
    private func previewRow(_ row: BulkProxyImportPreviewRow) -> some View {
        if row.issue != nil {
            Button {
                focusInput(lineNumber: row.lineNumber)
            } label: {
                previewRowContent(row)
            }
            .buttonStyle(.plain)
            .help("Перейти к строке \(row.lineNumber) в редакторе")
            .accessibilityHint("Переводит фокус в проблемную строку")
        } else {
            previewRowContent(row)
        }
    }

    private func previewRowContent(
        _ row: BulkProxyImportPreviewRow
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(row.lineNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            if let summary = row.safeSummary {
                Label(summary, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    row.issue?.message ?? "Проверь строку.",
                    systemImage: "exclamationmark.circle.fill"
                )
                .foregroundStyle(.orange)
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            row.safeSummary.map {
                "Строка \(row.lineNumber), готово, \($0)"
            } ??
                "Строка \(row.lineNumber), требует исправления, " +
                (row.issue?.message ?? "Проверь строку.")
        )
    }

    private func focusInput(lineNumber: Int) {
        guard let range = BulkProxyInputSelection.range(
            lineNumber: lineNumber,
            in: text
        ) else { return }
        proxyInputIsFocused = true
        Task { @MainActor in
            for attempt in 0..<4 {
                await Task.yield()
                if let textView = NSApp.keyWindow?.firstResponder
                    as? NSTextView
                {
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                    return
                }
                guard attempt < 3 else { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            inputMessage =
                "Не удалось выделить строку (lineNumber). " +
                "Щёлкни в поле и перейди к ней вручную."
        }
    }

    private func refreshPreview() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            preview = .empty
            inputMessage = nil
            creationError = nil
            announcementGate.reset()
            return
        }
        do {
            preview = try BulkProxyImportParser.preview(
                text,
                kind: kind,
                order: order
            )
            inputMessage = nil
            creationError = nil
            if baseNameIsValid && preview.isReady {
                announce(.ready(preview.drafts.count))
            } else {
                announce(.validationFailed)
            }
        } catch {
            preview = .empty
            inputMessage = error.localizedDescription
            creationError = nil
            announce(.validationFailed)
        }
    }

    private func validateBaseName() {
        creationError = nil
        if baseNameIsValid && preview.isReady {
            announce(.ready(preview.drafts.count))
        } else if !baseNameIsValid {
            announce(.validationFailed)
        }
    }

    private func create() {
        guard !isCreating, preview.isReady, baseNameIsValid else { return }
        let drafts = preview.drafts
        let capturedBaseName = baseName
        isCreating = true
        creationError = nil
        Task { @MainActor in
            // Publish the busy state before the existing atomic transaction.
            await Task.yield()
            do {
                let createdCount = drafts.count
                try await onCreate(drafts, capturedBaseName)
                announcementGate.reset()
                announce(.created(createdCount))
                dismiss()
            } catch {
                isCreating = false
                creationError = error.localizedDescription
                announcementGate.reset()
                announce(.creationFailed)
            }
        }
    }

    private func profileCountTitle(_ count: Int) -> String {
        let modulo100 = count % 100
        let modulo10 = count % 10
        let noun: String
        if (11...14).contains(modulo100) {
            noun = "профилей"
        } else if modulo10 == 1 {
            noun = "профиль"
        } else if (2...4).contains(modulo10) {
            noun = "профиля"
        } else {
            noun = "профилей"
        }
        return "\(count) \(noun)"
    }

    private func issueCountTitle(_ count: Int) -> String {
        let modulo100 = count % 100
        let modulo10 = count % 10
        let noun: String
        if (11...14).contains(modulo100) {
            noun = "строк"
        } else if modulo10 == 1 {
            noun = "строку"
        } else if (2...4).contains(modulo10) {
            noun = "строки"
        } else {
            noun = "строк"
        }
        return "\(count) \(noun)"
    }

    private func issueStatusTitle(_ count: Int) -> String {
        let modulo100 = count % 100
        let modulo10 = count % 10
        let isSingular = modulo10 == 1 && modulo100 != 11
        let noun: String
        if (11...14).contains(modulo100) {
            noun = "строк"
        } else if modulo10 == 1 {
            noun = "строка"
        } else if (2...4).contains(modulo10) {
            noun = "строки"
        } else {
            noun = "строк"
        }
        return "\(count) \(noun) " +
            (isSingular ? "требует" : "требуют") +
            " исправления"
    }

    private func statusLabel(
        _ title: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    @MainActor
    private func announce(
        _ announcement: BulkProxyImportAccessibilityAnnouncement
    ) {
        guard announcementGate.shouldAnnounce(announcement) else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}
