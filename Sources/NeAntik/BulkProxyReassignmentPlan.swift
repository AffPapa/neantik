import Foundation

/// Read-only, credential-safe preview for a future bulk proxy reassignment.
/// This type deliberately has no apply or persistence operation. Existing
/// profiles need a crash-recoverable Keychain transaction before writes are
/// safe to expose.
struct BulkProxyReassignmentPlan: Equatable, Sendable {
    enum Issue: Equatable, Sendable {
        case duplicateSelectedProfile
        case missingTarget
        case duplicateTarget
        case invalidTarget
    }

    struct Target: Equatable, Sendable {
        let profileID: UUID
        let proxy: ProxyConfiguration
    }

    struct ProxySummary: Equatable, Sendable {
        let kind: ProxyKind
        let endpoint: String
        let requiresAuthentication: Bool

        init(_ proxy: ProxyConfiguration) {
            kind = proxy.kind
            // Never render an invalid host: persisted or synthetic invalid
            // values can contain URI userinfo even though they are rejected.
            endpoint = proxy.isValid ? proxy.displayEndpoint : "некорректный адрес"
            requiresAuthentication = !proxy.username.isEmpty
        }

        var displayText: String {
            "\(kind.title) · \(endpoint) · " +
                (requiresAuthentication ? "с авторизацией" : "без авторизации")
        }
    }

    struct Row: Equatable, Sendable {
        let profileID: UUID
        let expectedRevision: UInt64
        let currentProxy: ProxySummary?
        let targetProxy: ProxySummary?
        let issues: [Issue]

        var isPreviewable: Bool { issues.isEmpty && targetProxy != nil }
    }

    let rows: [Row]
    let unselectedTargetProfileIDs: [UUID]

    var isComplete: Bool {
        !rows.isEmpty &&
            unselectedTargetProfileIDs.isEmpty &&
            rows.allSatisfy(\.isPreviewable)
    }

    static func resolve(
        selectedProfiles: [BrowserProfile],
        targets: [Target]
    ) -> Self {
        var targetsByProfile: [UUID: [ProxyConfiguration]] = [:]
        for target in targets {
            targetsByProfile[target.profileID, default: []].append(target.proxy)
        }

        let selectedIDs = Set(selectedProfiles.map(\.id))
        let unselectedTargets = Set(targetsByProfile.keys)
            .subtracting(selectedIDs)
            .sorted { $0.uuidString < $1.uuidString }

        var seen = Set<UUID>()
        let rows = selectedProfiles.map { profile -> Row in
            let isDuplicateSelection = !seen.insert(profile.id).inserted
            let proposed = targetsByProfile[profile.id] ?? []
            var issues: [Issue] = []
            if isDuplicateSelection { issues.append(.duplicateSelectedProfile) }
            if proposed.isEmpty {
                issues.append(.missingTarget)
            } else if proposed.count > 1 {
                issues.append(.duplicateTarget)
            }
            if proposed.first.map({ !$0.isValid }) == true {
                issues.append(.invalidTarget)
            }
            let target = proposed.count == 1 ? proposed[0] : nil
            return Row(
                profileID: profile.id,
                expectedRevision: profile.revision,
                currentProxy: profile.proxy.map(ProxySummary.init),
                targetProxy: target.map(ProxySummary.init),
                issues: issues
            )
        }

        return Self(rows: rows, unselectedTargetProfileIDs: unselectedTargets)
    }
}
