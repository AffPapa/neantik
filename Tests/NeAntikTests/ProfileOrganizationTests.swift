import Foundation
import Testing
@testable import NeAntik

struct ProfileOrganizationTests {
    @Test
    func newProfileUsesEditableAffTopFingerprintStartPage() {
        let profile = BrowserProfile(name: "Новый профиль")

        #expect(
            profile.startURL == "https://aff.top/tools/fingerprint"
        )
    }

    @Test
    func storedStartPageSurvivesDecodeWithoutMigration() throws {
        let profile = BrowserProfile(
            name: "Существующий профиль",
            startURL: "https://www.google.com"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            BrowserProfile.self,
            from: encoder.encode(profile)
        )

        #expect(decoded.startURL == "https://www.google.com")
    }

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
        object.removeValue(forKey: "note")
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
        #expect(first.note.isEmpty)
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
            note: "Первая строка\n\nВторая строка",
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
        #expect(decoded.note == profile.note)
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
            note: "Не копировать в новый профиль",
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
        #expect(copy.note.isEmpty)
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
    func compatibilityEnvelopesPreserveZWJLimitsAndRejectPathologicalInput() {
        func singleGrapheme(atUTF8Boundary byteCount: Int) -> String {
            "a\u{1AB0}" + String(
                repeating: "\u{301}",
                count: (byteCount - 4) / 2
            )
        }

        let family = "👨‍👩‍👧‍👦"
        let validName = String(
            repeating: family,
            count: BrowserProfile.maximumNameLength
        )
        let validTag = String(
            repeating: family,
            count: BrowserProfile.maximumTagLength
        )
        let validFolder = String(
            repeating: family,
            count: ProfileFolder.maximumNameLength
        )
        let validUsername = String(repeating: family, count: 512)

        #expect(validName.utf8.count == 3_000)
        #expect(validTag.utf8.count == 600)
        #expect(validFolder.utf8.count == 1_600)
        #expect(validUsername.utf8.count == 12_800)
        #expect(BrowserProfile.isValidName(validName))
        #expect(BrowserProfile.normalizedTags([validTag]) == [validTag])
        #expect(ProfileFolder.normalizedName(validFolder) == validFolder)
        #expect(
            ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8_080,
                username: validUsername
            ).isValid
        )
        #expect(
            !ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8_080,
                username: validUsername + family
            ).isValid
        )

        let nameBoundary = singleGrapheme(
            atUTF8Boundary: BrowserProfile.maximumNameUTF8Bytes
        )
        let tagBoundary = singleGrapheme(
            atUTF8Boundary: BrowserProfile.maximumTagUTF8Bytes
        )
        let folderBoundary = singleGrapheme(
            atUTF8Boundary: ProfileFolder.maximumNameUTF8Bytes
        )
        let usernameBoundary = singleGrapheme(
            atUTF8Boundary: ProxyConfiguration.maximumUsernameUTF8Bytes
        )
        #expect(nameBoundary.count == 1)
        #expect(BrowserProfile.isValidName(nameBoundary))
        #expect(!BrowserProfile.isValidName(nameBoundary + "\u{301}"))
        #expect(BrowserProfile.normalizedTags([tagBoundary]) == [tagBoundary])
        #expect(
            BrowserProfile.normalizedTags([tagBoundary + "\u{301}"]) == nil
        )
        #expect(ProfileFolder.normalizedName(folderBoundary) == folderBoundary)
        #expect(
            ProfileFolder.normalizedName(folderBoundary + "\u{301}") == nil
        )
        #expect(
            ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8_080,
                username: usernameBoundary
            ).isValid
        )
        #expect(
            !ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8_080,
                username: usernameBoundary + "\u{301}"
            ).isValid
        )

        let pathological =
            "a" + String(repeating: "\u{301}", count: 1_100_000)
        #expect(pathological.count == 1)
        #expect(pathological.utf8.count > 2 * 1_024 * 1_024)
        #expect(!BrowserProfile.isValidName(pathological))
        #expect(BrowserProfile.normalizedTags([pathological]) == nil)
        #expect(ProfileFolder.normalizedName(pathological) == nil)
        #expect(
            !ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8_080,
                username: pathological
            ).isValid
        )
    }

    @Test
    func persistedProfileValidatorCoversColorURLAndProxy() throws {
        let valid = BrowserProfile(
            name: "Valid",
            colorHex: "#abcdef",
            startURL: "https://example.com/path",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8_080,
                username: "user"
            )
        )
        #expect(valid.normalizedForPersistence() != nil)

        var invalidColor = valid
        invalidColor.colorHex = "javascript:red"
        var invalidURL = valid
        invalidURL.startURL = "file:///tmp/private"
        let urlPrefix = "https://example.com/?q="
        var boundaryURL = valid
        boundaryURL.startURL = urlPrefix + String(
            repeating: "a",
            count:
                BrowserProfile.maximumStartURLUTF8Bytes -
                urlPrefix.utf8.count
        )
        #expect(
            boundaryURL.startURL.utf8.count ==
                BrowserProfile.maximumStartURLUTF8Bytes
        )
        #expect(boundaryURL.normalizedForPersistence() != nil)
        var oversizedURL = boundaryURL
        oversizedURL.startURL += "a"
        var invalidProxy = valid
        invalidProxy.proxy?.port = 0

        for invalid in [invalidColor, invalidURL, oversizedURL, invalidProxy] {
            #expect(invalid.normalizedForPersistence() == nil)
            let data = try JSONEncoder().encode(invalid)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(BrowserProfile.self, from: data)
            }
        }
    }

    @Test
    func noteNormalizationPreservesInternalLinesAndRejectsUnsafeInput() {
        #expect(
            BrowserProfile.normalizedNote(
                "  Первая строка\r\n\rВторая\tчасть  "
            ) == "Первая строка\n\nВторая\tчасть"
        )
        #expect(
            BrowserProfile.normalizedNote(
                String(
                    repeating: "я",
                    count: BrowserProfile.maximumNoteLength
                )
            ) != nil
        )
        #expect(
            BrowserProfile.normalizedNote(
                String(
                    repeating: "я",
                    count: BrowserProfile.maximumNoteLength + 1
                )
            ) == nil
        )
        #expect(
            BrowserProfile.normalizedNote(
                String(
                    repeating: "👨‍👩‍👧‍👦",
                    count: BrowserProfile.maximumNoteLength
                )
            ) == nil
        )
        #expect(BrowserProfile.normalizedNote("safe\u{0}unsafe") == nil)
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
    func tagProjectionDeduplicatesFoldedUnicodeAndPreservesFirstLabel() {
        let profiles = [
            BrowserProfile(name: "A", tags: ["Café", "Работа"]),
            BrowserProfile(name: "B", tags: ["cafe", "РАБОТА"]),
        ]

        let tags = ProfileListProjection.allTags(in: profiles)

        #expect(tags.count == 2)
        #expect(tags.contains("Café"))
        #expect(tags.contains("Работа"))
        #expect(!tags.contains("cafe"))
        #expect(!tags.contains("РАБОТА"))
    }

    @Test
    func folderProjectionCombinesScopeSearchTagAndFolderName() {
        let workID = UUID()
        let personalID = UUID()
        let work = BrowserProfile(name: "Alpha", tags: ["Клиент"])
        let personal = BrowserProfile(name: "Beta", tags: ["Личный"])
        let unfiled = BrowserProfile(name: "Gamma", tags: ["Клиент"])
        let archived = BrowserProfile(
            name: "Archived",
            tags: ["Клиент"],
            isArchived: true
        )
        let organization = ProfileOrganizationState(
            folders: [
                ProfileFolder(id: workID, name: "Работа"),
                ProfileFolder(id: personalID, name: "Личное")
            ],
            assignmentsByProfileID: [
                work.id: workID,
                personal.id: personalID,
                archived.id: workID
            ]
        )
        let profiles = [work, personal, unfiled, archived]

        #expect(
            ProfileListProjection.filtered(
                profiles,
                searchText: "работа",
                tag: nil,
                folderFilter: .all,
                organization: organization
            ).map(\.id) == [work.id]
        )
        #expect(
            ProfileListProjection.filtered(
                profiles,
                searchText: "",
                tag: "клиент",
                folderFilter: .folder(workID),
                organization: organization
            ).map(\.id) == [work.id]
        )
        #expect(
            Set(
                ProfileListProjection.filtered(
                    profiles,
                    searchText: "",
                    tag: nil,
                    folderFilter: .unfiled,
                    organization: organization
                ).map(\.id)
            ) == Set([unfiled.id])
        )
        #expect(
            ProfileListProjection.count(
                profiles,
                scope: .archived,
                folderFilter: .folder(workID),
                organization: organization
            ) == 1
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
        let archivedPinned = BrowserProfile(
            name: "Архив",
            isPinned: true,
            isArchived: true
        )
        let profiles = [regular, archivedPinned, pinned]

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
        let pinnedOnly = ProfileListProjection.filtered(
            profiles,
            searchText: "",
            tag: nil,
            scope: .pinned
        )

        #expect(active.map(\.id) == [pinned.id, regular.id])
        #expect(archive.map(\.id) == [archivedPinned.id])
        #expect(pinnedOnly.map(\.id) == [pinned.id])
    }

    @Test
    func pinnedScopeComposesWithFolderTagAndSearch() {
        let workID = UUID()
        let matching = BrowserProfile(
            name: "QA Alpha",
            tags: ["Demo"],
            isPinned: true
        )
        let wrongTag = BrowserProfile(
            name: "QA Beta",
            tags: ["Личный"],
            isPinned: true
        )
        let wrongFolder = BrowserProfile(
            name: "QA Gamma",
            tags: ["Demo"],
            isPinned: true
        )
        let notPinned = BrowserProfile(
            name: "QA Delta",
            tags: ["Demo"]
        )
        let archivedPinned = BrowserProfile(
            name: "QA Archived",
            tags: ["Demo"],
            isPinned: true,
            isArchived: true
        )
        let organization = ProfileOrganizationState(
            folders: [ProfileFolder(id: workID, name: "QA Workspaces")],
            assignmentsByProfileID: [
                matching.id: workID,
                wrongTag.id: workID,
                notPinned.id: workID,
                archivedPinned.id: workID,
            ]
        )

        let result = ProfileListProjection.filtered(
            [
                matching,
                wrongTag,
                wrongFolder,
                notPinned,
                archivedPinned,
            ],
            searchText: "alpha",
            tag: "demo",
            scope: .pinned,
            folderFilter: .folder(workID),
            organization: organization
        )

        #expect(result.map(\.id) == [matching.id])
        #expect(
            ProfileListProjection.count(
                [
                    matching,
                    wrongTag,
                    wrongFolder,
                    notPinned,
                    archivedPinned,
                ],
                scope: .pinned,
                folderFilter: .folder(workID),
                organization: organization
            ) == 2
        )
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
    func sourceIndexUsesFolderAwareActiveTagCountsAndConstantFolderLookup() {
        let workID = UUID()
        let emptyID = UUID()
        let work = BrowserProfile(
            name: "Work",
            tags: ["Café"],
            isPinned: true
        )
        let unfiled = BrowserProfile(name: "Loose", tags: ["cafe"])
        let archived = BrowserProfile(
            name: "Archived",
            tags: ["Только архив"],
            isArchived: true
        )
        let organization = ProfileOrganizationState(
            folders: [
                ProfileFolder(id: workID, name: "Работа"),
                ProfileFolder(id: emptyID, name: "Пустая"),
            ],
            assignmentsByProfileID: [
                work.id: workID,
                archived.id: emptyID,
            ]
        )

        let index = ProfileListIndex(
            profiles: [work, unfiled, archived],
            organization: organization
        )

        #expect(index.activeCount == 2)
        #expect(index.pinnedCount == 1)
        #expect(index.archivedCount == 1)
        #expect(index.unfiledCount == 1)
        #expect(index.activeCount(in: .folder(workID)) == 1)
        #expect(index.activeCount(in: .folder(emptyID)) == 0)
        #expect(index.folderNameByID[workID] == "Работа")
        #expect(
            index.tagSummaries(in: .all) == [
                ProfileTagSummary(name: "Café", count: 2)
            ]
        )
        #expect(
            index.tagSummaries(in: .folder(workID)) == [
                ProfileTagSummary(name: "Café", count: 1)
            ]
        )
        #expect(index.tagSummaries(in: .folder(emptyID)).isEmpty)
    }

    @Test
    func sourceIndexBuildsTenThousandProfilesWithinAReasonableDebugBudget() {
        let folderID = UUID()
        let identity = BrowserIdentity(seed: 42)
        let profiles = (0..<10_000).map { index in
            BrowserProfile(
                name: "Profile \(index)",
                tags: ["Shared", "Unique \(index)"],
                isPinned: index.isMultiple(of: 10),
                identity: identity
            )
        }
        let organization = ProfileOrganizationState(
            folders: [ProfileFolder(id: folderID, name: "Scale")],
            assignmentsByProfileID: Dictionary(
                uniqueKeysWithValues: profiles.prefix(5_000).map {
                    ($0.id, folderID)
                }
            )
        )
        let startedAt = Date()

        let index = ProfileListIndex(
            profiles: profiles,
            organization: organization
        )

        #expect(index.activeCount == 10_000)
        #expect(index.activeCount(in: .folder(folderID)) == 5_000)
        #expect(
            index.tagSummaries(in: .all).first {
                $0.name == "Shared"
            }?.count == 10_000
        )
        #expect(Date().timeIntervalSince(startedAt) < 3)
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
