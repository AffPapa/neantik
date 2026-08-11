import Foundation
import SwiftUI

enum BulkProxyImportParser {
    static let maximumEntries = 100
    static let maximumInputBytes = 512 * 1_024

    static func parse(
        _ input: String,
        kind: ProxyKind,
        order: ProxyImportOrder
    ) throws -> [ProxyImportDraft] {
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

        return try nonEmpty.map { lineNumber, line in
            do {
                return try ProxyImportParser.parse(
                    line,
                    kind: kind,
                    order: order
                )
            } catch {
                throw BulkProxyImportError.invalidLine(lineNumber)
            }
        }
    }

    static func profileName(base: String, index: Int) -> String? {
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BrowserProfile.isValidName(clean), index >= 1 else {
            return nil
        }
        let suffix = " \(index)"
        let prefixLength = max(
            1,
            BrowserProfile.maximumNameLength - suffix.count
        )
        return String(clean.prefix(prefixLength)) + suffix
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

extension BulkProxyImportError: ProfileCredentialCleanupRecoveryProviding {
    var profileIDsRequiringCredentialCleanup: [UUID] {
        guard case let .rollbackFailed(profileIDs) = self else {
            return []
        }
        return profileIDs
    }
}

@MainActor
enum BulkProfileImporter {
    static func create(
        drafts: [ProxyImportDraft],
        baseName: String,
        store: ProfileStore,
        keychain: KeychainStore
    ) throws -> [BrowserProfile] {
        guard !drafts.isEmpty else {
            throw BulkProxyImportError.empty
        }
        guard drafts.count <= BulkProxyImportParser.maximumEntries else {
            throw BulkProxyImportError.tooMany
        }

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
        return try store.insertNewProfiles(profiles) { savedProfiles in
            var savedSecretIDs: [UUID] = []
            do {
                for (profile, draft) in zip(savedProfiles, drafts)
                where !draft.password.isEmpty {
                    try keychain.saveProxyPassword(
                        draft.password,
                        profileID: profile.id
                    )
                    savedSecretIDs.append(profile.id)
                }
            } catch {
                var cleanupFailedProfileIDs: [UUID] = []
                for profileID in savedSecretIDs {
                    do {
                        try keychain.deleteProxyPassword(
                            profileID: profileID
                        )
                    } catch {
                        cleanupFailedProfileIDs.append(profileID)
                    }
                }
                if !cleanupFailedProfileIDs.isEmpty {
                    throw BulkProxyImportError.rollbackFailed(
                        cleanupFailedProfileIDs
                    )
                }
                throw error
            }
        }
    }
}

struct BulkProxyImportView: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: ([ProxyImportDraft], String) throws -> Void

    @State private var text = ""
    @State private var baseName = "Прокси"
    @State private var kind: ProxyKind = .http
    @State private var order: ProxyImportOrder = .automatic
    @State private var drafts: [ProxyImportDraft] = []
    @State private var validationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Новые профили") {
                    TextField("Основа названия", text: $baseName)
                    Text(
                        "Будут созданы чистые профили «\(previewName)», каждый со своей папкой и новым набором параметров."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Прокси — по одному на строку") {
                    Picker("Тип", selection: $kind) {
                        ForEach(ProxyKind.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    Picker("Порядок", selection: $order) {
                        ForEach(ProxyImportOrder.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }

                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                        .privacySensitive()
                        .accessibilityLabel("Список прокси")

                    Text(
                        "Поддерживаются те же четыре формата, что и в одном профиле. Пароли сохранятся в Связке ключей. Соединение автоматически не проверяется."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else if !drafts.isEmpty {
                        Label(
                            "Готово к созданию: \(drafts.count)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                Button("Создать \(drafts.count)") {
                    create()
                }
                .buttonStyle(.borderedProminent)
                .disabled(drafts.isEmpty || !baseNameIsValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 500, idealWidth: 620, minHeight: 500)
        .onAppear(perform: refreshPreview)
        .onChange(of: text) { _, _ in refreshPreview() }
        .onChange(of: kind) { _, _ in refreshPreview() }
        .onChange(of: order) { _, _ in refreshPreview() }
        .onChange(of: baseName) { _, _ in refreshPreview() }
        .onDisappear {
            text = ""
            drafts = []
        }
    }

    private var baseNameIsValid: Bool {
        BulkProxyImportParser.profileName(base: baseName, index: 1) != nil
    }

    private var previewName: String {
        BulkProxyImportParser.profileName(base: baseName, index: 1)
            ?? "Прокси 1"
    }

    private func refreshPreview() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            drafts = []
            validationMessage = nil
            return
        }
        do {
            drafts = try BulkProxyImportParser.parse(
                text,
                kind: kind,
                order: order
            )
            validationMessage = baseNameIsValid
                ? nil
                : "Проверь основу названия."
        } catch {
            drafts = []
            validationMessage = error.localizedDescription
        }
    }

    private func create() {
        do {
            try onCreate(drafts, baseName)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
