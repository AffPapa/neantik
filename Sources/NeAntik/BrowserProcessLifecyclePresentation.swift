import Foundation

enum BrowserProcessOrigin: Equatable, Sendable {
    case currentManager
    case recoveredManager
    case manual
    case uncertain

    var title: String {
        switch self {
        case .currentManager: "Этот NeAntik"
        case .recoveredManager: "Восстановлен"
        case .manual: "Запущен вручную"
        case .uncertain: "Требует проверки"
        }
    }
}

struct BrowserProcessLifecycleItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileName: String
    let stateTitle: String
    let detail: String
    let systemImage: String
    let origin: BrowserProcessOrigin
    let canFocus: Bool
    let canStop: Bool
    let canForceStop: Bool
}

struct BrowserProcessStopAllPresentation: Equatable, Sendable {
    let eligibleProfileIDs: [UUID]
    let excludedCount: Int

    var eligibleCount: Int { eligibleProfileIDs.count }
    var shouldOfferAction: Bool { eligibleCount > 1 }

    var confirmationMessage: String {
        var message =
            "NeAntik отправит обычную команду завершения " +
            "\(eligibleCount) профилям. Принудительная остановка не используется."
        if excludedCount > 0 {
            message +=
                " Ещё \(excludedCount) профилей уже завершились, завершаются или требуют отдельного действия."
        }
        return message
    }

    static func resolve(
        items: [BrowserProcessLifecycleItem]
    ) -> Self {
        let eligible = items.filter(\.canStop).map(\.id)
        return Self(
            eligibleProfileIDs: eligible,
            excludedCount: items.count - eligible.count
        )
    }
}

enum BrowserProcessLifecycleProjection {
    static func requiresPeriodicRefresh(
        for items: [BrowserProcessLifecycleItem]
    ) -> Bool {
        !items.isEmpty
    }

    static func resolve(
        profiles: [BrowserProfile],
        processState: (UUID) -> BrowserProfileProcessState,
        stopPhase: (UUID) -> BrowserStopPhase,
        startedAt: (UUID) -> Date?,
        now: Date
    ) -> [BrowserProcessLifecycleItem] {
        profiles.compactMap { profile in
            let state = processState(profile.id)
            let phase = stopPhase(profile.id)
            guard state.isConfirmedRunning || isRecentCompletion(phase) else {
                return nil
            }
            let origin = origin(for: state)
            let elapsed = startedAt(profile.id).map {
                elapsedTitle(from: $0, to: now)
            }
            let detail: String
            let systemImage: String
            switch phase {
            case .closing:
                detail = "Завершаем Chromium без потери сессии"
                systemImage = "hourglass"
            case .forceStopAvailable:
                detail = "Не ответил на обычную остановку"
                systemImage = "exclamationmark.octagon.fill"
            case let .completed(_, wasForced):
                detail = wasForced
                    ? "Принудительно остановлен; проверь сессию при следующем запуске"
                    : "Процесс завершён, профиль безопасно разблокирован"
                systemImage = wasForced
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill"
            case .idle:
                detail = ([origin.title] + [elapsed].compactMap { $0 })
                    .joined(separator: " · ")
                systemImage = state.statusTone == .attention
                    ? "exclamationmark.triangle.fill"
                    : "circle.fill"
            }
            let isCompleted: Bool
            if case .completed = phase {
                isCompleted = true
            } else {
                isCompleted = false
            }
            return BrowserProcessLifecycleItem(
                id: profile.id,
                profileName: profile.name,
                stateTitle: state.title,
                detail: detail,
                systemImage: systemImage,
                origin: origin,
                canFocus: state.isConfirmedRunning && !isCompleted,
                canStop: state.canRequestStop && phase == .idle,
                canForceStop: state == .forceStopAvailable
            )
        }
    }

    static func elapsedTitle(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) с" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) мин" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours) ч"
            : "\(hours) ч \(remainingMinutes) мин"
    }

    private static func isRecentCompletion(
        _ phase: BrowserStopPhase
    ) -> Bool {
        if case .completed = phase { return true }
        return false
    }

    private static func origin(
        for state: BrowserProfileProcessState
    ) -> BrowserProcessOrigin {
        switch state {
        case .managed, .closing, .forceStopAvailable:
            .currentManager
        case .externalVerified:
            .recoveredManager
        case .externalManualOnly:
            .manual
        case .externalUnverified, .recoveryRequired, .checking:
            .uncertain
        case .stopped:
            .currentManager
        }
    }
}
