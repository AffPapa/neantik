import Foundation
import SwiftUI

struct ProfileEditorHeadingPresentation: Equatable, Sendable {
    let title: String
    let subtitle: String?

    static func resolve(original: BrowserProfile?, currentName: String) -> Self {
        guard original != nil else {
            return Self(title: "Создание профиля", subtitle: nil)
        }
        let name = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(title: "Редактирование профиля", subtitle: name.isEmpty ? nil : name)
    }
}

/// Ephemeral editor values only. Never encoded, logged or written to defaults.
struct ProfileEditorDraft: Equatable {
    var name: String
    var colorHex: String
    var symbolName: String
    var tags: [String]
    var note: String
    var folderID: UUID?
    var startURL: String
    var usesProxy: Bool
    var proxyKind: ProxyKind
    var proxyHost: String
    var proxyPort: String
    var proxyUsername: String
    var proxyPassword: String

    var firstIssue: ProfileEditorValidationIssue? {
        ProfileEditorValidation.firstIssue(
            name: name, tags: tags, note: note, startURL: startURL,
            usesProxy: usesProxy, proxyKind: proxyKind,
            proxyHost: proxyHost, proxyPort: proxyPort,
            proxyUsername: proxyUsername, proxyPassword: proxyPassword
        )
    }

    var proxyIssue: ProfileEditorValidationIssue? {
        ProfileEditorValidation.firstIssue(
            name: "Профиль", tags: [], startURL: "https://example.com",
            usesProxy: usesProxy, proxyKind: proxyKind,
            proxyHost: proxyHost, proxyPort: proxyPort,
            proxyUsername: proxyUsername, proxyPassword: proxyPassword
        )
    }

    func resolvingProxyImport(_ text: String, order: ProxyImportOrder = .automatic) throws -> Self {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        guard usesProxy else { throw ProxyImportError.invalid }
        let imported = try ProxyImportParser.parse(text, kind: proxyKind, order: order)
        var draft = self
        draft.proxyHost = imported.configuration.host
        draft.proxyPort = String(imported.configuration.port)
        draft.proxyUsername = imported.configuration.username
        draft.proxyPassword = imported.password
        return draft
    }

    /// Capture only the route being explicitly tested; do not apply pasted
    /// credentials to the editor or persist them as a side effect of Test.
    func proxyTestInput(pendingProxyText: String, order: ProxyImportOrder = .automatic) throws -> ProxyImportDraft? {
        let draft = try resolvingProxyImport(pendingProxyText, order: order)
        guard draft.usesProxy else { return nil }
        guard draft.proxyIssue == nil, let port = Int(draft.proxyPort) else {
            throw NeAntikError.invalidProxy
        }
        let configuration = ProxyConfiguration(
            kind: draft.proxyKind,
            host: draft.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: draft.proxyKind == .socks5 ? "" : draft.proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard configuration.isValid else { throw NeAntikError.invalidProxy }
        return ProxyImportDraft(configuration: configuration, password: draft.proxyPassword)
    }

    func saveIssue(pendingProxyText: String, pendingTagInput: String, order: ProxyImportOrder = .automatic) -> ProfileEditorValidationIssue? {
        if !usesProxy, let issue = ProfileEditorValidation.pendingProxyImportIssue(pendingProxyText) {
            return issue
        }
        do {
            let draft = try resolvingProxyImport(pendingProxyText, order: order)
            return draft.firstIssue ?? ProfileTagEditorModel.resolvingDraft(pendingTagInput, tags: draft.tags).error.map {
                ProfileEditorValidationIssue(field: .tags, message: $0.localizedDescription)
            }
        } catch {
            return ProfileEditorValidationIssue(field: .proxyImport, message: error.localizedDescription)
        }
    }
}

struct ProfileEditorSavePresentation: Equatable {
    let stateTitle: String
    let canSave: Bool
    let routeSummary: String

    static func resolve(
        isNew: Bool, hasChanges: Bool,
        issue: ProfileEditorValidationIssue?, usesProxy: Bool,
        kind: ProxyKind, hasUsername: Bool, isTesting: Bool,
        refreshedEvidence: Bool, invalidatedEvidence: Bool,
        latestProbeFailed: Bool = false
    ) -> Self {
        let title: String
        if let issue {
            title = issue.message
        } else if isTesting {
            title = "Дождись проверки или отмени её перед сохранением."
        } else {
            title = isNew ? "Профиль готов к созданию"
                : hasChanges ? "Есть несохранённые изменения" : "Нет изменений"
        }
        let route: String
        if !usesProxy {
            route = "Напрямую · отдельного прокси нет"
        } else {
            let auth = kind == .socks5 || !hasUsername
                ? "без логина" : "с логином · пароль в Связке ключей"
            let probe = isTesting ? "проверяется"
                : latestProbeFailed ? "последняя проверка не удалась"
                : invalidatedEvidence ? "настройки изменены · проверим при запуске"
                : refreshedEvidence ? "ответ получен · при запуске повторим"
                : "проверим автоматически при запуске"
            route = "\(kind.title) · \(auth) · \(probe)"
        }
        return Self(
            stateTitle: title,
            canSave: issue == nil && !isTesting && (isNew || hasChanges),
            routeSummary: route
        )
    }
}

struct ProfileEditorSaveSummary: View {
    let presentation: ProfileEditorSavePresentation
    let errorMessage: String?
    let issue: ProfileEditorValidationIssue?
    let onShowIssue: (ProfileEditorValidationIssue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let errorMessage {
                UserNoticeLabel(notice: UserNotice(errorMessage, level: .failure))
            }
            Text(presentation.routeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let issue {
                Button { onShowIssue(issue) } label: {
                    Label(presentation.stateTitle, systemImage: "arrow.up.circle")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .help("Перейти к полю, которое нужно проверить")
            } else {
                Text(presentation.stateTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// Keep an unapplied import reachable after switching back to Direct.
struct ProfilePendingProxyImportRecovery: View {
    @Binding var text: String
    @Binding var usesProxy: Bool
    let focus: FocusState<ProfileEditorField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Осталась неприменённая строка прокси. Включи прокси, чтобы применить её, или очисти поле.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Строка прокси для импорта", text: $text)
                .focused(focus, equals: .proxyImport)
                .accessibilityLabel("Строка прокси для импорта")
            HStack {
                Button("Включить прокси") { usesProxy = true }
                Button("Очистить строку") { text = "" }
            }
        }
    }
}
