import Foundation
import Testing
@testable import NeAntik

struct ProfileOrganizationTests {
    @Test
    func legacyProfileGetsStableAppearanceAndEmptyTags() throws {
        let id = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let profile = BrowserProfile(
            id: id,
            name: "Старый профиль",
            colorHex: "#10B981",
            symbolName: "shield.fill",
            tags: ["Работа"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(profile)
        guard var object = try JSONSerialization.jsonObject(with: encoded)
            as? [String: Any]
        else {
            Issue.record("Could not create legacy profile fixture")
            return
        }
        object.removeValue(forKey: "symbolName")
        object.removeValue(forKey: "tags")
        object.removeValue(forKey: "isPinned")
        object.removeValue(forKey: "isArchived")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(BrowserProfile.self, from: legacyData)
        let second = try decoder.decode(BrowserProfile.self, from: legacyData)

        #expect(first.id == id)
        #expect(first.colorHex == "#10B981")
        #expect(first.tags.isEmpty)
        #expect(!first.isPinned)
        #expect(!first.isArchived)
        #expect(first.symbolName == ProfileAppearance.defaultSymbol(for: id))
        #expect(first.symbolName == second.symbolName)
    }

    @Test
    func appearanceAndTagsRoundTripWithoutChangingIdentity() throws {
        let profile = BrowserProfile(
            name: "Проект",
            symbolName: "folder.fill",
            tags: ["Работа", "Клиент"],
            isPinned: true,
            isArchived: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            BrowserProfile.self,
            from: encoder.encode(profile)
        )

        #expect(decoded.id == profile.id)
        #expect(decoded.name == profile.name)
        #expect(decoded.colorHex == profile.colorHex)
        #expect(decoded.symbolName == profile.symbolName)
        #expect(decoded.tags == profile.tags)
        #expect(decoded.isPinned)
        #expect(decoded.isArchived)
        #expect(decoded.startURL == profile.startURL)
        #expect(decoded.proxy == profile.proxy)
        #expect(decoded.identity == profile.identity)
    }

    @Test
    func duplicateHasFreshIdentityAndNoBrowserHistory() {
        let original = BrowserProfile(
            name: String(repeating: "Д", count: 120),
            colorHex: "#10B981",
            symbolName: "folder.fill",
            tags: ["Работа"],
            isPinned: true,
            isArchived: true,
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: "user"
            ),
            lastLaunchedAt: Date(timeIntervalSince1970: 100)
        )

        let copy = original.duplicated(
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(copy.id != original.id)
        #expect(copy.identity.runtimeSeed != original.identity.runtimeSeed)
        #expect(copy.name.count <= BrowserProfile.maximumNameLength)
        #expect(copy.name.hasSuffix(" — копия"))
        #expect(copy.proxy == original.proxy)
        #expect(copy.tags == original.tags)
        #expect(!copy.isPinned)
        #expect(!copy.isArchived)
        #expect(copy.lastLaunchedAt == nil)
        #expect(copy.createdAt == Date(timeIntervalSince1970: 200))
    }

    @Test
    func tagsAreTrimmedBoundedAndDeduplicated() {
        #expect(
            BrowserProfile.normalizedTags([
                " Работа ",
                "работа",
                "Магазин"
            ]) == ["Работа", "Магазин"]
        )
        #expect(
            BrowserProfile.normalizedTags([
                String(
                    repeating: "я",
                    count: BrowserProfile.maximumTagLength + 1
                )
            ]) == nil
        )
        #expect(
            BrowserProfile.normalizedTags(
                (0...BrowserProfile.maximumTagCount).map {
                    "tag-\($0)"
                }
            ) == nil
        )
        #expect(BrowserProfile.normalizedTags(["строка\nвторая"]) == nil)
    }

    @Test
    func searchAndTagFilterHandleUnicode() {
        let profiles = [
            BrowserProfile(
                name: "Рабочий профиль",
                tags: ["Клиент"]
            ),
            BrowserProfile(
                name: "Café",
                tags: ["Покупки"]
            ),
            BrowserProfile(
                name: "日本語",
                tags: ["Личный"]
            )
        ]

        #expect(
            ProfileListProjection.filtered(
                profiles,
                searchText: "рабоч",
                tag: nil
            ).map(\.name) == ["Рабочий профиль"]
        )
        #expect(
            ProfileListProjection.filtered(
                profiles,
                searchText: "cafe",
                tag: nil
            ).map(\.name) == ["Café"]
        )
        #expect(
            ProfileListProjection.filtered(
                profiles,
                searchText: "",
                tag: "личный"
            ).map(\.name) == ["日本語"]
        )
    }

    @Test
    func naturalSortIsStableForDuplicateNames() {
        let early = Date(timeIntervalSince1970: 10)
        let late = Date(timeIntervalSince1970: 20)
        let profiles = [
            BrowserProfile(
                id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
                name: "Profile 10",
                createdAt: early
            ),
            BrowserProfile(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                name: "Same",
                createdAt: late
            ),
            BrowserProfile(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                name: "Same",
                createdAt: late
            ),
            BrowserProfile(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Profile 2",
                createdAt: early
            )
        ]

        let sorted = profiles.sorted(
            by: ProfileListProjection.areInIncreasingOrder
        )
        #expect(sorted.map(\.name).prefix(2) == ["Profile 2", "Profile 10"])
        #expect(sorted.suffix(2).map(\.id.uuidString) == [
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        ])
    }

    @Test
    func pinnedProfilesSortFirstAndScopesExcludeTheOtherSection() {
        let regular = BrowserProfile(name: "Альфа")
        let pinned = BrowserProfile(name: "Якорь", isPinned: true)
        let archived = BrowserProfile(name: "Архив", isArchived: true)
        let profiles = [regular, archived, pinned]

        let active = ProfileListProjection.filtered(
            profiles,
            searchText: "",
            tag: nil
        ).sorted(by: ProfileListProjection.areInIncreasingOrder)
        let archive = ProfileListProjection.filtered(
            profiles,
            searchText: "",
            tag: nil,
            scope: .archived
        )

        #expect(active.map(\.id) == [pinned.id, regular.id])
        #expect(archive.map(\.id) == [archived.id])
    }

    @Test
    func oneHundredProfilesFilterWithoutAnIndex() {
        let profiles = (0..<100).map { index in
            BrowserProfile(
                name: "Профиль \(index)",
                tags: [index.isMultiple(of: 2) ? "Чётные" : "Нечётные"]
            )
        }
        let result = ProfileListProjection.filtered(
            profiles,
            searchText: "Профиль",
            tag: "Чётные"
        )
        #expect(result.count == 50)
    }

    @Test
    func hiddenSelectionMovesToFirstVisibleProfile() {
        let first = BrowserProfile(name: "Альфа", tags: ["Работа"])
        let second = BrowserProfile(name: "Бета", tags: ["Личный"])
        let visible = ProfileListProjection.filtered(
            [first, second],
            searchText: "Бета",
            tag: nil
        )

        #expect(
            ProfileListProjection.normalizedSelection(
                first.id,
                in: visible
            ) == second.id
        )
        #expect(
            ProfileListProjection.normalizedSelection(
                second.id,
                in: visible
            ) == second.id
        )
    }

    @Test
    func emptyProjectionClearsSelection() {
        let profile = BrowserProfile(name: "Профиль")
        #expect(
            ProfileListProjection.normalizedSelection(
                profile.id,
                in: []
            ) == nil
        )
    }

    @Test
    func profilePaletteMaintainsSymbolContrast() {
        for color in ProfileAppearance.colors {
            let ratio = ProfileAppearance.symbolContrastRatio(for: color)
            #expect(ratio != nil)
            #expect((ratio ?? 0) >= 3)
        }
        #expect(
            ProfileAppearance.usesDarkForeground(for: "#EAB308")
        )
        #expect(
            !ProfileAppearance.usesDarkForeground(for: "invalid")
        )
    }
}
