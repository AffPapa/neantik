import Foundation

/// Small, presentation-agnostic building blocks for the "simple by default"
/// workspace. SwiftUI can keep the advanced controls behind the command palette
/// without duplicating business rules.
enum WorkspaceCommand: String, CaseIterable, Identifiable, Sendable {
    case newProfile, search, reopenLast, cleanLaunch, duplicate, inspectFingerprint
    var id: Self { self }
    var title: String {
        switch self {
        case .newProfile: "Новое рабочее место"
        case .search: "Найти рабочее место"
        case .reopenLast: "Открыть последнее место"
        case .cleanLaunch: "Чистый запуск"
        case .duplicate: "Создать похожее"
        case .inspectFingerprint: "Проверить согласованность среды"
        }
    }
    var keywords: [String] {
        switch self {
        case .newProfile: ["создать", "профиль", "рабочее место", "new"]
        case .search: ["найти", "поиск", "фильтр", "search"]
        case .reopenLast: ["последний", "вернуться", "recent"]
        case .cleanLaunch: ["чистый", "без вкладок", "временные данные"]
        case .duplicate: ["копия", "клонировать", "похожий"]
        case .inspectFingerprint: ["отпечаток", "fingerprint", "проверка", "согласованность"]
        }
    }
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !q.isEmpty else { return true }
        return ([title] + keywords).contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(q) }
    }
}

struct ProfileSearchMatch: Equatable, Sendable {
    let profileID: UUID
    let score: Int
    let matchedFields: [String]
}

enum ProfileSemanticSearch {
    static func rank(_ profiles: [BrowserProfile], query: String) -> [ProfileSearchMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return profiles.map { ProfileSearchMatch(profileID: $0.id, score: 0, matchedFields: []) } }
        let folded = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return profiles.compactMap { profile in
            var score = 0; var fields: [String] = []
            func test(_ value: String, _ field: String, _ weight: Int) {
                let candidate = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard candidate.contains(folded) else { return }
                score += candidate == folded ? weight + 20 : weight
                fields.append(field)
            }
            test(profile.name, "название", 100)
            test(profile.note, "заметка", 40)
            profile.tags.forEach { test($0, "тег", 60) }
            test(profile.startURL, "стартовый сайт", 20)
            guard score > 0 else { return nil }
            return ProfileSearchMatch(profileID: profile.id, score: score, matchedFields: fields)
        }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.profileID.uuidString < $1.profileID.uuidString }
    }
}

enum ProfileAutomationSuggestions {
    static func tags(for profiles: [BrowserProfile], minimumCount: Int = 2) -> [String] {
        let counts = profiles.flatMap(\.tags).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        return counts.filter { $0.value >= minimumCount }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(\.key)
    }
    static func suggestions(for profiles: [BrowserProfile], now: Date = Date()) -> [String] {
        var result = tags(for: profiles)
        if profiles.contains(where: { $0.proxy == nil }) { result.append("Без прокси") }
        if profiles.contains(where: { $0.lastLaunchedAt == nil }) { result.append("Ни разу не запускались") }
        if profiles.contains(where: { $0.lastLaunchedAt.map { now.timeIntervalSince($0) > 30 * 86400 } ?? false }) { result.append("Давно не запускались") }
        return result
    }
}

enum CleanLaunchMode: String, Codable, CaseIterable, Sendable { case normal, clean
    var title: String { self == .normal ? "Обычный запуск" : "Чистый запуск" }
    var explanation: String { self == .normal ? "Вернуть сохранённые вкладки и состояние." : "Открыть среду без сохранённых вкладок и временных данных." }
}

struct StartupTabSet: Codable, Equatable, Sendable {
    static let maximumCount = 20
    static let maximumURLBytes = 16 * 1024
    var urls: [String]
    init(urls: [String] = []) { self.urls = Array(urls.prefix(Self.maximumCount)) }
    var validURLs: [URL] { urls.compactMap { URL(string: $0) }.filter { $0.scheme == "http" || $0.scheme == "https" } }
    var isValid: Bool { urls.count <= Self.maximumCount && urls.allSatisfy { $0.utf8.count <= Self.maximumURLBytes && URL(string: $0)?.scheme.map { $0 == "http" || $0 == "https" } == true } }
}

struct LocalActivityEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: Kind
    let profileID: UUID?
    let date: Date
    enum Kind: String, Codable, Sendable { case launched, stopped, restored, proxyFailed, snapshotCreated, cleanLaunch }
    init(kind: Kind, profileID: UUID? = nil, date: Date = Date()) { id = UUID(); self.kind = kind; self.profileID = profileID; self.date = date }
}

/// Bounded, local-only activity history for the compact profile surface.
/// It deliberately stores identifiers and event kinds only: URLs, proxy
/// values, cookies and profile names never enter this journal.
struct LocalActivityLogStore: Sendable {
    let fileURL: URL
    let maximumEvents: Int

    init(rootDirectory: URL, maximumEvents: Int = 100) {
        self.fileURL = rootDirectory.appendingPathComponent("activity-log.json")
        self.maximumEvents = max(1, maximumEvents)
    }

    func events(limit: Int? = nil) -> [LocalActivityEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.neantikStable.decode(
                [LocalActivityEvent].self, from: data
              ) else { return [] }
        let ordered = decoded.sorted { $0.date > $1.date }
        return Array(ordered.prefix(max(0, limit ?? maximumEvents)))
    }

    func append(_ event: LocalActivityEvent) throws {
        var current = events()
        current.removeAll { $0.id == event.id }
        current.insert(event, at: 0)
        let data = try JSONEncoder.neantikStable.encode(
            Array(current.prefix(maximumEvents))
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    fileURL, withItemAt: temporary, backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

struct FingerprintExplanation: Equatable, Sendable {
    let title: String
    let details: [String]
    var isConsistent: Bool { details.allSatisfy { !$0.hasPrefix("Проверь") } }
    static func resolve(profile: BrowserProfile) -> Self {
        var details = ["Идентичность закреплена за этим рабочим местом."]
        if profile.identity.timezoneIdentifier == nil { details.append("Проверь часовой пояс: он не задан.") }
        if profile.identity.localeIdentifier == nil { details.append("Проверь язык: он не задан.") }
        if profile.proxy == nil { details.append("Прямое подключение: прокси не используется.") }
        return Self(title: isReady(details) ? "Среда согласована" : "Нужна проверка", details: details)
    }
    private static func isReady(_ details: [String]) -> Bool { !details.contains { $0.hasPrefix("Проверь") } }
}
