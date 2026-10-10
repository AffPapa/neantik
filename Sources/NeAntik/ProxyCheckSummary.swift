import Foundation

/// A small, privacy-safe projection for showing when a proxy check was run.
/// It deliberately contains no endpoint, address, location, or raw error data.
struct ProxyCheckSummary: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case neverChecked
        case incompleteContext
        case currentSuccess
        case staleSuccess
        case latestCheckFailed
        case clockUncertain
        case configurationChanged
    }

    static let freshnessLifetime: TimeInterval = 15 * 60
    static let toleratedFutureSkew: TimeInterval = 5 * 60

    let status: Status
    let checkedAt: Date?
    let lastSuccessfulCheckAt: Date?

    init(
        record: ProxyHealthRecord?,
        currentIdentity: ProxyHealthIdentity?,
        now: Date = .now
    ) {
        guard let record else {
            self.status = .neverChecked
            self.checkedAt = nil
            self.lastSuccessfulCheckAt = nil
            return
        }
        guard let currentIdentity, record.identity == currentIdentity else {
            self.status = .configurationChanged
            self.checkedAt = nil
            self.lastSuccessfulCheckAt = nil
            return
        }

        let attempt = record.state.latestAttempt
        self.checkedAt = attempt.checkedAt
        self.lastSuccessfulCheckAt = record.state.lastSuccess?.observedAt

        self.status = Self.status(for: record.state, now: now)
    }

    /// UI projections share one clock policy. No network or disk work is performed.
    static func status(for state: ProxyHealthState, now: Date) -> Status {
        let age = now.timeIntervalSince(state.latestAttempt.checkedAt)
        guard age.isFinite, age >= -toleratedFutureSkew else { return .clockUncertain }
        guard state.latestAttempt.outcome == .succeeded else { return .latestCheckFailed }
        guard state.hasCompleteRouteContext else { return .incompleteContext }
        return age <= freshnessLifetime ? .currentSuccess : .staleSuccess
    }

    var title: String {
        switch status {
        case .neverChecked: "Прокси ещё не проверялся"
        case .incompleteContext: "Прокси отвечает; часовой пояс и язык не определены. Повтори проверку перед запуском."
        case .currentSuccess: "Проверка прокси прошла"
        case .staleSuccess: "Проверка прокси устарела"
        case .latestCheckFailed: "Последняя проверка не прошла"
        case .clockUncertain: "Время проверки не подтверждено"
        case .configurationChanged: "Настройки прокси изменились"
        }
    }
}
