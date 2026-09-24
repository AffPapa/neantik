import Foundation

/// A small, privacy-safe projection for showing when a proxy check was run.
/// It deliberately contains no endpoint, address, location, or raw error data.
struct ProxyCheckSummary: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case neverChecked
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

        let age = now.timeIntervalSince(attempt.checkedAt)
        guard age >= -Self.toleratedFutureSkew else {
            self.status = .clockUncertain
            return
        }
        guard attempt.outcome == .succeeded else {
            self.status = .latestCheckFailed
            return
        }
        self.status = age <= Self.freshnessLifetime
            ? .currentSuccess
            : .staleSuccess
    }

    var title: String {
        switch status {
        case .neverChecked: "Прокси ещё не проверялся"
        case .currentSuccess: "Проверка прокси прошла"
        case .staleSuccess: "Проверка прокси устарела"
        case .latestCheckFailed: "Последняя проверка не прошла"
        case .clockUncertain: "Время проверки не подтверждено"
        case .configurationChanged: "Настройки прокси изменились"
        }
    }
}
