import Foundation

/// Presentation and action policy for opening a profile from the catalog.
/// Kept independent from the removed Home surface because catalog rows and
/// menu deep-links share the same launch semantics.
struct WorkplaceOpenPresentation: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case launch
        case activate
        case cancel
        case unavailable
    }

    let action: Action
    let title: String
    let detail: String
    let systemImage: String
    var showsInlineDetail = true

    static func resolve(
        state: BrowserProfileProcessState,
        archived: Bool,
        runtime: BrowserRuntimeAvailability,
        preparing: Bool = false,
        testing: Bool = false
    ) -> Self {
        guard !archived else {
            return Self(
                action: .unavailable,
                title: "В архиве",
                detail: "Верни рабочее место из архива",
                systemImage: "archivebox"
            )
        }
        switch state {
        case .managed, .externalVerified, .externalManualOnly:
            return Self(
                action: .activate,
                title: "Продолжить",
                detail: "Перейти в открытый браузер этого рабочего места",
                systemImage: "arrow.up.forward.app"
            )
        default:
            let presentation = BrowserLaunchActionPresentation.resolve(
                processState: state,
                isArchived: archived,
                runtimeAvailability: runtime,
                isProxyTesting: testing,
                isLaunchPreparation: preparing
            )
            return Self(
                action: preparing ? .cancel :
                    (presentation.isEnabled && state == .stopped
                        ? .launch : .unavailable),
                title: preparing ? "Отменить" :
                    (state == .stopped && !testing ? "Открыть" : presentation.title),
                detail: presentation.help,
                systemImage: preparing ? "xmark" :
                    (state == .stopped ? "arrow.up.right" : presentation.systemImage),
                showsInlineDetail: state != .stopped || runtime == .ready
            )
        }
    }
}
