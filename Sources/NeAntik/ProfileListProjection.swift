import Foundation

enum ProfileListScope: String, CaseIterable, Identifiable, Sendable {
    case active
    case archived

    var id: Self { self }

    var title: String {
        switch self {
        case .active: "Профили"
        case .archived: "Архив"
        }
    }
}

enum ProfileListProjection {
    static func normalizedSelection(
        _ currentSelection: UUID?,
        in visibleProfiles: [BrowserProfile]
    ) -> UUID? {
        if let currentSelection,
           visibleProfiles.contains(where: { $0.id == currentSelection }) {
            return currentSelection
        }
        return visibleProfiles.first?.id
    }

    static func filtered(
        _ profiles: [BrowserProfile],
        searchText: String,
        tag: String?,
        scope: ProfileListScope = .active
    ) -> [BrowserProfile] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return profiles.filter { profile in
            guard profile.isArchived == (scope == .archived) else {
                return false
            }
            let matchesTag: Bool
            if let tag {
                matchesTag = profile.tags.contains {
                    $0.compare(
                        tag,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
                }
            } else {
                matchesTag = true
            }
            guard matchesTag else { return false }
            guard !query.isEmpty else { return true }
            return ([profile.name] + profile.tags).contains {
                $0.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
    }

    static func allTags(in profiles: [BrowserProfile]) -> [String] {
        var values: [String] = []
        for tag in profiles.flatMap(\.tags) {
            if !values.contains(where: {
                $0.compare(
                    tag,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) {
                values.append(tag)
            }
        }
        return values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    static func areInIncreasingOrder(
        _ lhs: BrowserProfile,
        _ rhs: BrowserProfile
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
