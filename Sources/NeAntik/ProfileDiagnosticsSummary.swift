import Foundation

enum ProfileDiagnosticsStatus: Equatable, Sendable {
    case ready
    case attention
    case checking
    case unavailable

    var title: String {
        switch self {
        case .ready:
            "В порядке"
        case .attention:
            "Требует внимания"
        case .checking:
            "Считается размер…"
        case .unavailable:
            "Проверка недоступна"
        }
    }
}

enum ProfileDiagnosticsNextStep: Equatable, Sendable {
    case none
    case recoverProfile
    case waitForProfile
    case retryInspection
    case runtimeNeedsAttention
    case inspectDetails

    var accessibilityLabel: String? {
        title.map { "Следующий шаг: \($0)" }
    }

    var title: String? {
        switch self {
        case .none:
            nil
        case .recoverProfile:
            "Закрой профиль и повтори запуск, чтобы завершить восстановление."
        case .waitForProfile:
            "Дождись завершения текущей операции и проверь профиль снова."
        case .retryInspection:
            "Повтори проверку после того, как приложение закончит текущую операцию."
        case .runtimeNeedsAttention:
            "Проверь встроенный движок перед следующим запуском."
        case .inspectDetails:
            "Открой подробности диагностики перед следующим запуском."
        }
    }
}

struct ProfileDiagnosticsSummary: Equatable, Sendable {
    let status: ProfileDiagnosticsStatus
    let detail: String
    let nextStep: ProfileDiagnosticsNextStep

    static func resolve(
        lifecycle: ProfileLifecycleHealthSnapshot,
        privacyPanel: ProfilePrivacyPanelSnapshot = .empty,
        artifactProvenance: ProfileArtifactProvenanceSnapshot = .empty,
        runtimeProvenance: RuntimeProvenanceSnapshot = .empty
    ) -> Self {
        switch lifecycle.recovery {
        case .required:
            return Self(
                status: .attention,
                detail: "Профилю требуется восстановление перед запуском.",
                nextStep: .recoverProfile
            )
        case .unavailable:
            return Self(
                status: .unavailable,
                detail: "Состояние восстановления пока нельзя проверить.",
                nextStep: .retryInspection
            )
        case .clear:
            break
        }

        switch lifecycle.lock {
        case .active:
            return Self(
                status: .attention,
                detail: "Профиль занят другим процессом или ещё завершается.",
                nextStep: .waitForProfile
            )
        case .unavailable:
            return Self(
                status: .unavailable,
                detail: "Состояние блокировки пока нельзя проверить.",
                nextStep: .retryInspection
            )
        case .clear, .managed:
            break
        }

        switch lifecycle.browserData {
        case .checking:
            return Self(
                status: .checking,
                detail: "Подсчитывается размер локальных данных профиля.",
                nextStep: .none
            )
        case .unavailable:
            return Self(
                status: .unavailable,
                detail: "Размер локальных данных пока нельзя проверить.",
                nextStep: .retryInspection
            )
        case .missing where lifecycle.lastLaunchedAt != nil:
            return Self(
                status: .attention,
                detail: "После предыдущего запуска данные профиля не найдены.",
                nextStep: .inspectDetails
            )
        case .missing, .available:
            break
        }

        if privacyPanel.mediaDevices == .unavailable ||
            privacyPanel.permissionsAPI == .unavailable
        {
            return Self(
                status: .unavailable,
                detail: "Панель приватности пока нельзя полностью проверить.",
                nextStep: .retryInspection
            )
        }

        if artifactProvenance.downloads == .unavailable ||
            artifactProvenance.extensions == .unavailable ||
            artifactProvenance.quarantine == .unavailable
        {
            return Self(
                status: .unavailable,
                detail: "Состояние файлов профиля пока нельзя проверить.",
                nextStep: .retryInspection
            )
        }

        if runtimeProvenance.name == "Движок не выбран" ||
            runtimeProvenance.preflight == "Проверка не завершена"
        {
            return Self(
                status: .unavailable,
                detail: "Встроенный движок ещё не прошёл проверку запуска.",
                nextStep: .retryInspection
            )
        }

        if runtimeProvenance.publicReleaseStatus == "Не определён" {
            return Self(
                status: .unavailable,
                detail: "Статус версии встроенного движка пока нельзя проверить.",
                nextStep: .retryInspection
            )
        }

        if runtimeProvenance.architecture == "Не проверена" ||
            runtimeProvenance.signature == "Не проверена" ||
            runtimeProvenance.executableDigest == "Не измерен" ||
            runtimeProvenance.frameworkDigest == "Не измерен"
        {
            return Self(
                status: .unavailable,
                detail: "Происхождение встроенного движка проверено не полностью.",
                nextStep: .retryInspection
            )
        }

        if runtimeProvenance.publicReleaseStatus.contains("заблокирован") {
            return Self(
                status: .attention,
                detail: "Версия встроенного движка ниже принятого Direct baseline.",
                nextStep: .runtimeNeedsAttention
            )
        }

        if runtimeProvenance.preflight == "Требует внимания" ||
            runtimeProvenance.signature == "Невалидна" ||
            runtimeProvenance.architecture == "Неподходящая архитектура"
        {
            return Self(
                status: .attention,
                detail: "Встроенный движок требует проверки перед запуском.",
                nextStep: .runtimeNeedsAttention
            )
        }

        if lifecycle.lastLaunchedAt == nil {
            return Self(
                status: .ready,
                detail: "Профиль готов к первому запуску.",
                nextStep: .none
            )
        }

        return Self(
            status: .ready,
            detail: "Профиль готов; подробности доступны по запросу.",
            nextStep: .none
        )
    }
}
