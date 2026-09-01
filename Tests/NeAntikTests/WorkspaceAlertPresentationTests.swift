import XCTest
@testable import NeAntik

final class WorkspaceAlertPresentationTests: XCTestCase {
    func testProcessAndStorageErrorsOfferReadinessRecovery() {
        for source in [
            WorkspaceAlertPresentation.Source.process,
            .storage,
        ] {
            let presentation = WorkspaceAlertPresentation(
                source: source,
                title: "Ошибка",
                message: "Подробности"
            )
            XCTAssertTrue(presentation.offersReadinessRecovery)
        }
    }

    func testLocalErrorsDoNotOfferUnrelatedRecovery() {
        let presentation = WorkspaceAlertPresentation(
            source: .local,
            title: "Ошибка",
            message: "Подробности"
        )
        XCTAssertFalse(presentation.offersReadinessRecovery)
    }
}
