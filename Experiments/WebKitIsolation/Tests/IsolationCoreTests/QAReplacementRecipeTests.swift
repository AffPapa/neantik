import XCTest
@testable import IsolationCore

final class QAReplacementRecipeTests: XCTestCase {
    func testOnlyReviewedTransitions() {
        XCTAssertTrue(QAReplacementRecipe.permits(from: "3", to: "5"))
        XCTAssertTrue(QAReplacementRecipe.permits(from: "5", to: "6"))
    }
    func testUnknownSameAndDowngradeRefuse() {
        for pair in [("5", "5"), ("6", "5"), ("3", "6"), ("4", "6"),
                     ("5", "7"), ("05", "6"), ("5", "06"), ("", "6")] {
            XCTAssertFalse(QAReplacementRecipe.permits(from: pair.0, to: pair.1))
        }
    }
}
