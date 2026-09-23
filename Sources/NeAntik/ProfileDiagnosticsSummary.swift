import Foundation

enum ProfileDiagnosticsStatus: Equatable, Sendable {
    case ready
    case attention
    case unavailable

    var title: String {
        switch self {
        case .ready:
            "В порядке"
        case .attention:
            "Требует внимания"
        case .unavailable:
            "Проверка недоступна"
        }
    }
}

struct ProfileDiagnosticsSummary: Equatable, Sendable {
    let status: ProfileDiagnosticsStatus
    let detail: String

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
                detail: "Профилю требуется восстановление перед запуском."
            )
        case .unavailable:
            return Self(
                status: .unavailable,
                detail: "Состояние восстановления пока нельзя проверить."
            )
        case .clear:
            break
        }

        switch lifecycle.lock {
        case .active:
            return Self(
                status: .attention,
                detail: "Профиль занят другим процессом или ещё завершается."
            )
        case .unavailable:
            return Self(
                status: .unavailable,
                detail: "Состояние блокировки пока нельзя проверить."
            )
        case .clear:
            break
        }

        switch lifecycle.browserData {
        case .unavailable:
            return Self(
                status: .unavailable,
                detail: "Размер локальных данных пока нельзя проверить."
            )
        case .missing where lifecycle.lastLaunchedAt != nil:
            return Self(
                status: .attention,
                detail: "После предыдущего запуска данные профиля не найдены."
            )
        case .missing, .available:
            break
        }

        if privacyPanel.mediaDevices == .unavailable ||
            privacyPanel.permissionsAPI == .unavailable
        {
            return Self(
                status: .unavailable,
                detail: "Панель приватности пока нельзя полностью проверить."
            )
        }

        if artifactProvenance.downloads == .unavailable ||
            artifactProvenance.extensions == .unavailable ||
            artifactProvenance.quarantine == .unavailable
        {
            return Self(
                status: .unavailable,
                detail: "Состояние файлов профиля пока нельзя проверить."
            )
        }

        if runtimeProvenance.name == "Движок не выбран" ||
            runtimeProvenance.preflight == "Проверка не завершена"
        {
            return Self(
                status: .unavailable,
                detail: "Встроенный движок ещё не прошёл проверку запуска."
            )
        }

        if runtimeProvenance.publicReleaseStatus == "Не определён" {
            return Self(
                status: .unavailable,
                detail: "Статус версии встроенного движка пока нельзя проверить."
            )
        }

        if runtimeProvenance.architecture == "Не проверена" ||
            runtimeProvenance.signature == "Не проверена" ||
            runtimeProvenance.executableDigest == "Не измерен" ||
            runtimeProvenance.frameworkDigest == "Не измерен"
        {
            return Self(
                status: .unavailable,
                detail: "Происхождение встроенного движка проверено не полностью."
            )
        }

        if runtimeProvenance.publicReleaseStatus.contains("заблокирован") {
            return Self(
                status: .attention,
                detail: "Версия встроенного движка ниже принятого Direct baseline."
            )
        }

        if runtimeProvenance.preflight == "Требует внимания" ||
            runtimeProvenance.signature == "Невалидна" ||
            runtimeProvenance.architecture == "Неподходящая архитектура"
        {
            return Self(
                status: .attention,
                detail: "Встроенный движок требует проверки перед запуском."
            )
        }

        if lifecycle.lastLaunchedAt == nil {
            return Self(
                status: .ready,
                detail: "Профиль готов к первому запуску."
            )
        }

        return Self(
            status: .ready,
            detail: "Профиль готов; подробности доступны по запросу."
        )
    }
}
