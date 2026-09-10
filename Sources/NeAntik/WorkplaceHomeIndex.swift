import Foundation

struct WorkplaceHomeIndex: Equatable, Sendable {
    let orderedActiveProfiles: [BrowserProfile]
    let unfiledProfileIDs: Set<UUID>
    let untaggedProfileIDs: Set<UUID>

    init(
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState
    ) {
        let activeProfiles = profiles.filter { !$0.isArchived }
        orderedActiveProfiles = activeProfiles.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            let left = lhs.lastLaunchedAt ?? lhs.createdAt
            let right = rhs.lastLaunchedAt ?? rhs.createdAt
            if left != right { return left > right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        unfiledProfileIDs = Set(activeProfiles.compactMap { profile in
            organization.folder(withID: organization.folderID(forProfileID: profile.id)) == nil
                ? profile.id
                : nil
        })
        untaggedProfileIDs = Set(activeProfiles.compactMap { profile in
            profile.tags.isEmpty ? profile.id : nil
        })
    }

    func resolve(
        search: String,
        operational: ProfileOperationalProjection,
        limit: Int = 24,
        revealProfileID: UUID? = nil
    ) -> WorkplaceHomeProjection {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = orderedActiveProfiles.filter { profile in
            query.isEmpty || ([profile.name, profile.note] + profile.tags).contains {
                $0.localizedStandardContains(query)
            }
        }
        let summary = WorkplaceHomeSummary(
            activeCount: orderedActiveProfiles.count,
            runningCount: operational.runningProfileIDs.count,
            attentionCount: operational.attentionProfileIDs.count,
            unfiledCount: unfiledProfileIDs.count,
            untaggedCount: untaggedProfileIDs.count
        )
        var quickMatches: [WorkplaceHomeQuickFilter: [BrowserProfile]] = Dictionary(
            uniqueKeysWithValues: WorkplaceHomeQuickFilter.allCases.map { ($0, []) }
        )
        for profile in matches {
            quickMatches[.all, default: []].append(profile)
            if operational.runningProfileIDs.contains(profile.id) {
                quickMatches[.running, default: []].append(profile)
            }
            if operational.attentionProfileIDs.contains(profile.id) {
                quickMatches[.attention, default: []].append(profile)
            }
            if unfiledProfileIDs.contains(profile.id) {
                quickMatches[.unfiled, default: []].append(profile)
            }
            if untaggedProfileIDs.contains(profile.id) {
                quickMatches[.untagged, default: []].append(profile)
            }
        }
        return WorkplaceHomeProjection(
            profiles: WorkplaceHomeProjection.visibleProfiles(
                matches: matches, limit: limit, revealProfileID: revealProfileID
            ),
            matchCount: matches.count,
            summary: summary,
            matchesByQuickFilter: quickMatches
        )
    }
}

@MainActor
final class WorkplaceHomeStateResolver {
    private var profileRevision: UInt64?
    private var index: WorkplaceHomeIndex?
    private var processRevision: UInt64?
    private var healthRecords: [UUID: ProxyHealthRecord]?
    private var operational: ProfileOperationalProjection?

    func resolve(
        profileRevision requestedProfileRevision: UInt64,
        processRevision requestedProcessRevision: UInt64,
        healthRecords requestedHealthRecords: [UUID: ProxyHealthRecord],
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState,
        search: String,
        revealProfileID: UUID?,
        processState: (UUID) -> BrowserProfileProcessState,
        proxyHealth: (BrowserProfile) -> ProxyHealthState?
    ) -> WorkplaceHomeProjection {
        let currentIndex: WorkplaceHomeIndex
        if profileRevision == requestedProfileRevision, let index {
            currentIndex = index
        } else {
            let resolved = WorkplaceHomeIndex(
                profiles: profiles,
                organization: organization
            )
            profileRevision = requestedProfileRevision
            index = resolved
            processRevision = nil
            healthRecords = nil
            operational = nil
            currentIndex = resolved
        }
        let currentOperational: ProfileOperationalProjection
        if processRevision == requestedProcessRevision,
           healthRecords == requestedHealthRecords,
           let operational
        {
            currentOperational = operational
        } else {
            let resolved = ProfileOperationalProjection.resolve(
                profiles: currentIndex.orderedActiveProfiles,
                processState: processState,
                proxyHealth: proxyHealth
            )
            processRevision = requestedProcessRevision
            healthRecords = requestedHealthRecords
            operational = resolved
            currentOperational = resolved
        }
        return currentIndex.resolve(
            search: search,
            operational: currentOperational,
            revealProfileID: revealProfileID
        )
    }
}
