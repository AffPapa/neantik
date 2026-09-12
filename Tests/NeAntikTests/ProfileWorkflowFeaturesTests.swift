import Foundation
import XCTest
@testable import NeAntik

final class ProfileWorkflowFeaturesTests: XCTestCase {
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
