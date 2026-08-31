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

        if input.profile.proxy?.isValid == false {
            throw BrowserLaunchStagedFailure(
                stage: .proxy,
                message: "адрес или порт прокси некорректны.",
                recovery: "Измени прокси профиля."
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
