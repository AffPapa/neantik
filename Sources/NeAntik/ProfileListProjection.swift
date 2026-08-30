import Foundation

enum ProfileListScope: String, CaseIterable, Identifiable, Sendable {
    case active
    case pinned
    case archived

    var id: Self { self }

    var title: String {
        switch self {
        case .active: "Профили"
        case .pinned: "Закреплённые"
        case .archived: "Архив"
        }
    }
}

enum ProfileFolderFilter: Hashable, Sendable {
    case all
    case unfiled
    case folder(UUID)
}

/// Stable tag identity independent from the spelling shown in the sidebar.
///
/// `Café`, `cafe`, and `CAFÉ` deliberately produce the same identifier. The
/// display label can therefore follow the current deterministic representative
/// without invalidating a selection held by the UI.
struct ProfileTagID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = Self.folded(rawValue)
    }

    init(displayName: String) {
        self.init(rawValue: displayName)
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).precomposedStringWithCanonicalMapping
    }
}

struct ProfileTagSummary: Identifiable, Equatable, Sendable {
    let id: ProfileTagID
    let name: String
    let count: Int

    init(name: String, count: Int) {
        self.init(
            id: ProfileTagID(displayName: name),
            name: name,
            count: count
        )
    }

    init(id: ProfileTagID, name: String, count: Int) {
        self.id = id
        self.name = name
        self.count = count
    }
}

struct ProfileListPreview<Element: Equatable & Sendable>:
    Equatable,
    Sendable
{
    let visibleItems: [Element]
    let hiddenCount: Int

    var hasHiddenItems: Bool {
        hiddenCount > 0
    }
}

/// One linear index for the workspace source column.
///
/// It keeps folder lookups and folder-aware tag counts out of SwiftUI row
/// builders, where repeated filtering otherwise grows with folders × profiles.
struct ProfileListIndex: Equatable, Sendable {
    private struct IndexedProfile: Equatable, Sendable {
        let profile: BrowserProfile
        let folderID: UUID?
        let profileSearchText: String
        let folderSearchText: String?
    }

    private struct TagAccumulatorKey: Hashable {
        let scope: ProfileListScope
        let folderFilter: ProfileFolderFilter
        let tagID: ProfileTagID
    }

    private struct TagAccumulator {
        let id: ProfileTagID
        let displayName: String
        var count: Int
    }

    let activeCount: Int
    let pinnedCount: Int
    let archivedCount: Int
    let unfiledCount: Int
    let activeCountByFolderID: [UUID: Int]
    let folderNameByID: [UUID: String]
    private let indexedProfiles: [IndexedProfile]
    private let orderedProfileIndicesByOrdering:
        [ProfileListOrdering: [Int]]
    private let displayNameByTagID: [ProfileTagID: String]
    private let countsByScope:
        [ProfileListScope: [ProfileFolderFilter: Int]]

    private let tagSummariesByScope:
        [ProfileListScope: [ProfileFolderFilter: [ProfileTagSummary]]]

    init(
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState
    ) {
        var activeCount = 0
        var pinnedCount = 0
        var archivedCount = 0
        var unfiledCount = 0
        var activeCountByFolderID: [UUID: Int] = [:]
        var countsByScope:
            [ProfileListScope: [ProfileFolderFilter: Int]] = [:]
        var tagAccumulators: [TagAccumulatorKey: TagAccumulator] = [:]
        var indexedProfiles: [IndexedProfile] = []
        var displayNameByTagID: [ProfileTagID: String] = [:]

        let resolvedFolderNameByID = Dictionary(
            uniqueKeysWithValues: organization.folders.map {
                ($0.id, $0.name)
            }
        )
        folderNameByID = resolvedFolderNameByID

        for profile in profiles {
            let assignedFolderID = organization.folderID(
                forProfileID: profile.id
            )
            let folderFilter: ProfileFolderFilter
            if let assignedFolderID,
               resolvedFolderNameByID[assignedFolderID] != nil {
                folderFilter = .folder(assignedFolderID)
            } else {
                folderFilter = .unfiled
            }

            let scopes: [ProfileListScope]
            if profile.isArchived {
                archivedCount += 1
                scopes = [.archived]
            } else {
                activeCount += 1
                if case let .folder(folderID) = folderFilter {
                    activeCountByFolderID[folderID, default: 0] += 1
                } else {
                    unfiledCount += 1
                }
                if profile.isPinned {
                    pinnedCount += 1
                    scopes = [.active, .pinned]
                } else {
                    scopes = [.active]
                }
            }

            var profileDisplayNameByTagID: [ProfileTagID: String] = [:]
            for tag in profile.tags {
                let tagID = ProfileTagID(displayName: tag)
                if displayNameByTagID[tagID] == nil {
                    displayNameByTagID[tagID] = tag
                }
                if profileDisplayNameByTagID[tagID] == nil {
                    profileDisplayNameByTagID[tagID] = tag
                }
            }
            indexedProfiles.append(
                IndexedProfile(
                    profile: profile,
                    folderID: folderFilter.folderID,
                    profileSearchText: ProfileSearchText.document(
                        profileValues: [profile.name] + profile.tags + [
                            profile.note
                        ] + ProfileRouteSearchDocument.values(for: profile)
                    ),
                    folderSearchText: folderFilter.folderID.flatMap {
                        resolvedFolderNameByID[$0]
                    }.map(ProfileSearchText.fold)
                )
            )
            for scope in scopes {
                for filter in [ProfileFolderFilter.all, folderFilter] {
                    countsByScope[scope, default: [:]][filter, default: 0] += 1
                    for (tagID, displayName) in profileDisplayNameByTagID {
                        let key = TagAccumulatorKey(
                            scope: scope,
                            folderFilter: filter,
                            tagID: tagID
                        )
                        if var current = tagAccumulators[key] {
                            current.count += 1
                            tagAccumulators[key] = current
                        } else {
                            tagAccumulators[key] = TagAccumulator(
                                id: tagID,
                                displayName: displayName,
                                count: 1
                            )
                        }
                    }
                }
            }
        }

        self.activeCount = activeCount
        self.pinnedCount = pinnedCount
        self.archivedCount = archivedCount
        self.unfiledCount = unfiledCount
        self.activeCountByFolderID = activeCountByFolderID
        self.indexedProfiles = indexedProfiles
        let unorderedIndices = Array(indexedProfiles.indices)
        orderedProfileIndicesByOrdering = Dictionary(
            uniqueKeysWithValues: ProfileListOrdering.allCases.map { ordering in
                (
                    ordering,
                    unorderedIndices.sorted { lhs, rhs in
                        ordering.areInIncreasingOrder(
                            indexedProfiles[lhs].profile,
                            indexedProfiles[rhs].profile
                        )
                    }
                )
            }
        )
        self.displayNameByTagID = displayNameByTagID
        self.countsByScope = countsByScope
        var summariesByScope:
            [ProfileListScope: [ProfileFolderFilter: [ProfileTagSummary]]] = [:]
        for (key, accumulator) in tagAccumulators {
            summariesByScope[key.scope, default: [:]][
                key.folderFilter,
                default: []
            ].append(
                ProfileTagSummary(
                    id: accumulator.id,
                    name: accumulator.displayName,
                    count: accumulator.count
                )
            )
        }
        tagSummariesByScope = summariesByScope.mapValues { summariesByFilter in
            summariesByFilter.mapValues { summaries in
                summaries.sorted(by: Self.tagSummaryIsInIncreasingOrder)
            }
        }
    }

    func activeCount(in folderFilter: ProfileFolderFilter) -> Int {
        switch folderFilter {
        case .all:
            activeCount
        case .unfiled:
            unfiledCount
        case let .folder(folderID):
            activeCountByFolderID[folderID, default: 0]
        }
    }

    func count(
        scope: ProfileListScope,
        in folderFilter: ProfileFolderFilter,
        tagID: ProfileTagID? = nil
    ) -> Int {
        if let tagID {
            return tagSummaries(
                scope: scope,
                in: folderFilter
            ).first(where: { $0.id == tagID })?.count ?? 0
        }
        return countsByScope[scope]?[folderFilter] ?? 0
    }

    func tagSummaries(
        in folderFilter: ProfileFolderFilter
    ) -> [ProfileTagSummary] {
        tagSummaries(scope: .active, in: folderFilter)
    }

    func tagSummaries(
        scope: ProfileListScope,
        in folderFilter: ProfileFolderFilter
    ) -> [ProfileTagSummary] {
        tagSummariesByScope[scope]?[folderFilter] ?? []
    }

    func displayName(for tagID: ProfileTagID) -> String? {
        displayNameByTagID[tagID]
    }

    func filtered(
        searchText: String,
        tag: String?,
        scope: ProfileListScope,
        folderFilter: ProfileFolderFilter,
        routeFilter: ProfileRouteFilter = .all,
        ordering: ProfileListOrdering = .pinnedThenName
    ) -> [BrowserProfile] {
        let searchQuery = ProfileSearchText.query(searchText)
        let orderedIndices = orderedProfileIndicesByOrdering[ordering] ??
            Array(indexedProfiles.indices)
        return orderedIndices.compactMap { index in
            let entry = indexedProfiles[index]
            switch scope {
            case .active:
                guard !entry.profile.isArchived else { return nil }
            case .pinned:
                guard !entry.profile.isArchived, entry.profile.isPinned else {
                    return nil
                }
            case .archived:
                guard entry.profile.isArchived else { return nil }
            }
            switch folderFilter {
            case .all:
                break
            case .unfiled:
                guard entry.folderID == nil else { return nil }
            case let .folder(requiredFolderID):
                guard entry.folderID == requiredFolderID else { return nil }
            }
            guard routeFilter.includes(entry.profile) else { return nil }
            if let tag, !entry.profile.tags.contains(where: {
                $0.compare(
                    tag,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) {
                return nil
            }
            guard !searchQuery.isEmpty else { return entry.profile }
            if entry.profileSearchText.contains(searchQuery) {
                return entry.profile
            }
            if case .all = folderFilter,
               entry.folderSearchText?.contains(searchQuery) == true {
                return entry.profile
            }
            return nil
        }
    }

    private static func tagSummaryIsInIncreasingOrder(
        _ lhs: ProfileTagSummary,
        _ rhs: ProfileTagSummary
    ) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.id != rhs.id {
            return lhs.id.rawValue < rhs.id.rawValue
        }
        return lhs.name < rhs.name
    }
}

private extension ProfileFolderFilter {
    var folderID: UUID? {
        guard case let .folder(id) = self else { return nil }
        return id
    }
}

enum ProfileListProjection {
    static let defaultPreviewLimit = 8

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
        scope: ProfileListScope = .active,
        folderFilter: ProfileFolderFilter = .all,
        organization: ProfileOrganizationState = .empty,
        routeFilter: ProfileRouteFilter = .all,
        ordering: ProfileListOrdering = .pinnedThenName
    ) -> [BrowserProfile] {
        let query = ProfileSearchText.query(searchText)
        let folderNameByID = Dictionary(
            uniqueKeysWithValues: organization.folders.map {
                ($0.id, $0.name)
            }
        )
        return profiles.filter { profile in
            switch scope {
            case .active:
                guard !profile.isArchived else { return false }
            case .pinned:
                guard !profile.isArchived, profile.isPinned else {
                    return false
                }
            case .archived:
                guard profile.isArchived else { return false }
            }
            let assignedFolderID = organization.folderID(
                forProfileID: profile.id
            )
            let folderID = assignedFolderID.flatMap {
                folderNameByID[$0] == nil ? nil : $0
            }
            switch folderFilter {
            case .all:
                break
            case .unfiled:
                guard folderID == nil else { return false }
            case let .folder(requiredFolderID):
                guard folderID == requiredFolderID else { return false }
            }
            guard routeFilter.includes(profile) else { return false }
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
            if ProfileSearchText.document(
                profileValues: [profile.name] + profile.tags + [profile.note] +
                    ProfileRouteSearchDocument.values(for: profile)
            ).contains(query) {
                return true
            }
            if case .all = folderFilter,
               let folderID,
               let folderName = folderNameByID[folderID] {
                return ProfileSearchText.fold(folderName).contains(query)
            }
            return false
        }.sorted(by: ordering.areInIncreasingOrder)
    }

    static func count(
        _ profiles: [BrowserProfile],
        scope: ProfileListScope,
        folderFilter: ProfileFolderFilter,
        organization: ProfileOrganizationState
    ) -> Int {
        filtered(
            profiles,
            searchText: "",
            tag: nil,
            scope: scope,
            folderFilter: folderFilter,
            organization: organization
        ).count
    }

    static func allTags(in profiles: [BrowserProfile]) -> [String] {
        var firstValueByID: [ProfileTagID: String] = [:]
        for tag in profiles.flatMap(\.tags) {
            let id = ProfileTagID(displayName: tag)
            if firstValueByID[id] == nil {
                firstValueByID[id] = tag
            }
        }
        return firstValueByID.values.sorted(by: tagNameIsInIncreasingOrder)
    }

    static func folderPreview(
        _ folders: [ProfileFolder],
        selectedID: UUID?,
        limit: Int = defaultPreviewLimit
    ) -> ProfileListPreview<ProfileFolder> {
        let orderedFolders = orderedPreviewSource(
            folders,
            by: ProfileFolder.areInIncreasingOrder
        )
        return limitedPreview(
            orderedFolders,
            selectedID: selectedID,
            limit: limit,
            id: \.id,
            areInIncreasingOrder: ProfileFolder.areInIncreasingOrder
        )
    }

    static func tagPreview(
        _ tags: [ProfileTagSummary],
        selectedID: ProfileTagID?,
        limit: Int = defaultPreviewLimit
    ) -> ProfileListPreview<ProfileTagSummary> {
        let orderedTags = orderedPreviewSource(
            tags,
            by: tagSummaryIsInIncreasingOrder
        )
        return limitedPreview(
            orderedTags,
            selectedID: selectedID,
            limit: limit,
            id: \.id,
            areInIncreasingOrder: tagSummaryIsInIncreasingOrder
        )
    }

    private static func limitedPreview<Element, ID>(
        _ sortedItems: [Element],
        selectedID: ID?,
        limit: Int,
        id: KeyPath<Element, ID>,
        areInIncreasingOrder: (Element, Element) -> Bool
    ) -> ProfileListPreview<Element>
    where Element: Equatable & Sendable, ID: Equatable {
        let requestedLimit = max(0, limit)
        let selectedItem = selectedID.flatMap { selectedID in
            sortedItems.first {
                $0[keyPath: id] == selectedID
            }
        }
        let effectiveLimit = selectedItem == nil
            ? requestedLimit
            : max(1, requestedLimit)
        var visibleItems = Array(sortedItems.prefix(effectiveLimit))
        if let selectedItem,
           !visibleItems.contains(where: {
               $0[keyPath: id] == selectedItem[keyPath: id]
           }) {
            if visibleItems.isEmpty {
                visibleItems = [selectedItem]
            } else {
                visibleItems[visibleItems.index(before: visibleItems.endIndex)] =
                    selectedItem
            }
            visibleItems.sort(by: areInIncreasingOrder)
        }
        return ProfileListPreview(
            visibleItems: visibleItems,
            hiddenCount: max(0, sortedItems.count - visibleItems.count)
        )
    }

    /// Production folder state and tag summaries are already sorted by their
    /// owning projections. Preserve the defensive standalone API for callers
    /// with arbitrary input without paying an O(n log n) sort on every SwiftUI
    /// render of an already ordered workspace.
    private static func orderedPreviewSource<Element>(
        _ items: [Element],
        by areInIncreasingOrder: (Element, Element) -> Bool
    ) -> [Element] {
        guard items.count > 1 else { return items }
        for index in items.indices.dropFirst() {
            let previous = items.index(before: index)
            if areInIncreasingOrder(items[index], items[previous]) {
                return items.sorted(by: areInIncreasingOrder)
            }
        }
        return items
    }

    private static func tagSummaryIsInIncreasingOrder(
        _ lhs: ProfileTagSummary,
        _ rhs: ProfileTagSummary
    ) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.id != rhs.id {
            return lhs.id.rawValue < rhs.id.rawValue
        }
        return lhs.name < rhs.name
    }

    private static func tagNameIsInIncreasingOrder(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let nameOrder = lhs.localizedStandardCompare(rhs)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        let lhsID = ProfileTagID(displayName: lhs)
        let rhsID = ProfileTagID(displayName: rhs)
        if lhsID != rhsID {
            return lhsID.rawValue < rhsID.rawValue
        }
        return lhs < rhs
    }

    static func areInIncreasingOrder(
        _ lhs: BrowserProfile,
        _ rhs: BrowserProfile
    ) -> Bool {
        ProfileListOrdering.pinnedThenName.areInIncreasingOrder(lhs, rhs)
    }
}

private enum ProfileSearchText {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func query(_ value: String) -> String {
        fold(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func document(profileValues: [String]) -> String {
        profileValues.map(fold).joined(separator: "\u{0}")
    }

    static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        ).precomposedStringWithCanonicalMapping
    }
}
