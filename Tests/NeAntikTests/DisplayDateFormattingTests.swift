import Foundation
import Testing
@testable import NeAntik

struct DisplayDateFormattingTests {
    @Test
    func dateTimeUsesRussianPresentationIndependentlyOfSystemLocale() {
        let date = Date(timeIntervalSince1970: 1_777_142_260)
        let value = date.neAntikDisplayDateTime

        #expect(!value.contains(" at "))
        #expect(!value.contains("Aug"))
        #expect(value.contains("2026"))
    }
}
