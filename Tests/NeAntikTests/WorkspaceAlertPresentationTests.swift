import Testing
@testable import NeAntik

struct WorkspaceAlertPresentationTests {
    @Test
    func processAndStorageErrorsOfferReadinessRecovery() {
        for source in [
            WorkspaceAlertPresentation.Source.process,
            .storage,
        ] {
            let presentation = WorkspaceAlertPresentation(
                source: source,
                title: "Ошибка",
                message: "Подробности"
            )
            #expect(presentation.offersReadinessRecovery)
        }
    }

    @Test
    func localErrorsDoNotOfferUnrelatedRecovery() {
        let presentation = WorkspaceAlertPresentation(
            source: .local,
            title: "Ошибка",
            message: "Подробности"
        )
        #expect(!presentation.offersReadinessRecovery)
    }
}
