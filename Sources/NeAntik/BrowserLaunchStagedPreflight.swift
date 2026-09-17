import Foundation

enum BrowserLaunchStage: String, CaseIterable, Equatable, Sendable {
    case runtime
    case storage
    case proxy
    case consistency
    case process

    var title: String {
        switch self {
        case .runtime: "Браузерный движок"
        case .storage: "Локальные данные"
        case .proxy: "Прокси"
        case .consistency: "Профиль"
        case .process: "Процесс"
        }
    }
}

struct BrowserLaunchStagedFailure: LocalizedError, Equatable, Sendable {
    let stage: BrowserLaunchStage
    let message: String
    let recovery: String

    var errorDescription: String? {
        "Этап «\(stage.title)»: \(message) \(recovery)"
    }
}

struct BrowserLaunchPreflightInput: Equatable, Sendable {
    let profile: BrowserProfile
    let processState: BrowserProfileProcessState
    let runtimePreflight: BrowserRuntimePreflight
    let storage: WorkspaceStorageState
    let storageIntegrity: WorkspaceStorageIntegrityState
    let readiness: ProfileReadinessReport?

    init(
        profile: BrowserProfile,
        processState: BrowserProfileProcessState,
        runtimePreflight: BrowserRuntimePreflight,
        storage: WorkspaceStorageState,
        storageIntegrity: WorkspaceStorageIntegrityState = .passed,
        readiness: ProfileReadinessReport? = nil
    ) {
        self.profile = profile
        self.processState = processState
        self.runtimePreflight = runtimePreflight
        self.storage = storage
        self.storageIntegrity = storageIntegrity
        self.readiness = readiness
    }
}

/// A privacy-safe, UI-independent launch preview. It deliberately contains
/// no profile paths, proxy endpoints, process identifiers or browser output.
/// The manager can render it before starting Chromium and the QA harness can
/// persist it as a deterministic explanation of a launch decision.
struct BrowserLaunchDryRun: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        let stage: BrowserLaunchStage
        let title: String
        let state: State
        let detail: String
    }

    enum State: String, Equatable, Sendable {
        case ready
        case review
        case blocked
    }

    let profileID: UUID
    let profileRevision: UInt64
    let profileName: String
    let steps: [Step]

    var isLaunchable: Bool { !steps.contains { $0.state == .blocked } }
    var primaryMessage: String {
        steps.first(where: { $0.state != .ready })?.detail ??
            "Профиль готов к запуску."
    }

    static func build(_ input: BrowserLaunchPreflightInput) -> Self {
        let runtime = input.runtimePreflight.isReady
            ? Step(stage: .runtime, title: "Браузерный движок", state: .ready,
                   detail: "Встроенный Chromium найден и готов.")
            : Step(stage: .runtime, title: "Браузерный движок", state: .blocked,
                   detail: input.runtimePreflight.errors.first ?? "Chromium не готов.")
        let storageState: State
        let storageDetail: String
        switch input.storage {
        case .ready(let capacity):
            if let capacity, capacity < BrowserLaunchStagedPreflight.minimumAvailableCapacity {
                storageState = .review
                storageDetail = "Свободного места мало; запуск возможен после очистки временных данных."
            } else {
                storageState = .ready
                storageDetail = "Папка данных доступна для записи."
            }
        case .checking: storageState = .review; storageDetail = "Проверка локальных данных ещё выполняется."
        case .readOnly: storageState = .blocked; storageDetail = "Папка данных доступна только для чтения."
        case .unavailable: storageState = .blocked; storageDetail = "Папка данных недоступна."
        }
        let proxy: Step
        if let configured = input.profile.proxy {
            proxy = configured.isValid
                ? Step(stage: .proxy, title: "Прокси", state: .review,
                       detail: "Прокси настроен; перед запуском будет выполнена свежая проверка маршрута.")
                : Step(stage: .proxy, title: "Прокси", state: .blocked,
                       detail: "Адрес или порт прокси некорректны.")
        } else {
            proxy = Step(stage: .proxy, title: "Прокси", state: .ready,
                         detail: "Прямое подключение без прокси.")
        }
        let consistency: Step
        if input.profile.isArchived {
            consistency = Step(stage: .consistency, title: "Профиль", state: .blocked,
                               detail: "Профиль находится в архиве.")
        } else if let readiness = input.readiness, readiness.status != .ready {
            consistency = Step(stage: .consistency, title: "Профиль", state: .review,
                               detail: readiness.primaryIssue ?? "Профиль требует проверки.")
        } else {
            consistency = Step(stage: .consistency, title: "Профиль", state: .ready,
                               detail: "Параметры профиля согласованы.")
        }
        let process = input.processState == .stopped
            ? Step(stage: .process, title: "Процесс", state: .ready, detail: "Профиль свободен для запуска.")
            : Step(stage: .process, title: "Процесс", state: .blocked,
                   detail: input.processState.guidance ?? "Профиль уже используется.")
        return Self(profileID: input.profile.id, profileRevision: input.profile.revision,
                    profileName: input.profile.name,
                    steps: [runtime, Step(stage: .storage, title: "Локальные данные", state: storageState, detail: storageDetail), proxy, consistency, process])
    }
}

/// Pure, ordered preflight for an ordinary user launch.
///
/// Keeping the five stages explicit makes a failure actionable without
/// exposing browser-data paths, proxy credentials or process identifiers.
enum BrowserLaunchStagedPreflight {
    static let minimumAvailableCapacity: Int64 = 1_024 * 1_024 * 1_024

    static func validate(_ input: BrowserLaunchPreflightInput) throws {
        if !input.runtimePreflight.isReady {
            throw BrowserLaunchStagedFailure(
                stage: .runtime,
                message: input.runtimePreflight.errors.first ??
                    "встроенный Chromium не готов.",
                recovery: "Переустанови NeAntik из официального DMG или ZIP."
            )
        }

        switch input.storage {
        case .checking:
            throw BrowserLaunchStagedFailure(
                stage: .storage,
                message: "проверка локальных данных ещё выполняется.",
                recovery: "Дождись завершения и повтори запуск."
            )
        case .readOnly:
            throw BrowserLaunchStagedFailure(
                stage: .storage,
                message: "папка данных доступна только для чтения.",
                recovery: "Проверь доступ NeAntik к данным приложения."
            )
        case .unavailable:
            throw BrowserLaunchStagedFailure(
                stage: .storage,
                message: "папка данных недоступна.",
                recovery: "Не удаляй профили; проверь диск и разрешения."
            )
        case let .ready(availableCapacity):
            if let availableCapacity,
               availableCapacity < minimumAvailableCapacity
            {
                throw BrowserLaunchStagedFailure(
                    stage: .storage,
                    message: "на диске меньше 1 ГБ свободного места.",
                    recovery: "Освободи место и повтори запуск."
                )
            }
        }

        switch input.storageIntegrity {
        case .checking:
            throw BrowserLaunchStagedFailure(
                stage: .storage,
                message: "глубокая проверка записи ещё выполняется.",
                recovery: "Дождись завершения и повтори запуск."
            )
        case .failed:
            throw BrowserLaunchStagedFailure(
                stage: .storage,
                message: "не удалось безопасно записать и проверить временные данные.",
                recovery: "Проверь диск и разрешения папки данных, затем повтори запуск."
            )
        case .passed:
            break
        }

        if input.profile.proxy?.isValid == false {
            throw BrowserLaunchStagedFailure(
                stage: .proxy,
                message: "адрес или порт прокси некорректны.",
                recovery: "Измени прокси профиля."
            )
        }

        if let readiness = input.readiness, readiness.status != .ready {
            throw BrowserLaunchStagedFailure(
                stage: .consistency,
                message: readiness.primaryIssue ?? "профиль ещё не готов.",
                recovery: readiness.nextAction ?? "Открой сведения профиля и устрани указанную проблему."
            )
        }

        if input.profile.isArchived {
            throw BrowserLaunchStagedFailure(
                stage: .consistency,
                message: "профиль находится в архиве.",
                recovery: "Верни его из архива перед запуском."
            )
        }

        guard input.processState == .stopped else {
            throw BrowserLaunchStagedFailure(
                stage: .process,
                message: input.processState.title.lowercased() + ".",
                recovery: input.processState.guidance ??
                    "Дождись безопасной сверки состояния."
            )
        }
    }
}
