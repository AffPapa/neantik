import Foundation
import XCTest
@testable import NeAntik

final class ProfileWorkflowFeaturesTests: XCTestCase {
    @MainActor
    func testTelemetryNeverFallsBackToZeroVersionOrBuild() {
        XCTAssertEqual(NeAntikTelemetry.validVersion(nil), "0.6.1")
        XCTAssertEqual(NeAntikTelemetry.validVersion("0.0.0"), "0.6.1")
        XCTAssertEqual(NeAntikTelemetry.validBuild(nil), "43")
        XCTAssertEqual(NeAntikTelemetry.validBuild("0"), "43")
        XCTAssertEqual(NeAntikTelemetry.validBuild("17"), "17")
    }
    func testCommandPaletteMatchesRussianAndEnglishTerms() {
        XCTAssertTrue(WorkspaceCommand.cleanLaunch.matches("чистый"))
        XCTAssertTrue(WorkspaceCommand.search.matches("search"))
        XCTAssertFalse(WorkspaceCommand.reopenLast.matches("прокси"))
    }

    func testSemanticSearchRanksNameThenNoteAndTags() {
        let first = BrowserProfile(name: "Работа", note: "дизайн")
        let second = BrowserProfile(name: "Личное", tags: ["работа"])
        let result = ProfileSemanticSearch.rank([second, first], query: "работа")
        XCTAssertEqual(result.map(\.profileID), [first.id, second.id])
        XCTAssertEqual(result.first?.matchedFields, ["название"])
    }

    func testSuggestionsAreDeterministicAndUseful() {
        let now = Date()
        let profiles = [BrowserProfile(name: "A", tags: ["дизайн"], lastLaunchedAt: now.addingTimeInterval(-31 * 86400)), BrowserProfile(name: "B", tags: ["дизайн"])]
        XCTAssertEqual(ProfileAutomationSuggestions.suggestions(for: profiles, now: now), ["дизайн", "Без прокси", "Ни разу не запускались", "Давно не запускались"])
    }

    func testCookieParserAcceptsJSONAndNetscape() throws {
        let json = Data(#"[{"name":"sid","value":"x","domain":"example.com","path":"/","secure":true}]"#.utf8)
        XCTAssertEqual(try CookieImportParser.parse(json).first?.name, "sid")
        let netscape = Data(".example.com\tTRUE\t/\tFALSE\t0\tsid\tx\n".utf8)
        let imported = try CookieImportParser.parse(netscape).first
        XCTAssertEqual(imported?.domain, ".example.com")
        XCTAssertFalse(imported?.httpOnly ?? true)
    }

    func testCookieParserRejectsInvalidPath() {
        let json = Data(#"[{"name":"sid","value":"x","domain":"example.com","path":"bad"}]"#.utf8)
        XCTAssertThrowsError(try CookieImportParser.parse(json)) { error in
            XCTAssertEqual(error as? CookieImportError, .invalidRecord(1))
        }
    }

    func testStartupTabsOnlyAllowHTTP() {
        XCTAssertTrue(StartupTabSet(urls: ["https://example.com"]).isValid)
        XCTAssertFalse(StartupTabSet(urls: ["file:///tmp/private"]).isValid)
    }

    func testStartupTabsPersistAndLegacyProfilesDefaultToEmpty() throws {
        let profile = BrowserProfile(
            name: "Pinned tabs",
            startupTabs: StartupTabSet(urls: [
                "https://example.com/one",
                "https://example.org/two"
            ])
        )
        let encoder = JSONEncoder.neantikStable
        let decoder = JSONDecoder.neantikStable
        let decoded = try decoder.decode(
            BrowserProfile.self,
            from: encoder.encode(profile)
        )
        XCTAssertEqual(decoded.startupTabs, profile.startupTabs)

        var legacy = try JSONSerialization.jsonObject(
            with: encoder.encode(profile)
        ) as! [String: Any]
        legacy.removeValue(forKey: "startupTabs")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let migrated = try decoder.decode(BrowserProfile.self, from: legacyData)
        XCTAssertEqual(migrated.startupTabs, StartupTabSet())
    }

    func testActivityLogIsBoundedAndNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let log = LocalActivityLogStore(rootDirectory: root, maximumEvents: 2)
        let old = LocalActivityEvent(kind: .launched, date: Date(timeIntervalSince1970: 1))
        let newer = LocalActivityEvent(kind: .restored, date: Date(timeIntervalSince1970: 2))
        let newest = LocalActivityEvent(kind: .cleanLaunch, date: Date(timeIntervalSince1970: 3))
        try log.append(old)
        try log.append(newer)
        try log.append(newest)
        XCTAssertEqual(log.events().map(\.kind), [.cleanLaunch, .restored])
    }
}
