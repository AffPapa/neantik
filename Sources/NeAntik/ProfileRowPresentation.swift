import Foundation

/// A compact, text-first projection for the daily profile list.
///
/// Status and route remain readable without relying on color, while the note
/// is normalized to one line before SwiftUI truncates it to the available
/// width. No credential or runtime detail is introduced here.
struct ProfileRowPresentation: Equatable, Sendable {
    static let maximumNoteSummaryLength = 120

    let statusTitle: String
    let statusSystemImage: String
    let statusTone: BrowserProcessStatusTone
    let routeTitle: String
    let noteSummary: String

    var statusAccessibilityLabel: String {
        "Статус: \(statusTitle)"
    }

    var routeAccessibilityLabel: String {
        "Подключение: \(routeTitle)"
    }

    static func profileAccessibilityLabel(_ profile: BrowserProfile) -> String {
        "Профиль: \(profile.name)"
    }

    static func resolve(
        profile: BrowserProfile,
        processState: BrowserProfileProcessState
    ) -> Self {
        let status: (String, String, BrowserProcessStatusTone)
        if profile.isArchived {
            status = ("В архиве", "archivebox", .neutral)
        } else {
            status = (
                processState.title,
                statusSystemImage(for: processState.statusTone),
                processState.statusTone
            )
        }
        return Self(
            statusTitle: status.0,
            statusSystemImage: status.1,
            statusTone: status.2,
            routeTitle: profile.proxy?.displayName ?? "Без прокси",
            noteSummary: compactNoteSummary(profile.note)
        )
    }

    private static func compactNoteSummary(_ note: String) -> String {
        let summary = ProfileNotePresentation.resolve(note).collapsedSummary
        guard summary.count > maximumNoteSummaryLength else {
            return summary
        }
        return String(summary.prefix(maximumNoteSummaryLength))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func compactLaunchTitle(_ title: String) -> String {
        switch title {
        case "Запустить":
            return "Старт"
        case "Остановить":
            return "Стоп"
        case "Отменить подготовку":
            return "Отмена"
        case "Закрыть вручную":
            return "Закрыть"
        case "В архиве":
            return "Архив"
        default:
            return title
        }
    }

    private static func statusSystemImage(
        for tone: BrowserProcessStatusTone
    ) -> String {
        switch tone {
        case .neutral:
            "circle"
        case .activity:
            "clock.arrow.circlepath"
        case .healthy:
            "circle.fill"
        case .attention:
            "exclamationmark.triangle.fill"
        }
    }
}
