import Foundation

/// A lightweight menu-only view. Unlike Home, it never reads process or proxy
/// state because the menu needs only recent local places.
enum WorkplaceMenuProjection {
    static func recentPlaces(
        profiles: [BrowserProfile],
        limit: Int = 8
    ) -> [BrowserProfile] {
        Array(
            profiles
                .lazy
                .filter { !$0.isArchived }
                .sorted(by: areInMenuOrder)
                .prefix(max(0, limit))
        )
    }

    private static func areInMenuOrder(
        _ lhs: BrowserProfile,
        _ rhs: BrowserProfile
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        let left = lhs.lastLaunchedAt ?? lhs.createdAt
        let right = rhs.lastLaunchedAt ?? rhs.createdAt
        if left != right { return left > right }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
