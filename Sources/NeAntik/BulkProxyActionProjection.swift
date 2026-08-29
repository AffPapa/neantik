import Foundation

/// One immutable target snapshot for the bulk proxy-check presentation and
/// operation. Labels, accessibility text, progress totals, and the task itself
/// must all consume this same projection.
struct BulkProxyActionProjection: Equatable, Sendable {
    let profiles: [BrowserProfile]

    var profileIDs: [UUID] {
        profiles.map(\.id)
    }

    var count: Int {
        profiles.count
    }

    var isVisible: Bool {
        !profiles.isEmpty
    }

    static func resolve(
        visibleProfiles: [BrowserProfile],
        processState: (UUID) -> BrowserProfileProcessState,
        isPreparing: (UUID) -> Bool,
        isTesting: (UUID) -> Bool
    ) -> Self {
        Self(
            profiles: visibleProfiles.filter { profile in
                profile.proxy != nil &&
                    processState(profile.id) == .stopped &&
                    !isPreparing(profile.id) &&
                    !isTesting(profile.id)
            }
        )
    }
}
