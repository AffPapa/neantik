import Foundation

enum ProfileEditorField: String, Hashable, Sendable {
    case name
    case tags
    case note
    case startURL
    case proxyHost
    case proxyPort
    case proxyUsername
    case proxyPassword
    case proxyImport
}

struct ProfileNotePresentation: Equatable, Sendable {
    let characterCount: Int
    let utf8ByteCount: Int
    let collapsedSummary: String
    let shouldOfferExpansion: Bool
    let validationMessage: String?

    var countLabel: String {
        "\(characterCount) из \(BrowserProfile.maximumNoteLength) символов"
    }

    static func resolve(_ value: String) -> Self {
        let normalizedLineEndings = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let clean = normalizedLineEndings.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let summary = clean
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let visualLineCount = clean.components(separatedBy: "\n").count

        let message: String?
        if clean.count > BrowserProfile.maximumNoteLength {
            message =
                "Сократи заметку до " +
                "\(BrowserProfile.maximumNoteLength) символов."
        } else if clean.utf8.count > BrowserProfile.maximumNoteUTF8Bytes {
            message =
                "Сократи заметку до " +
                "\(BrowserProfile.maximumNoteUTF8Bytes) байт UTF-8."
        } else if BrowserProfile.normalizedNote(value) == nil {
            message = "Удали из заметки недопустимые управляющие символы."
        } else {
            message = nil
        }

        return Self(
            characterCount: clean.count,
            utf8ByteCount: clean.utf8.count,
            collapsedSummary: summary,
            shouldOfferExpansion:
                visualLineCount > 3 || summary.count > 180,
            validationMessage: message
        )
    }
}

struct ProfileEditorValidationIssue: Equatable, Sendable {
    let field: ProfileEditorField
    let message: String
}

enum ProfileEditorValidation {
    static func nameMessage(for value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !BrowserProfile.isValidName(clean) else { return nil }
        if clean.isEmpty { return "Введи название профиля." }
        if clean.count > BrowserProfile.maximumNameLength {
            return "Сократи название до \(BrowserProfile.maximumNameLength) символов."
        }
        if clean.utf8.count > BrowserProfile.maximumNameUTF8Bytes {
            return "Название занимает слишком много места. Сократи его или используй более простые символы."
        }
        return "Убери переносы строк и скрытые управляющие символы из названия."
    }

    static func pendingProxyImportIssue(_ text: String) -> ProfileEditorValidationIssue? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ProfileEditorValidationIssue(
            field: .proxyImport,
            message: "Строка прокси ещё не применена. Нажми «Вставить прокси» или очисти поле."
        )
    }

    static func firstIssue(
        name: String,
        tags: [String],
        note: String = "",
        startURL: String,
        usesProxy: Bool,
        proxyKind: ProxyKind,
        proxyHost: String,
        proxyPort: String,
        proxyUsername: String,
        proxyPassword: String = ""
    ) -> ProfileEditorValidationIssue? {
        if let message = nameMessage(for: name) {
            return ProfileEditorValidationIssue(
                field: .name,
                message: message
            )
        }

        guard BrowserProfile.normalizedTags(tags) != nil else {
            return ProfileEditorValidationIssue(
                field: .tags,
                message:
                    "Проверь теги: не больше " +
                    "\(BrowserProfile.maximumTagCount), до " +
                    "\(BrowserProfile.maximumTagLength) символов каждый."
            )
        }

        let notePresentation = ProfileNotePresentation.resolve(note)
        if let message = notePresentation.validationMessage {
            return ProfileEditorValidationIssue(
                field: .note,
                message: message
            )
        }

        guard BrowserLaunchBuilder.validatedStartURL(startURL) != nil else {
            return ProfileEditorValidationIssue(
                field: .startURL,
                message: "Проверь адрес стартовой страницы."
            )
        }

        guard usesProxy else { return nil }

        let cleanHost = proxyHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanHost.isEmpty else {
            return ProfileEditorValidationIssue(
                field: .proxyHost,
                message: "Введи адрес прокси."
            )
        }

        guard let port = Int(proxyPort), (1...65_535).contains(port) else {
            return ProfileEditorValidationIssue(
                field: .proxyPort,
                message: "Введи порт от 1 до 65535."
            )
        }

        let proxy = ProxyConfiguration(
            kind: proxyKind,
            host: cleanHost,
            port: port,
            username: proxyKind == .socks5
                ? ""
                : proxyUsername.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        )
        var endpointOnly = proxy
        endpointOnly.username = ""
        guard endpointOnly.isValid else {
            return ProfileEditorValidationIssue(
                field: .proxyHost,
                message: "Проверь адрес прокси."
            )
        }
        guard proxy.isValid else {
            let exceedsLimit = proxy.username.count > ProxyConfiguration.maximumUsernameLength ||
                proxy.username.utf8.count > ProxyConfiguration.maximumUsernameUTF8Bytes
            return ProfileEditorValidationIssue(
                field: .proxyUsername,
                message: exceedsLimit
                    ? "Сократи логин прокси до \(ProxyConfiguration.maximumUsernameLength) символов и \(ProxyConfiguration.maximumUsernameUTF8Bytes) байт UTF-8."
                    : "Удали из логина прокси двоеточие и недопустимые управляющие символы."
            )
        }

        if proxyKind != .socks5 {
            guard !proxyPassword.contains("\0") else {
                return ProfileEditorValidationIssue(
                    field: .proxyPassword,
                    message:
                        "Удали из пароля прокси нулевой управляющий символ."
                )
            }
            guard ProxyImportParser.passwordIsWithinLimits(proxyPassword)
            else {
                return ProfileEditorValidationIssue(
                    field: .proxyPassword,
                    message:
                        "Сократи пароль прокси до " +
                        "\(ProxyImportParser.maximumPasswordLength) символов " +
                        "и \(ProxyImportParser.maximumPasswordBytes) байт UTF-8."
                )
            }
        }
        return nil
    }
}
