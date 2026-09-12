import Foundation

struct ImportedCookie: Codable, Equatable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    let secure: Bool
    let httpOnly: Bool
}

enum CookieImportError: LocalizedError, Equatable {
    case empty, tooLarge, malformed, tooMany, invalidRecord(Int)
    var errorDescription: String? {
        switch self {
        case .empty: "Файл cookies пустой."
        case .tooLarge: "Файл cookies слишком большой (максимум 10 МБ)."
        case .malformed: "Не удалось распознать JSON или Netscape cookies."
        case .tooMany: "Слишком много cookies (максимум 5 000)."
        case let .invalidRecord(line): "Строка \(line) содержит некорректные cookies."
        }
    }
}

enum CookieImportParser {
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumCookies = 5_000

    static func parse(_ data: Data) throws -> [ImportedCookie] {
        guard !data.isEmpty else { throw CookieImportError.empty }
        guard data.count <= maximumBytes else { throw CookieImportError.tooLarge }
        if let json = try? JSONDecoder().decode([JSONCookie].self, from: data) {
            let result = try json.enumerated().map { try $0.element.imported(at: $0.offset + 1) }
            guard result.count <= maximumCookies else { throw CookieImportError.tooMany }
            return result
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CookieImportError.malformed }
        let lines = text.split(whereSeparator: \.isNewline)
        var result: [ImportedCookie] = []
        for (offset, line) in lines.enumerated() {
            let value = String(line)
            if value.isEmpty || value.hasPrefix("#") { continue }
            let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 7 else { throw CookieImportError.invalidRecord(offset + 1) }
            guard let expiry = Double(fields[4]) else { throw CookieImportError.invalidRecord(offset + 1) }
            // Netscape's second column means "include subdomains", not
            // HttpOnly. HttpOnly is not represented by this format and must
            // never be inferred from it.
            let cookie = ImportedCookie(name: String(fields[5]), value: String(fields[6]), domain: String(fields[0]), path: String(fields[2]), expires: expiry > 0 ? Date(timeIntervalSince1970: expiry) : nil, secure: fields[3].uppercased() == "TRUE", httpOnly: false)
            guard isValid(cookie) else { throw CookieImportError.invalidRecord(offset + 1) }
            result.append(cookie)
            guard result.count <= maximumCookies else { throw CookieImportError.tooMany }
        }
        guard !result.isEmpty else { throw CookieImportError.malformed }
        return result
    }

    private static func isValid(_ cookie: ImportedCookie) -> Bool {
        !cookie.name.isEmpty && !cookie.domain.isEmpty && cookie.path.first == "/" &&
            cookie.name.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) } &&
            !cookie.value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private struct JSONCookie: Decodable {
        let name: String; let value: String; let domain: String; let path: String?
        let expirationDate: Double?; let expires: Double?; let secure: Bool?; let httpOnly: Bool?
        func imported(at line: Int) throws -> ImportedCookie {
            let result = ImportedCookie(name: name, value: value, domain: domain, path: path ?? "/", expires: (expirationDate ?? expires).map { Date(timeIntervalSince1970: $0) }, secure: secure ?? false, httpOnly: httpOnly ?? false)
            guard CookieImportParser.isValid(result) else { throw CookieImportError.invalidRecord(line) }
            return result
        }
    }
}
