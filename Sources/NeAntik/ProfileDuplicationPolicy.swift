import Foundation

struct ProfileDuplicationOptions: Equatable, Sendable {
    var name: String
    var destinationFolderID: UUID?
    private(set) var copiesProxy: Bool
    private(set) var copiesProxyPassword: Bool

    init(
        name: String,
        destinationFolderID: UUID?,
        copiesProxy: Bool = false,
        copiesProxyPassword: Bool = false
    ) {
        self.name = name
        self.destinationFolderID = destinationFolderID
        self.copiesProxy = copiesProxy
        self.copiesProxyPassword =
            copiesProxy && copiesProxyPassword
    }

    mutating func setCopiesProxy(_ isEnabled: Bool) {
        copiesProxy = isEnabled
        if !isEnabled {
            copiesProxyPassword = false
        }
    }

    mutating func setCopiesProxyPassword(_ isEnabled: Bool) {
        copiesProxyPassword = copiesProxy && isEnabled
    }
}

struct ProfileDuplicationNameValidation: Equatable, Sendable {
    let normalizedName: String?
    let message: String?

    var isValid: Bool { normalizedName != nil }

    static func resolve(_ requestedName: String) -> Self {
        let cleanName = requestedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanName.isEmpty else {
            return Self(
                normalizedName: nil,
                message: "Введи название нового профиля."
            )
        }
        guard cleanName.count <= BrowserProfile.maximumNameLength else {
            return Self(
                normalizedName: nil,
                message:
                    "Сократи название до " +
                    "\(BrowserProfile.maximumNameLength) символов."
            )
        }
        guard cleanName.utf8.count <= BrowserProfile.maximumNameUTF8Bytes,
              BrowserProfile.isValidName(cleanName)
        else {
            return Self(
                normalizedName: nil,
                message: "Удали из названия недопустимые символы."
            )
        }
        return Self(normalizedName: cleanName, message: nil)
    }
}

enum ProfileDuplicationError: LocalizedError, Equatable {
    case invalidName
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Проверь название нового профиля."
        case .sourceChanged:
            "Исходный профиль изменился в другом окне. Закрой этот лист и открой создание похожего профиля заново."
        }
    }
}

struct ProfileDuplicationTransfer: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable {
        case copied
        case notCopied
        case copiedCount(Int)
    }

    let id: String
    let title: String
    let detail: String
    let state: State

    var systemImage: String {
        switch state {
        case .copied, .copiedCount: "checkmark.circle.fill"
        case .notCopied: "minus.circle"
        }
    }

    var isCopied: Bool {
        switch state {
        case .copied, .copiedCount: true
        case .notCopied: false
        }
    }
}

enum ProfileDuplicationPolicy {
    static func requireCurrentSource(
        _ source: BrowserProfile,
        expectedRevision: UInt64
    ) throws {
        guard source.revision == expectedRevision else {
            throw ProfileDuplicationError.sourceChanged
        }
    }

    static func suggestedName(
        for sourceName: String,
        existingNames: [String]
    ) -> String {
        let existingKeys = Set(existingNames.map(comparisonKey))
        let maximumAttempts = existingNames.count + 2
        for index in 1...maximumAttempts {
            let suffix = index == 1
                ? " — копия"
                : " — копия \(index)"
            guard let candidate = BrowserProfile.nameByAppendingSuffix(
                suffix,
                to: sourceName
            ) else {
                continue
            }
            if !existingKeys.contains(comparisonKey(candidate)) {
                return candidate
            }
        }

        // The bounded loop above has more candidates than existing names.
        // This fallback is only for a malformed source name.
        return "Копия"
    }

    static func makeProfile(
        from source: BrowserProfile,
        options: ProfileDuplicationOptions,
        at date: Date = Date()
    ) throws -> BrowserProfile {
        let validation = ProfileDuplicationNameValidation.resolve(
            options.name
        )
        guard let name = validation.normalizedName else {
            throw ProfileDuplicationError.invalidName
        }
        return source.duplicated(
            named: name,
            copyingProxy: options.copiesProxy,
            at: date
        )
    }

    static func transfers(
        from source: BrowserProfile,
        options: ProfileDuplicationOptions
    ) -> [ProfileDuplicationTransfer] {
        let startupCount = source.startupTabs.validURLs.count
        let startupDetail = startupCount > 0
            ? "Перенесётся \(startupCount) \(startupCount == 1 ? "адрес" : "адреса") для следующего запуска."
            : "У источника нет стартовых вкладок."
        return [
            ProfileDuplicationTransfer(
                id: "cookies",
                title: "Cookies и данные сайтов",
                detail: "Начнётся чистое BrowserData без входов и истории источника.",
                state: .notCopied
            ),
            ProfileDuplicationTransfer(
                id: "tabs",
                title: "Открытые вкладки",
                detail: "Текущая сессия вкладок не переносится.",
                state: .notCopied
            ),
            ProfileDuplicationTransfer(
                id: "startup-tabs",
                title: "Стартовые вкладки",
                detail: startupDetail,
                state: startupCount > 0 ? .copiedCount(startupCount) : .notCopied
            ),
            ProfileDuplicationTransfer(
                id: "proxy",
                title: "Прокси",
                detail: options.copiesProxy
                    ? (options.copiesProxyPassword ? "Адрес и пароль из Связки ключей." : "Адрес прокси без пароля.")
                    : "Новый профиль будет использовать прямое подключение.",
                state: options.copiesProxy ? .copied : .notCopied
            ),
            ProfileDuplicationTransfer(
                id: "fingerprint",
                title: "Цифровая идентичность",
                detail: "Создастся новая согласованная идентичность.",
                state: .notCopied
            ),
            ProfileDuplicationTransfer(
                id: "extensions",
                title: "Расширения",
                detail: "Расширения не переносятся вместе с чистым BrowserData.",
                state: .notCopied
            )
        ]
    }

    static func shouldCopyProxyPassword(
        source: BrowserProfile,
        options: ProfileDuplicationOptions
    ) -> Bool {
        source.proxy != nil &&
            options.copiesProxy &&
            options.copiesProxyPassword
    }

    private static func comparisonKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
