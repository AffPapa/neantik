import Testing
@testable import NeAntik

struct RussianCountTests {
    @Test(arguments: [
        (0, "профилей", "строк", "строк требуют исправления", "0 разделов"),
        (1, "профиль", "строку", "строка требует исправления", "1 раздел"),
        (2, "профиля", "строки", "строки требуют исправления", "2 раздела"),
        (4, "профиля", "строки", "строки требуют исправления", "4 раздела"),
        (5, "профилей", "строк", "строк требуют исправления", "5 разделов"),
        (11, "профилей", "строк", "строк требуют исправления", "11 разделов"),
        (14, "профилей", "строк", "строк требуют исправления", "14 разделов"),
        (21, "профиль", "строку", "строка требует исправления", "21 раздел"),
        (111, "профилей", "строк", "строк требуют исправления", "111 разделов"),
    ])
    func preservesExistingCasesAndVerbAgreement(
        count: Int, profile: String, line: String, status: String, sections: String
    ) {
        #expect(RussianCount.word(
            count, one: "профиль", few: "профиля", many: "профилей"
        ) == profile)
        #expect(RussianCount.title(
            count, one: "профиль", few: "профиля", many: "профилей"
        ) == "\(count) \(profile)")
        #expect(RussianCount.title(
            count, one: "строку", few: "строки", many: "строк"
        ) == "\(count) \(line)")
        #expect(RussianCount.title(
            count, one: "строка требует исправления",
            few: "строки требуют исправления", many: "строк требуют исправления"
        ) == "\(count) \(status)")
        #expect(ProfileEnvironmentPresentation.sectionCountTitle(count) == sections)
    }
}
