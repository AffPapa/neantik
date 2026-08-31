import Foundation

enum WorkspaceReadinessLevel: Int, Comparable, Sendable {
    case ready
    case checking
    case attention
    case blocked

    static func < (
        lhs: WorkspaceReadinessLevel,
        rhs: WorkspaceReadinessLevel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .ready: "Готово"
        case .checking: "Проверка"
        case .attention: "Проверь"
        case .blocked: "Исправь"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .checking: "hourglass.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }
}

enum WorkspaceApplicationLocation: Equatable, Sendable {
    case applications
    case development
    case translocated
    case elsewhere

    var diagnosticValue: String {
        switch self {
        case .applications: "applications"
        case .development: "development"
        case .translocated: "translocated"
        case .elsewhere: "elsewhere"
        }
    }
}

struct WorkspaceApplicationIdentity: Equatable, Sendable {
    let displayName: String
    let version: String
    let build: String
    let bundleIdentifier: String
    let bundlePath: String
    let location: WorkspaceApplicationLocation

    static func current(bundle: Bundle = .main) -> Self {
        let bundleURL = bundle.bundleURL.standardizedFileURL
        let bundlePath = bundleURL.path
        let identifier = bundle.bundleIdentifier ?? "unknown"
        let isDevelopment = identifier ==
            NeAntikApplicationEnvironment.developmentBundleIdentifier
        let location: WorkspaceApplicationLocation
        if isDevelopment {
            location = .development
        } else if bundlePath.contains("/AppTranslocation/") {
            location = .translocated
        } else if bundlePath == "/Applications/NeAntik.app" ||
                    bundlePath.hasPrefix("/Applications/")
        {
            location = .applications
        } else {
            location = .elsewhere
        }
        return Self(
            displayName: bundle.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String ?? bundle.object(
                forInfoDictionaryKey: "CFBundleName"
            ) as? String ?? "NeAntik",
            version: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            build: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            bundleIdentifier: identifier,
            bundlePath: bundlePath,
            location: location
        )
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard bundlePath == home || bundlePath.hasPrefix(home + "/") else {
            return bundlePath
        }
        return "~" + bundlePath.dropFirst(home.count)
    }
}

enum WorkspaceStorageState: Equatable, Sendable {
    case checking
    case ready(availableCapacity: Int64?)
    case readOnly
    case unavailable
}

struct WorkspaceReadinessSystemInspection: Equatable, Sendable {
    let application: WorkspaceApplicationIdentity
    let storage: WorkspaceStorageState

    static func checking(
        application: WorkspaceApplicationIdentity
    ) -> Self {
        Self(application: application, storage: .checking)
    }
}

enum WorkspaceReadinessSystemInspector {
    static func inspect(
        application: WorkspaceApplicationIdentity,
        dataRootURL: URL,
        fileManager: FileManager = .default
    ) -> WorkspaceReadinessSystemInspection {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: dataRootURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue,
              fileManager.isReadableFile(atPath: dataRootURL.path)
        else {
            return WorkspaceReadinessSystemInspection(
                application: application,
                storage: .unavailable
            )
        }
        guard fileManager.isWritableFile(atPath: dataRootURL.path) else {
            return WorkspaceReadinessSystemInspection(
                application: application,
                storage: .readOnly
            )
        }
        let capacity = try? dataRootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        return WorkspaceReadinessSystemInspection(
            application: application,
            storage: .ready(availableCapacity: capacity ?? nil)
        )
    }
}

struct WorkspaceReadinessItem: Identifiable, Equatable, Sendable {
    enum ID: String, Sendable {
        case application
        case runtime
        case storage
        case processes
        case routes
    }

    let id: ID
    let title: String
    let value: String
    let detail: String
    let level: WorkspaceReadinessLevel

    var accessibilitySummary: String {
        "\(title). \(level.title). \(value). \(detail)"
    }
}

struct WorkspaceReadinessInput: Equatable, Sendable {
    let system: WorkspaceReadinessSystemInspection
    let runtimeAvailability: BrowserRuntimeAvailability
    let runtimeVersion: String?
    let runtimeArchitectures: [String]
    let profileCount: Int
    let runningCount: Int
    let processAttentionCount: Int
    let directRouteCount: Int
    let proxiedRouteCount: Int
    let proxyAttentionCount: Int
}

struct WorkspaceReadinessSnapshot: Equatable, Sendable {
    let level: WorkspaceReadinessLevel
    let title: String
    let summary: String
    let items: [WorkspaceReadinessItem]
    let diagnosticText: String

    static func resolve(_ input: WorkspaceReadinessInput) -> Self {
        let items = [
            applicationItem(input.system.application),
            runtimeItem(
                availability: input.runtimeAvailability,
                version: input.runtimeVersion,
                architectures: input.runtimeArchitectures
            ),
            storageItem(input.system.storage),
            processItem(
                profileCount: input.profileCount,
                runningCount: input.runningCount,
                attentionCount: input.processAttentionCount
            ),
            routeItem(
                profileCount: input.profileCount,
                directCount: input.directRouteCount,
                proxiedCount: input.proxiedRouteCount,
                attentionCount: input.proxyAttentionCount
            ),
        ]
        let level = items.map(\.level).max() ?? .ready
        let title: String
        let summary: String
        switch level {
        case .ready:
            title = "NeAntik готов"
            summary = "Движок и локальные данные доступны."
        case .checking:
            title = "Проверяем готовность…"
            summary = "Дождись завершения локальных проверок."
        case .attention:
            title = "Есть что проверить"
            summary = "Запуск доступен, но есть важные предупреждения."
        case .blocked:
            title = "Запуск требует исправления"
            summary = "Исправь блокирующие пункты и нажми «Проверить снова»."
        }
        return Self(
            level: level,
            title: title,
            summary: summary,
            items: items,
            diagnosticText: diagnosticText(input, items: items, level: level)
        )
    }

    private static func applicationItem(
        _ application: WorkspaceApplicationIdentity
    ) -> WorkspaceReadinessItem {
        let value = "\(application.displayName) \(application.version) (\(application.build))"
        switch application.location {
        case .applications:
            return WorkspaceReadinessItem(
                id: .application,
                title: "Приложение",
                value: value,
                detail: "Установлено в Applications. В разрешениях macOS выбирай именно NeAntik.app.",
                level: .ready
            )
        case .development:
            return WorkspaceReadinessItem(
                id: .application,
                title: "Приложение",
                value: value,
                detail: "Изолированная Dev-сборка. Публичный релиз не изменяется.",
                level: .ready
            )
        case .translocated:
            return WorkspaceReadinessItem(
                id: .application,
                title: "Приложение",
                value: value,
                detail: "macOS запустила временную копию. Перемести NeAntik.app в Applications и открой заново.",
                level: .attention
            )
        case .elsewhere:
            return WorkspaceReadinessItem(
                id: .application,
                title: "Приложение",
                value: value,
                detail: "Лучше переместить NeAntik.app в Applications, чтобы путь и разрешения не менялись.",
                level: .attention
            )
        }
    }

    private static func runtimeItem(
        availability: BrowserRuntimeAvailability,
        version: String?,
        architectures: [String]
    ) -> WorkspaceReadinessItem {
        switch availability {
        case .resolving:
            return WorkspaceReadinessItem(
                id: .runtime,
                title: "Браузерный движок",
                value: "Проверяем…",
                detail: "Проверяем наличие, архитектуру и подпись встроенного Chromium.",
                level: .checking
            )
        case .ready:
            let parts = [version.map { "Chromium \($0)" }]
                .compactMap { $0 } + architectures
            return WorkspaceReadinessItem(
                id: .runtime,
                title: "Браузерный движок",
                value: parts.isEmpty ? "Готов" : parts.joined(separator: " · "),
                detail: "Встроенный движок прошёл локальную проверку готовности.",
                level: .ready
            )
        case .missing:
            return WorkspaceReadinessItem(
                id: .runtime,
                title: "Браузерный движок",
                value: "Не найден",
                detail: "Переустанови NeAntik из официального DMG или ZIP. Данные профилей удалять не нужно.",
                level: .blocked
            )
        case let .invalid(message):
            let detail = message.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return WorkspaceReadinessItem(
                id: .runtime,
                title: "Браузерный движок",
                value: "Проверка не пройдена",
                detail: detail.isEmpty
                    ? "Переустанови NeAntik из официального DMG или ZIP."
                    : detail,
                level: .blocked
            )
        }
    }

    private static func storageItem(
        _ storage: WorkspaceStorageState
    ) -> WorkspaceReadinessItem {
        switch storage {
        case .checking:
            return WorkspaceReadinessItem(
                id: .storage,
                title: "Локальные данные",
                value: "Проверяем…",
                detail: "Проверяем доступ к общей папке данных NeAntik.",
                level: .checking
            )
        case let .ready(capacity):
            let value = capacity.map {
                "Доступны · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) свободно"
            } ?? "Доступны"
            return WorkspaceReadinessItem(
                id: .storage,
                title: "Локальные данные",
                value: value,
                detail: "Метаданные и папки профилей доступны для чтения и записи.",
                level: .ready
            )
        case .readOnly:
            return WorkspaceReadinessItem(
                id: .storage,
                title: "Локальные данные",
                value: "Только чтение",
                detail: "Разреши NeAntik записывать данные приложения и проверь снова.",
                level: .blocked
            )
        case .unavailable:
            return WorkspaceReadinessItem(
                id: .storage,
                title: "Локальные данные",
                value: "Недоступны",
                detail: "Общая папка данных NeAntik недоступна. Не удаляй профили; сначала проверь диск и разрешения.",
                level: .blocked
            )
        }
    }

    private static func processItem(
        profileCount: Int,
        runningCount: Int,
        attentionCount: Int
    ) -> WorkspaceReadinessItem {
        if attentionCount > 0 {
            return WorkspaceReadinessItem(
                id: .processes,
                title: "Процессы",
                value: "Требуют внимания: \(attentionCount)",
                detail: "Закрой отмеченные окна вручную или выполни повторную сверку состояния.",
                level: .attention
            )
        }
        return WorkspaceReadinessItem(
            id: .processes,
            title: "Процессы",
            value: profileCount == 0
                ? "Нет профилей"
                : "Запущено: \(runningCount) из \(profileCount)",
            detail: "Необъяснённых или восстановительных процессов нет.",
            level: .ready
        )
    }

    private static func routeItem(
        profileCount: Int,
        directCount: Int,
        proxiedCount: Int,
        attentionCount: Int
    ) -> WorkspaceReadinessItem {
        if attentionCount > 0 {
            return WorkspaceReadinessItem(
                id: .routes,
                title: "Подключения",
                value: "Прокси требуют внимания: \(attentionCount)",
                detail: "Повтори проверку неуспешных или неполных прокси перед запуском.",
                level: .attention
            )
        }
        if directCount > 0 {
            return WorkspaceReadinessItem(
                id: .routes,
                title: "Подключения",
                value: "Без прокси: \(directCount) · С прокси: \(proxiedCount)",
                detail: "Прямые профили используют обычный публичный адрес Mac или системного VPN.",
                level: .attention
            )
        }
        return WorkspaceReadinessItem(
            id: .routes,
            title: "Подключения",
            value: profileCount == 0 ? "Нет профилей" : "С прокси: \(proxiedCount)",
            detail: profileCount == 0
                ? "Настрой подключение при создании первого профиля."
                : "Записанных ошибок последней проверки прокси нет.",
            level: .ready
        )
    }

    private static func diagnosticText(
        _ input: WorkspaceReadinessInput,
        items: [WorkspaceReadinessItem],
        level: WorkspaceReadinessLevel
    ) -> String {
        let application = input.system.application
        let storage: String
        switch input.system.storage {
        case .checking: storage = "checking"
        case .ready: storage = "ready"
        case .readOnly: storage = "read-only"
        case .unavailable: storage = "unavailable"
        }
        let runtime: String
        switch input.runtimeAvailability {
        case .resolving: runtime = "checking"
        case .ready: runtime = "ready"
        case .missing: runtime = "missing"
        case .invalid: runtime = "invalid"
        }
        let architecture = input.runtimeArchitectures.isEmpty
            ? "unknown"
            : input.runtimeArchitectures.joined(separator: "+")
        return [
            "NeAntik readiness",
            "overall=\(level.title.lowercased())",
            "app=\(application.version) (\(application.build))",
            "bundle=\(application.bundleIdentifier)",
            "location=\(application.location.diagnosticValue)",
            "runtime=\(runtime)",
            "runtimeVersion=\(input.runtimeVersion ?? "unknown")",
            "runtimeArch=\(architecture)",
            "storage=\(storage)",
            "profiles=\(input.profileCount)",
            "running=\(input.runningCount)",
            "processAttention=\(input.processAttentionCount)",
            "directRoutes=\(input.directRouteCount)",
            "proxiedRoutes=\(input.proxiedRouteCount)",
            "proxyAttention=\(input.proxyAttentionCount)",
            "checks=\(items.count)",
        ].joined(separator: "\n")
    }
}
