import CoreFoundation
import Foundation

enum BookmarkImportError: LocalizedError {
    case invalidFormat, limitExceeded, unsupportedURL, empty
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Не удалось прочитать закладки. Выбери экспорт Netscape HTML или файл Bookmarks Chromium версии 1."
        case .limitExceeded: return "Файл закладок слишком большой или сложный: до 8 МБ, 10 000 элементов и 32 уровней папок."
        case .unsupportedURL: return "Импорт остановлен: поддерживаются только абсолютные HTTP/HTTPS-ссылки без логина и пароля. Проверь экспорт закладок."
        case .empty: return "В файле нет закладок для импорта."
        }
    }
}

indirect enum ImportedBookmark: Sendable, Equatable {
    case folder(String, [ImportedBookmark])
    case link(String, String)
}

/// Parses inert bytes only. No WebKit, script evaluation, network, credentials,
/// source profile identity, sync metadata or source IDs enter the new profile.
struct BookmarkImportDocument: Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    let roots: [[ImportedBookmark]]
    let linkCount: Int
    let folderCount: Int
    private init(roots: [[ImportedBookmark]], links: Int, folders: Int) {
        self.roots = roots; linkCount = links; folderCount = folders
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw BookmarkImportError.limitExceeded }
        guard var text = String(data: data, encoding: .utf8) else { throw BookmarkImportError.invalidFormat }
        if text.first == "\u{feff}" { text.removeFirst() }
        var budget = BookmarkBudget()
        let roots: [[ImportedBookmark]]
        if text.trimmingCharacters(in: .whitespacesAndNewlines).first == "{" {
            try BookmarkJSONShape.validate(Data(text.utf8))
            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let version = object["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  let sourceRoots = object["roots"] as? [String: Any],
                  Set(sourceRoots.keys).isSubset(of: ["bookmark_bar", "other", "synced"]),
                  sourceRoots["bookmark_bar"] != nil, sourceRoots["other"] != nil else { throw BookmarkImportError.invalidFormat }
            roots = try ["bookmark_bar", "other", "synced"].map { key in
                guard let root = sourceRoots[key] else { return [] }
                guard let value = root as? [String: Any], value["type"] as? String == "folder",
                      let children = value["children"] as? [Any] else { throw BookmarkImportError.invalidFormat }
                return try children.map { try budget.jsonNode($0, depth: 1) }
            }
        } else {
            roots = [try BookmarkHTML.parse(text, budget: &budget), [], []]
        }
        guard budget.links > 0 else { throw BookmarkImportError.empty }
        return Self(roots: roots, links: budget.links, folders: budget.folders)
    }

    /// Fresh local IDs/GUIDs and creation dates; imported sync/checksum/identity
    /// fields are deliberately not copied. Chromium supplies its own checksum.
    func chromiumBytes() throws -> Data {
        var nextID = 3
        let date = String(UInt64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000))
        func node(_ item: ImportedBookmark) -> [String: Any] {
            nextID += 1
            var object: [String: Any] = ["id": String(nextID), "guid": UUID().uuidString.lowercased(), "date_added": date, "date_last_used": "0"]
            switch item {
            case let .link(title, url): object["type"] = "url"; object["name"] = title; object["url"] = url
            case let .folder(title, children): object["type"] = "folder"; object["name"] = title; object["date_modified"] = date; object["children"] = children.map(node)
            }
            return object
        }
        var output: [String: Any] = [:]
        for (index, key) in ["bookmark_bar", "other", "synced"].enumerated() {
            output[key] = ["id": String(index + 1), "guid": UUID().uuidString.lowercased(), "type": "folder", "name": ["Bookmarks bar", "Other bookmarks", "Mobile bookmarks"][index], "date_added": date, "date_modified": date, "children": roots[index].map(node)]
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "roots": output], options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= Self.maximumBytes else { throw BookmarkImportError.limitExceeded }
        return bytes
    }
}

private struct BookmarkBudget {
    var nodes = 0, links = 0, folders = 0
    mutating func admit(depth: Int) throws {
        nodes += 1
        guard nodes <= 10_000, depth <= 32 else { throw BookmarkImportError.limitExceeded }
        try Task.checkCancellation()
    }
    static func title(_ title: String) throws -> String {
        guard title.utf8.count <= 1_024, !title.unicodeScalars.contains(where: { $0.value == 0 }) else { throw BookmarkImportError.limitExceeded }
        return title
    }
    static func url(_ text: String) throws -> String {
        guard text.utf8.count <= 8_192 else { throw BookmarkImportError.limitExceeded }
        guard !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let url = URLComponents(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !text.contains("\\"), url.url != nil else { throw BookmarkImportError.unsupportedURL }
        return text
    }
    mutating func jsonNode(_ value: Any, depth: Int) throws -> ImportedBookmark {
        try admit(depth: depth)
        guard let value = value as? [String: Any], let title = value["name"] as? String else { throw BookmarkImportError.invalidFormat }
        let name = try Self.title(title)
        switch value["type"] as? String {
        case "url":
            guard let text = value["url"] as? String, value["children"] == nil else { throw BookmarkImportError.invalidFormat }
            links += 1; return .link(name, try Self.url(text))
        case "folder":
            guard let children = value["children"] as? [Any], value["url"] == nil else { throw BookmarkImportError.invalidFormat }
            folders += 1; return .folder(name, try children.map { try jsonNode($0, depth: depth + 1) })
        default: throw BookmarkImportError.invalidFormat
        }
    }
}

/// Structural preflight before Foundation parsing: bounded nesting and exact
/// duplicate-key rejection (including escaped equivalent spellings).
private struct BookmarkJSONShape {
    let bytes: [UInt8]; var index = 0, values = 0
    static func validate(_ data: Data) throws {
        try Task.checkCancellation()
        var scanner = Self(bytes: Array(data)); try scanner.value(depth: 0); try scanner.space()
        guard scanner.index == scanner.bytes.count else { throw BookmarkImportError.invalidFormat }
    }
    mutating func space() throws { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { if index % 1_024 == 0 { try Task.checkCancellation() }; index += 1 } }
    mutating func take(_ byte: UInt8) throws { try space(); guard index < bytes.count, bytes[index] == byte else { throw BookmarkImportError.invalidFormat }; index += 1 }
    mutating func string() throws -> String {
        try space(); let start = index; try take(34)
        while index < bytes.count {
            if (index - start) % 1_024 == 0 { try Task.checkCancellation() }
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { break }; index += 1 }
            else if byte == 34 {
                let literal = Data(bytes[start..<index])
                guard let result = try JSONSerialization.jsonObject(with: literal, options: [.fragmentsAllowed]) as? String else { break }
                return result
            }
        }
        throw BookmarkImportError.invalidFormat
    }
    mutating func value(depth: Int) throws {
        values += 1
        guard depth <= 70, values <= 200_000 else { throw BookmarkImportError.limitExceeded }
        try Task.checkCancellation(); try space()
        guard index < bytes.count else { throw BookmarkImportError.invalidFormat }
        if bytes[index] == 34 { _ = try string(); return }
        if bytes[index] == 123 {
            index += 1; try space(); var keys = Set<String>()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            while true {
                guard keys.insert(try string()).inserted else { throw BookmarkImportError.invalidFormat }
                try take(58); try value(depth: depth + 1); try space()
                guard index < bytes.count else { throw BookmarkImportError.invalidFormat }
                if bytes[index] == 125 { index += 1; return }; try take(44)
            }
        }
        if bytes[index] == 91 {
            index += 1; try space()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); try space(); guard index < bytes.count else { throw BookmarkImportError.invalidFormat }
                if bytes[index] == 93 { index += 1; return }; try take(44)
            }
        }
        let start = index
        while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { if (index - start) % 1_024 == 0 { try Task.checkCancellation() }; index += 1 }
        guard index > start else { throw BookmarkImportError.invalidFormat }
        _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])
    }
}

/// Small Netscape export grammar, not a general HTML renderer. Handles omitted
/// DT/P closing tags; refuses executable/unknown elements and ambiguous lists.
private enum BookmarkHTML {
    static func parse(_ text: String, budget: inout BookmarkBudget) throws -> [ImportedBookmark] {
        guard text.prefix(1_024).uppercased().contains("NETSCAPE-BOOKMARK-FILE-1") else { throw BookmarkImportError.invalidFormat }
        var cursor = text.startIndex, lists: [[ImportedBookmark]] = [], titles: [String?] = []
        var pendingFolder: String?, capture: String?, captured = "", href: String?, tokens = 0, finished: [ImportedBookmark]?
        while cursor < text.endIndex {
            try Task.checkCancellation(); tokens += 1
            guard tokens <= 60_000 else { throw BookmarkImportError.limitExceeded }
            guard let start = text[cursor...].firstIndex(of: "<") else {
                guard text[cursor...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BookmarkImportError.invalidFormat }; break
            }
            let chunk = String(text[cursor..<start])
            if capture != nil { captured += chunk; guard captured.utf8.count <= 8_192 else { throw BookmarkImportError.limitExceeded } }
            else if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw BookmarkImportError.invalidFormat }
            if text[start...].hasPrefix("<!--") {
                guard let end = text[start...].range(of: "-->") else { throw BookmarkImportError.invalidFormat }; cursor = end.upperBound; continue
            }
            guard let end = text[start...].firstIndex(of: ">"), text.distance(from: start, to: end) <= 65_536 else { throw BookmarkImportError.invalidFormat }
            var tag = String(text[text.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = text.index(after: end)
            if tag.uppercased() == "!DOCTYPE NETSCAPE-BOOKMARK-FILE-1" { continue }
            let closing = tag.first == "/"; if closing { tag.removeFirst() }
            let name = String(tag.prefix { !$0.isWhitespace }).lowercased()
            guard ["meta", "title", "h1", "h3", "dl", "dt", "p", "a"].contains(name) else { throw BookmarkImportError.invalidFormat }
            let attributes = String(tag.dropFirst(name.count))
            if name == "title" || name == "h1" || name == "h3" || name == "a" {
                if !closing {
                    guard capture == nil else { throw BookmarkImportError.invalidFormat }
                    capture = name; captured = ""
                    if name == "a" {
                        guard !lists.isEmpty, pendingFolder == nil else { throw BookmarkImportError.invalidFormat }
                        href = try attribute("href", in: attributes)
                        guard href != nil else { throw BookmarkImportError.invalidFormat }
                    }
                } else {
                    guard capture == name else { throw BookmarkImportError.invalidFormat }
                    if name == "h3" {
                        guard !lists.isEmpty, pendingFolder == nil else { throw BookmarkImportError.invalidFormat }
                        pendingFolder = try BookmarkBudget.title(entities(captured))
                    } else if name == "a" {
                        try budget.admit(depth: lists.count); budget.links += 1
                        lists[lists.count - 1].append(.link(try BookmarkBudget.title(entities(captured)), try BookmarkBudget.url(entities(href!, permitsLiteralAmpersand: true))))
                    }
                    capture = nil; captured = ""; href = nil
                }
            } else {
                guard capture == nil else { throw BookmarkImportError.invalidFormat }
                if name == "dl" {
                    if !closing {
                        guard lists.count < 32, finished == nil, lists.isEmpty || pendingFolder != nil else { throw BookmarkImportError.invalidFormat }
                        titles.append(pendingFolder); pendingFolder = nil; lists.append([])
                    } else {
                        guard pendingFolder == nil, let children = lists.popLast(), let title = titles.popLast() else { throw BookmarkImportError.invalidFormat }
                        if lists.isEmpty { guard title == nil else { throw BookmarkImportError.invalidFormat }; finished = children }
                        else { guard let title else { throw BookmarkImportError.invalidFormat }; try budget.admit(depth: lists.count); budget.folders += 1; lists[lists.count - 1].append(.folder(title, children)) }
                    }
                }
            }
        }
        guard capture == nil, pendingFolder == nil, lists.isEmpty, let finished else { throw BookmarkImportError.invalidFormat }
        return finished
    }
    private static func attribute(_ key: String, in text: String) throws -> String? {
        // Only inert export attributes are read. Quoted values may contain >;
        // this conservative grammar refuses such ambiguous tags.
        let regex = try NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
        let range = NSRange(text.startIndex..., in: text); var found: String?, names = Set<String>(), end = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), text[end..<whole.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let nameRange = Range(match.range(at: 1), in: text) else { throw BookmarkImportError.invalidFormat }
            let name = text[nameRange].lowercased(); guard names.insert(name).inserted else { throw BookmarkImportError.invalidFormat }
            if name == key { for index in 2...4 { if let r = Range(match.range(at: index), in: text) { found = String(text[r]) } } }
            end = whole.upperBound
        }
        guard text[end...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BookmarkImportError.invalidFormat }
        return found
    }
    private static func entities(_ text: String, permitsLiteralAmpersand: Bool = false) throws -> String {
        var result = "", cursor = text.startIndex
        while let start = text[cursor...].firstIndex(of: "&") {
            result += text[cursor..<start]
            guard let end = text[start...].firstIndex(of: ";"), text.distance(from: start, to: end) <= 16 else {
                if permitsLiteralAmpersand { result += "&"; cursor = text.index(after: start); continue }
                throw BookmarkImportError.invalidFormat
            }
            let token = String(text[text.index(after: start)..<end]); let scalar: UnicodeScalar?
            if let known = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}"][token] { result += known }
            else {
                if token.hasPrefix("#x") || token.hasPrefix("#X") { scalar = UInt32(token.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init) }
                else if token.hasPrefix("#") { scalar = UInt32(token.dropFirst()).flatMap(UnicodeScalar.init) }
                else { scalar = nil }
                guard let scalar, scalar.value != 0 else {
                    if permitsLiteralAmpersand { result += "&"; cursor = text.index(after: start); continue }
                    throw BookmarkImportError.invalidFormat
                }; result.unicodeScalars.append(scalar)
            }
            cursor = text.index(after: end)
        }
        result += text[cursor...]; return result
    }
}
