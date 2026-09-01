import Foundation

/// Stable, local-only ordering for the profile library.
///
/// Every order keeps explicitly pinned profiles first. The remaining keys are
/// total and deterministic so changing the visible order never mutates profile
/// metadata or depends on the input array's incidental order.
enum ProfileListOrdering: String, CaseIterable, Identifiable, Sendable {
    case pinnedThenName
    case recentLaunch
    case recentlyModified
    case newest

    var id: Self { self }

    var title: String {
        switch self {
        case .pinnedThenName:
            "Закреплённые и название"
        case .recentLaunch:
            "Недавно запускались"
        case .recentlyModified:
            "Недавно изменённые"
        case .newest:
            "Сначала новые"
        }
    }

    func areInIncreasingOrder(
        _ lhs: BrowserProfile,
        _ rhs: BrowserProfile
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }

        switch self {
        case .pinnedThenName:
            return Self.nameCreationAndIDOrder(lhs, rhs)

        case .recentLaunch:
            switch (lhs.lastLaunchedAt, rhs.lastLaunchedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return Self.nameCreationAndIDOrder(lhs, rhs)
            }

        case .recentlyModified:
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return Self.nameCreationAndIDOrder(lhs, rhs)

        case .newest:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return Self.nameAndIDOrder(lhs, rhs)
        }
    }

    private static func nameCreationAndIDOrder(
        _ lhs: BrowserProfile,
        _ rhs: BrowserProfile
    ) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func nameAndIDOrder(
        _ lhs: BrowserProfile,
        _ rhs: BrowserProfile
    ) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// A metadata-only route facet. Resolving it never probes a proxy or reads a
/// credential from Keychain.
enum ProfileRouteFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case withProxy
    case withoutProxy

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            "Все подключения"
        case .withProxy:
            "С прокси"
        case .withoutProxy:
            "Без прокси"
        }
    }

    func includes(_ profile: BrowserProfile) -> Bool {
        switch self {
        case .all:
            true
        case .withProxy:
            profile.proxy != nil
        case .withoutProxy:
            profile.proxy == nil
        }
    }
}

/// Searchable route values deliberately contain only the proxy type and public
/// endpoint. The username and Keychain-backed password never enter the search
/// index.
enum ProfileRouteSearchDocument {
    static func values(for profile: BrowserProfile) -> [String] {
        guard let proxy = profile.proxy else { return [] }
        return [proxy.kind.title, proxy.displayEndpoint]
    }
}
