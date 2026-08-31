import Foundation

/// Semantic process-state tone shared by every profile surface.
///
/// Manual-close and recovery states are deliberately not presented as healthy
/// just because a process exists: they require the user's attention.
enum BrowserProcessStatusTone: Equatable, Sendable {
    case neutral
    case activity
    case healthy
    case attention
}

extension BrowserProfileProcessState {
    var statusTone: BrowserProcessStatusTone {
        switch self {
        case .stopped:
            .neutral
        case .checking, .closing:
            .activity
        case .managed, .externalVerified:
            .healthy
        case .forceStopAvailable, .externalManualOnly,
             .externalUnverified, .recoveryRequired:
            .attention
        }
    }
}

/// The user-facing availability of the embedded browser engine.
///
/// This deliberately distinguishes a completed lookup with no engine from a
/// lookup that is still running. A Boolean loading flag cannot represent the
/// missing and invalid states needed to explain a disabled launch action.
enum BrowserRuntimeAvailability: Equatable, Sendable {
    case resolving
    case ready
    case missing
    case invalid(message: String)
}

/// A UI-independent description of the profile's primary launch action.
///
/// Keeping this decision outside individual SwiftUI surfaces prevents the
/// toolbar, profile rows, menus, and detail view from presenting conflicting
/// actions for the same process state.
struct BrowserLaunchActionPresentation: Equatable, Sendable {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let help: String

    static func resolve(
        processState: BrowserProfileProcessState,
        isArchived: Bool,
        runtimeAvailability: BrowserRuntimeAvailability,
        isProxyTesting: Bool = false,
        isLaunchPreparation: Bool = false
    ) -> Self {
        switch processState {
        case .managed, .externalVerified:
            // A known running process always keeps its safe stop action. In
            // particular, an unrelated runtime lookup must not strand it.
            return Self(
                title: "Остановить",
                systemImage: "stop.fill",
                isEnabled: true,
                help: processState.guidance ?? "Остановить профиль"
            )

        case .closing:
            return Self(
                title: "Закрывается…",
                systemImage: "hourglass",
                isEnabled: false,
                help: processState.guidance ?? "Chromium завершает работу"
            )

        case .forceStopAvailable:
            return Self(
                title: "Не отвечает",
                systemImage: "exclamationmark.octagon.fill",
                isEnabled: false,
                help: processState.guidance ??
                    "Принудительная остановка доступна в сведениях профиля"
            )

        case .checking:
            if isLaunchPreparation {
                return Self(
                    title: "Отменить подготовку",
                    systemImage: "xmark.circle.fill",
                    isEnabled: true,
                    help: "Отменить проверку прокси и запуск профиля"
                )
            }
            return Self(
                title: "Подготовка…",
                systemImage: "hourglass",
                isEnabled: false,
                help: processState.guidance ??
                    "NeAntik подготавливает данные профиля"
            )

        case .externalManualOnly, .externalUnverified, .recoveryRequired:
            return Self(
                title: "Закрыть вручную",
                systemImage: "hand.raised.fill",
                isEnabled: false,
                help: processState.guidance ??
                    "Закрой окно браузера вручную"
            )

        case .stopped:
            if isArchived {
                return Self(
                    title: "В архиве",
                    systemImage: "archivebox",
                    isEnabled: false,
                    help: "Верни профиль из архива, чтобы запустить"
                )
            }

            if isProxyTesting {
                return Self(
                    title: "Проверка прокси…",
                    systemImage: "hourglass",
                    isEnabled: false,
                    help: "Проверка прокси уже выполняется"
                )
            }

            switch runtimeAvailability {
            case .resolving:
                return Self(
                    title: "Проверка…",
                    systemImage: "hourglass",
                    isEnabled: false,
                    help: "NeAntik проверяет браузерный движок. " +
                        "Запуск станет доступен после проверки."
                )

            case .ready:
                return Self(
                    title: "Запустить",
                    systemImage: "play.fill",
                    isEnabled: true,
                    help: "Запустить профиль"
                )

            case .missing:
                return Self(
                    title: "Запустить",
                    systemImage: "play.fill",
                    isEnabled: false,
                    help: "Встроенный браузерный движок не найден. " +
                        "Переустанови NeAntik из официального DMG или ZIP."
                )

            case let .invalid(message):
                let detail = message.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return Self(
                    title: "Запустить",
                    systemImage: "play.fill",
                    isEnabled: false,
                    help: detail.isEmpty
                        ? "Браузерный движок не готов. Переустанови " +
                            "NeAntik из официального DMG или ZIP."
                        : "Браузерный движок не готов: \(detail)"
                )
            }
        }
    }

}
