import Testing
@testable import NeAntik

struct UserNoticeTests {
    @Test func everyLevelHasDistinctTextAndSymbolSemantics() {
        let levels = UserNoticeLevel.allCases

        #expect(Set(levels.map(\.systemImage)).count == levels.count)
        #expect(Set(levels.map(\.accessibilityTitle)).count == levels.count)
    }

    @Test func accessibilitySummaryNeverReliesOnColorAlone() {
        let notice = UserNotice(
            "Не удалось скопировать",
            level: .failure
        )

        #expect(notice.accessibilitySummary ==
            "Ошибка. Не удалось скопировать")
    }
}
