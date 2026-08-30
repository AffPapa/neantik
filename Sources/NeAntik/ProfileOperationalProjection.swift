import Foundation

/// Transient, local-only views over the currently visible profile list.
///
/// These filters never become profile metadata. They are derived from the
/// process manager and the already persisted, credential-free proxy outcome,
/// so choosing a view cannot perform network, Keychain or filesystem work.
enum ProfileOperationalFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case running
    case attention
    case neverLaunched

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            "Все"
        case .running:
            "Запущены"
        case .attention:
            "Внимание"
        case .neverLaunched:
            "Без запусков"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "rectangle.stack"
        case .running:
            "play.circle.fill"
        case .attention:
            "exclamationmark.triangle.fill"
        case .neverLaunched:
            "sparkles"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all:
            "Ничего не найдено"
        case .running:
            "Нет запущенных профилей"
        case .attention:
            "Профили не требуют внимания"
        case .neverLaunched:
            "Все профили уже запускались"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all:
            "Измени поиск или фильтры."
        case .running:
            "Запусти профиль — он появится в этом представлении."
        case .attention:
            "Нет ошибок последней проверки прокси или состояний восстановления."
        case .neverLaunched:
            "Здесь показываются профили без истории запуска."
        }
    }
}

enum ProfileRowDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    var id: Self { self }

    var title: String {
        switch self {
        case .comfortable:
            "Удобно"
        case .compact:
            "Компактно"
        }
    }

    var systemImage: String {
        switch self {
        case .comfortable:
            "rectangle.grid.1x2"
        case .compact:
            "list.bullet"
        }
    }
}

struct ProfileOperationalSummary: Equatable, Sendable {
    let allCount: Int
    let runningCount: Int
    let attentionCount: Int
    let neverLaunchedCount: Int

    func count(for filter: ProfileOperationalFilter) -> Int {
        switch filter {
        case .all:
            allCount
        case .running:
            runningCount
        case .attention:
            attentionCount
        case .neverLaunched:
            neverLaunchedCount
        }
    }
}

struct ProfileOperationalProjection: Equatable, Sendable {
    let allProfiles: [BrowserProfile]
    let runningProfileIDs: Set<UUID>
    let attentionProfileIDs: Set<UUID>
    let neverLaunchedProfileIDs: Set<UUID>
    let summary: ProfileOperationalSummary

    static func resolve(
        profiles: [BrowserProfile],
        processState: (UUID) -> BrowserProfileProcessState,
        proxyHealth: (BrowserProfile) -> ProxyHealthState?
    ) -> Self {
        var runningProfileIDs = Set<UUID>()
        var attentionProfileIDs = Set<UUID>()
        var neverLaunchedProfileIDs = Set<UUID>()

        for profile in profiles {
            let state = processState(profile.id)
            let proxyNeedsAttention = proxyHealth(profile).map {
                !$0.hasCompleteRouteContext
            } ?? false
            if state.isConfirmedRunning {
                runningProfileIDs.insert(profile.id)
            }
            if state.statusTone == .attention || proxyNeedsAttention {
                attentionProfileIDs.insert(profile.id)
            }
            if profile.lastLaunchedAt == nil {
                neverLaunchedProfileIDs.insert(profile.id)
            }
        }

        return Self(
            allProfiles: profiles,
            runningProfileIDs: runningProfileIDs,
            attentionProfileIDs: attentionProfileIDs,
            neverLaunchedProfileIDs: neverLaunchedProfileIDs,
            summary: ProfileOperationalSummary(
                allCount: profiles.count,
                runningCount: runningProfileIDs.count,
                attentionCount: attentionProfileIDs.count,
                neverLaunchedCount: neverLaunchedProfileIDs.count
            )
        )
    }

    func profiles(for filter: ProfileOperationalFilter) -> [BrowserProfile] {
        switch filter {
        case .all:
            allProfiles
        case .running:
            allProfiles.filter { runningProfileIDs.contains($0.id) }
        case .attention:
            allProfiles.filter { attentionProfileIDs.contains($0.id) }
        case .neverLaunched:
            allProfiles.filter { neverLaunchedProfileIDs.contains($0.id) }
        }
    }
}
