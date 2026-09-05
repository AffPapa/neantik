import Foundation
import SwiftUI

/// Ephemeral editor values only. Never encoded, logged or written to defaults.
struct ProfileEditorDraft: Equatable {
    let name: String
    let colorHex: String
    let symbolName: String
    let tags: [String]
    let note: String
    let folderID: UUID?
    let startURL: String
    let usesProxy: Bool
    let proxyKind: ProxyKind
    let proxyHost: String
    let proxyPort: String
    let proxyUsername: String
    let proxyPassword: String

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
                : invalidatedEvidence ? "настройки изменены · проверь снова"
                : refreshedEvidence ? "ответ получен · при запуске повторим"
                : "в этом окне не проверен"
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
