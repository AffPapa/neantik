import Foundation

struct ProxyImportDraft: Equatable, Sendable {
    let configuration: ProxyConfiguration
    let password: String

    var redactedSummary: String {
        let authentication = configuration.username.isEmpty
            ? "без авторизации"
            : "логин \(Self.redacted(configuration.username))"
        return "\(configuration.kind.title) · \(configuration.displayEndpoint) · \(authentication)"
    }

    private static func redacted(_ value: String) -> String {
        guard let first = value.first else { return "не указан" }
        return "\(first)•••"
    }
}

enum ProxyImportOrder: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case credentialsFirst
    case endpointFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Определить автоматически"
        case .credentialsFirst: "Адрес прокси справа"
        case .endpointFirst: "Адрес прокси слева"
        }
    }
}

enum ProxyImportParser {
    static let maximumInputBytes = 8 * 1_024
    static let maximumPasswordBytes = 4 * 1_024

    static func parse(
        _ input: String,
        kind: ProxyKind,
        order: ProxyImportOrder = .automatic
    ) throws -> ProxyImportDraft {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ProxyImportError.empty
        }
        guard value.utf8.count <= maximumInputBytes else {
            throw ProxyImportError.tooLong
        }
        guard value.rangeOfCharacter(from: .controlCharacters) == nil,
              !value.contains("://")
        else {
            throw ProxyImportError.invalid
        }

        let parsedCandidates: [ProxyImportDraft]
        if value.contains("@") {
            guard value.filter({ $0 == "@" }).count == 1,
                  let marker = value.firstIndex(of: "@")
            else {
                throw ProxyImportError.invalid
            }
            let left = String(value[..<marker])
            let right = String(value[value.index(after: marker)...])
            parsedCandidates = candidates(
                left: left,
                right: right,
                kind: kind,
                order: order
            )
        } else {
            let parts = try topLevelComponents(value, separator: ":")
            if parts.count == 2 {
                guard let endpoint = endpoint(
                    host: parts[0],
                    port: parts[1],
                    kind: kind,
                    username: ""
                ) else {
                    throw ProxyImportError.invalid
                }
                return ProxyImportDraft(
                    configuration: endpoint,
                    password: ""
                )
            }
            guard parts.count == 4 else {
                throw ProxyImportError.invalid
            }
            parsedCandidates = colonCandidates(
                parts: parts,
                kind: kind,
                order: order
            )
        }

        let unique = parsedCandidates.reduce(into: [ProxyImportDraft]()) {
            if !$0.contains($1) {
                $0.append($1)
            }
        }
        guard !unique.isEmpty else {
            throw ProxyImportError.invalid
        }
        guard unique.count == 1 else {
            throw ProxyImportError.ambiguous
        }
        let result = unique[0]
        if kind == .socks5 && !result.configuration.username.isEmpty {
            throw ProxyImportError.socksAuthenticationUnsupported
        }
        return result
    }

    private static func candidates(
        left: String,
        right: String,
        kind: ProxyKind,
        order: ProxyImportOrder
    ) -> [ProxyImportDraft] {
        var values: [ProxyImportDraft] = []
        if order != .endpointFirst,
           let credentials = credentials(left),
           let endpointParts = try? topLevelComponents(
               right,
               separator: ":"
           ),
           endpointParts.count == 2,
           let configuration = endpoint(
               host: endpointParts[0],
               port: endpointParts[1],
               kind: kind,
               username: credentials.username
           ) {
            values.append(
                ProxyImportDraft(
                    configuration: configuration,
                    password: credentials.password
                )
            )
        }
        if order != .credentialsFirst,
           let endpointParts = try? topLevelComponents(
               left,
               separator: ":"
           ),
           endpointParts.count == 2,
           let credentials = credentials(right),
           let configuration = endpoint(
               host: endpointParts[0],
               port: endpointParts[1],
               kind: kind,
               username: credentials.username
           ) {
            values.append(
                ProxyImportDraft(
                    configuration: configuration,
                    password: credentials.password
                )
            )
        }
        return values
    }

    private static func colonCandidates(
        parts: [String],
        kind: ProxyKind,
        order: ProxyImportOrder
    ) -> [ProxyImportDraft] {
        var values: [ProxyImportDraft] = []
        if order != .endpointFirst,
           let credentials = credentials(parts[0], parts[1]),
           let configuration = endpoint(
               host: parts[2],
               port: parts[3],
               kind: kind,
               username: credentials.username
           ) {
            values.append(
                ProxyImportDraft(
                    configuration: configuration,
                    password: credentials.password
                )
            )
        }
        if order != .credentialsFirst,
           let credentials = credentials(parts[2], parts[3]),
           let configuration = endpoint(
               host: parts[0],
               port: parts[1],
               kind: kind,
               username: credentials.username
           ) {
            values.append(
                ProxyImportDraft(
                    configuration: configuration,
                    password: credentials.password
                )
            )
        }
        return values
    }

    private static func credentials(
        _ value: String
    ) -> (username: String, password: String)? {
        guard let parts = try? topLevelComponents(value, separator: ":"),
              parts.count == 2
        else {
            return nil
        }
        return credentials(parts[0], parts[1])
    }

    private static func credentials(
        _ rawUsername: String,
        _ rawPassword: String
    ) -> (username: String, password: String)? {
        guard let username = decodedCredential(rawUsername),
              let password = decodedCredential(rawPassword),
              !username.isEmpty,
              !password.isEmpty,
              username.utf8.count <= 512,
              password.utf8.count <= maximumPasswordBytes,
              !username.contains(":"),
              username.rangeOfCharacter(from: .controlCharacters) == nil,
              password.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            return nil
        }
        return (username, password)
    }

    private static func decodedCredential(_ value: String) -> String? {
        guard percentEncodingIsWellFormed(value) else {
            return nil
        }
        return value.removingPercentEncoding
    }

    private static func percentEncodingIsWellFormed(
        _ value: String
    ) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "%" {
                guard index + 2 < scalars.count,
                      scalars[index + 1].isASCIIHexDigit,
                      scalars[index + 2].isASCIIHexDigit
                else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func endpoint(
        host rawHost: String,
        port rawPort: String,
        kind: ProxyKind,
        username: String
    ) -> ProxyConfiguration? {
        guard !rawHost.isEmpty,
              !rawPort.isEmpty,
              rawPort.unicodeScalars.allSatisfy({
                  $0.value >= 48 && $0.value <= 57
              }),
              let port = Int(rawPort),
              (1...65_535).contains(port)
        else {
            return nil
        }
        let configuration = ProxyConfiguration(
            kind: kind,
            host: rawHost,
            port: port,
            username: username
        )
        if configuration.isValid {
            return configuration
        }
        // Validate the endpoint and credentials independently so callers can
        // produce the specific SOCKS5-authentication error below instead of a
        // misleading generic parser failure.
        if kind == .socks5, !username.isEmpty {
            let credentialValidation = ProxyConfiguration(
                kind: .http,
                host: rawHost,
                port: port,
                username: username
            )
            return credentialValidation.isValid ? configuration : nil
        }
        return nil
    }

    private static func topLevelComponents(
        _ value: String,
        separator: Character
    ) throws -> [String] {
        var components = [String]()
        var current = ""
        var insideBrackets = false
        for character in value {
            switch character {
            case "[":
                guard !insideBrackets else {
                    throw ProxyImportError.invalid
                }
                insideBrackets = true
                current.append(character)
            case "]":
                guard insideBrackets else {
                    throw ProxyImportError.invalid
                }
                insideBrackets = false
                current.append(character)
            case separator where !insideBrackets:
                components.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        guard !insideBrackets else {
            throw ProxyImportError.invalid
        }
        components.append(current)
        return components
    }
}

private extension Unicode.Scalar {
    var isASCIIHexDigit: Bool {
        (value >= 48 && value <= 57) ||
            (value >= 65 && value <= 70) ||
            (value >= 97 && value <= 102)
    }
}

enum ProxyImportError: LocalizedError, Equatable {
    case empty
    case tooLong
    case invalid
    case ambiguous
    case socksAuthenticationUnsupported

    var errorDescription: String? {
        switch self {
        case .empty:
            "Вставь адрес прокси одной строкой."
        case .tooLong:
            "Строка прокси слишком длинная."
        case .invalid:
            "Не удалось распознать прокси. Проверь адрес, порт и формат."
        case .ambiguous:
            "Неясно, где адрес прокси. Выбери «Адрес прокси слева» или «Адрес прокси справа»."
        case .socksAuthenticationUnsupported:
            "SOCKS5 в Chromium поддерживается только без логина и пароля."
        }
    }
}
