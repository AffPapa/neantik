import Foundation

struct ProfileOperationalHealthIssue: Codable, Equatable, Identifiable, Sendable {
    enum Severity: String, Codable, Sendable {
        case info
        case warning
        case blocking
    }

    let id: String
    let severity: Severity
    let title: String
    let explanation: String
    let actionTitle: String
    let canAutoFix: Bool
}

struct ProfileOperationalHealthReport: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case ready
        case review
        case blocked
    }

    let status: Status
    let title: String
    let primaryIssue: ProfileOperationalHealthIssue?
    let issues: [ProfileOperationalHealthIssue]
    let checkedAt: Date

    var canLaunchWithWarning: Bool {
        status != .blocked
    }

    var automaticActionTitles: [String] {
        issues.filter(\.canAutoFix).map(\.actionTitle)
    }
}

enum ProfileOperationalHealthEvaluator {
    static let lowFreeDiskBytes: Int64 = 512 * 1_024 * 1_024

    static func evaluate(
        profile: BrowserProfile,
        readiness: ProfileReadinessReport,
        storage: ProfileStorageSurfaceReport? = nil,
        extensions: ExtensionSurfaceReport? = nil,
        profileDirectoryExists: Bool = true,
        hasActiveLock: Bool = false,
        runtimeReady: Bool = true,
        freeDiskBytes: Int64? = nil,
        now: Date = Date()
    ) -> ProfileOperationalHealthReport {
        var issues: [ProfileOperationalHealthIssue] = []
        if profile.isArchived {
            issues.append(issue(
                id: "archived",
                severity: .blocking,
                title: "Профиль в архиве",
                explanation: "Архивный профиль нельзя запускать, пока он не восстановлен.",
                actionTitle: "Восстановить профиль",
                canAutoFix: false
            ))
        }
        if !profileDirectoryExists {
            issues.append(issue(
                id: "missing-directory",
                severity: .blocking,
                title: "Нет папки профиля",
                explanation: "NeAntik не нашёл локальную папку рабочего места.",
                actionTitle: "Восстановить папку из snapshot",
                canAutoFix: true
            ))
        }
        if hasActiveLock {
            issues.append(issue(
                id: "active-lock",
                severity: .blocking,
                title: "Профиль уже открыт",
                explanation: "Одновременный запуск может испортить Chromium-данные профиля.",
                actionTitle: "Показать открытое окно",
                canAutoFix: false
            ))
        }
        if !runtimeReady || readiness.issues.contains(where: { $0.contains("Chromium") }) {
            issues.append(issue(
                id: "runtime",
                severity: .warning,
                title: "Нужно проверить Chromium",
                explanation: "Профиль можно открыть только после проверки совместимости runtime.",
                actionTitle: "Проверить runtime",
                canAutoFix: true
            ))
        }
        if profile.proxy != nil && readiness.issues.contains(where: { $0.contains("Прокси") }) {
            issues.append(issue(
                id: "proxy-check",
                severity: .warning,
                title: "Прокси не проверялся",
                explanation: "Перед запуском стоит проверить доступность маршрута, не раскрывая endpoint в отчётах.",
                actionTitle: "Проверить прокси",
                canAutoFix: true
            ))
        }
        if storage?.requiresReview == true {
            issues.append(issue(
                id: "storage-review",
                severity: .warning,
                title: "Локальное хранилище требует внимания",
                explanation: "Одна из storage-поверхностей слишком большая или недоступна для быстрой проверки.",
                actionTitle: "Открыть сведения storage",
                canAutoFix: false
            ))
        }
        if extensions?.requiresReview == true {
            issues.append(issue(
                id: "extensions-review",
                severity: .warning,
                title: "Расширения могут влиять на среду",
                explanation: "Найдены расширения с широким доступом или чувствительными разрешениями.",
                actionTitle: "Посмотреть расширения",
                canAutoFix: false
            ))
        }
        if let freeDiskBytes, freeDiskBytes < lowFreeDiskBytes {
            issues.append(issue(
                id: "low-disk",
                severity: .warning,
                title: "Мало свободного места",
                explanation: "Chromium может нестабильно сохранять вкладки и локальное состояние.",
                actionTitle: "Освободить cache/temp",
                canAutoFix: true
            ))
        }

        let status: ProfileOperationalHealthReport.Status
        if issues.contains(where: { $0.severity == .blocking }) {
            status = .blocked
        } else if issues.isEmpty {
            status = .ready
        } else {
            status = .review
        }
        return ProfileOperationalHealthReport(
            status: status,
            title: title(for: status),
            primaryIssue: issues.first,
            issues: issues,
            checkedAt: now
        )
    }

    private static func title(
        for status: ProfileOperationalHealthReport.Status
    ) -> String {
        switch status {
        case .ready: "Готов"
        case .review: "Можно запустить, но лучше проверить"
        case .blocked: "Запуск заблокирован"
        }
    }

    private static func issue(
        id: String,
        severity: ProfileOperationalHealthIssue.Severity,
        title: String,
        explanation: String,
        actionTitle: String,
        canAutoFix: Bool
    ) -> ProfileOperationalHealthIssue {
        ProfileOperationalHealthIssue(
            id: id,
            severity: severity,
            title: title,
            explanation: explanation,
            actionTitle: actionTitle,
            canAutoFix: canAutoFix
        )
    }
}

struct ProfileDisposableCleanupCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let relativePath: String
    let explanation: String
}

struct ProfileDisposableCleanupPlan: Codable, Equatable, Sendable {
    let candidates: [ProfileDisposableCleanupCandidate]

    var isEmpty: Bool {
        candidates.isEmpty
    }
}

enum ProfileDisposableCleanupPlanner {
    static let disposableRelativePaths = [
        "Default/Cache",
        "Default/Code Cache",
        "Default/GPUCache",
        "Default/ShaderCache",
        "Default/GrShaderCache",
        "Default/Crashpad",
        "Default/Service Worker/ScriptCache"
    ]

    static func plan(
        profileDirectory: URL,
        fileManager: FileManager = .default
    ) -> ProfileDisposableCleanupPlan {
        let candidates = disposableRelativePaths.compactMap { relativePath -> ProfileDisposableCleanupCandidate? in
            let url = profileDirectory.appendingPathComponent(relativePath)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  url.standardizedFileURL.path.hasPrefix(profileDirectory.standardizedFileURL.path + "/")
            else { return nil }
            return ProfileDisposableCleanupCandidate(
                id: relativePath,
                relativePath: relativePath,
                explanation: "Можно удалить без cookies, паролей и профиля: Chromium пересоздаст эту cache-папку."
            )
        }
        return ProfileDisposableCleanupPlan(candidates: candidates)
    }
}

enum CheckerFixtureProfileFactory {
    static func makeLocalFixtures(now: Date = Date()) -> [BrowserProfile] {
        [
            BrowserProfile(
                name: "QA · Нормальный профиль",
                tags: ["QA", "normal"],
                note: "Фикстура: согласованная локальная среда без прокси и расширений.",
                createdAt: now,
                updatedAt: now
            ),
            BrowserProfile(
                name: "QA · Конфликт среды",
                tags: ["QA", "conflict"],
                note: "Фикстура: использовать для проверки объяснений readiness и checker matrix.",
                identity: BrowserIdentity(
                    timezoneIdentifier: "Europe/Berlin",
                    localeIdentifier: "en_US"
                ),
                createdAt: now,
                updatedAt: now
            ),
            BrowserProfile(
                name: "QA · После сбоя",
                tags: ["QA", "crash"],
                note: "Фикстура: recovery, lock-файлы, snapshot и понятная причина запуска.",
                createdAt: now,
                updatedAt: now
            ),
            BrowserProfile(
                name: "QA · Расширения",
                tags: ["QA", "extensions"],
                note: "Фикстура: проверять broad permissions и влияние расширений без чтения истории.",
                createdAt: now,
                updatedAt: now
            )
        ]
    }
}

struct ReleaseQACheck: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let passed: Bool
    let evidence: String
}

struct ReleaseQASnapshot: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let checks: [ReleaseQACheck]

    var isReady: Bool {
        checks.allSatisfy(\.passed)
    }

    var summary: String {
        let passed = checks.filter(\.passed).count
        return "Release QA: \(passed)/\(checks.count) · \(isReady ? "готово" : "нужна проверка")"
    }
}

enum ReleaseQASnapshotBuilder {
    static func build(
        version: String,
        build: String,
        testsPassed: Bool,
        openSourceTreePassed: Bool,
        zipNotarized: Bool,
        dmgNotarized: Bool,
        githubAssetsVerified: Bool,
        siteGatePassed: Bool
    ) -> ReleaseQASnapshot {
        ReleaseQASnapshot(
            version: version,
            build: build,
            checks: [
                check("tests", "Тесты", testsPassed, "XCTest и Swift Testing"),
                check("oss", "Open-source дерево", openSourceTreePassed, "без build roots и секретов"),
                check("zip", "ZIP notarized", zipNotarized, "Developer ID, Apple notarization, Gatekeeper"),
                check("dmg", "DMG notarized", dmgNotarized, "stapled, mounted-app accepted"),
                check("github", "GitHub assets", githubAssetsVerified, "скачивание и sha256"),
                check("site", "Сайт", siteGatePassed, "официальный affpapa release gate")
            ]
        )
    }

    private static func check(
        _ id: String,
        _ title: String,
        _ passed: Bool,
        _ evidence: String
    ) -> ReleaseQACheck {
        ReleaseQACheck(id: id, title: title, passed: passed, evidence: evidence)
    }
}
