import Testing
@testable import NeAntik

struct AccessibilityPresentationTests {
    @Test
    func evidenceStatesUseDistinctNonColorSymbols() {
        let states: [DiagnosticEvidenceState] = [
            .configured,
            .derived,
            .observed,
            .unavailable,
            .unverified,
        ]
        let symbols = states.map(EvidenceBadgePresentation.systemImage)

        #expect(Set(symbols).count == states.count)
        #expect(states.allSatisfy { !$0.title.isEmpty })
    }

    @Test
    func announcementGateSuppressesOnlyConsecutiveDuplicates() {
        var gate =
            AccessibilityAnnouncementGate<
                BulkProxyImportAccessibilityAnnouncement
            >()

        let firstValidation = gate.shouldAnnounce(.validationFailed)
        let duplicateValidation = gate.shouldAnnounce(.validationFailed)
        let firstReady = gate.shouldAnnounce(.ready(2))
        let duplicateReady = gate.shouldAnnounce(.ready(2))
        #expect(firstValidation)
        #expect(!duplicateValidation)
        #expect(firstReady)
        #expect(!duplicateReady)
        gate.reset()
        let readyAfterReset = gate.shouldAnnounce(.ready(2))
        #expect(readyAfterReset)
    }

    @Test
    func bulkAnnouncementsCannotEchoProxyCredentials() {
        let credential = "operator:unique-secret@proxy.example:443"
        let announcements: [BulkProxyImportAccessibilityAnnouncement] = [
            .validationFailed,
            .ready(3),
            .created(3),
            .creationFailed,
        ]

        for announcement in announcements {
            #expect(!announcement.message.contains(credential))
            #expect(!announcement.message.contains("unique-secret"))
            #expect(!announcement.message.contains("proxy.example"))
        }
    }

    @Test
    func folderAnnouncementsAreActionableAndInputIndependent() {
        let announcements: [ProfileFolderAccessibilityAnnouncement] = [
            .invalidName,
            .duplicateName,
            .saveFailed,
        ]

        for announcement in announcements {
            #expect(!announcement.message.isEmpty)
            #expect(!announcement.message.contains("secret-folder-name"))
        }
    }

    @Test
    func tagValidationAnnouncementsSuppressDuplicatesUntilReset() {
        var gate =
            AccessibilityAnnouncementGate<
                ProfileTagEditorAccessibilityAnnouncement
            >()

        let firstTooMany = gate.shouldAnnounce(.tooMany)
        let duplicateTooMany = gate.shouldAnnounce(.tooMany)
        let firstTooLong = gate.shouldAnnounce(.tooLong)
        let duplicateTooLong = gate.shouldAnnounce(.tooLong)

        #expect(firstTooMany)
        #expect(!duplicateTooMany)
        #expect(firstTooLong)
        #expect(!duplicateTooLong)

        gate.reset()

        let tooLongAfterReset = gate.shouldAnnounce(.tooLong)
        let firstInvalid = gate.shouldAnnounce(.invalid)
        let duplicateInvalid = gate.shouldAnnounce(.invalid)

        #expect(tooLongAfterReset)
        #expect(firstInvalid)
        #expect(!duplicateInvalid)
    }

    @Test
    func tagValidationAnnouncementsAreActionableAndInputIndependent() {
        let privateInput = "secret-client-tag"
        let expectations: [
            (
                error: ProfileTagEditorValidationError,
                announcement: ProfileTagEditorAccessibilityAnnouncement
            )
        ] = [
            (.tooMany, .tooMany),
            (.tooLong, .tooLong),
            (.invalid, .invalid),
        ]

        for expectation in expectations {
            let announcement =
                ProfileTagEditorAccessibilityAnnouncement(expectation.error)
            #expect(announcement == expectation.announcement)
            #expect(!announcement.message.isEmpty)
            #expect(announcement.message.contains("Тег не добавлен"))
            #expect(!announcement.message.contains(privateInput))
        }
    }

    @Test
    func notePresentationHasVisibleCountsAndPrivateInputFreeErrors() {
        let privateInput = "private-client-context"
        let oversized = privateInput + String(
            repeating: "З",
            count: BrowserProfile.maximumNoteLength
        )
        let presentation = ProfileNotePresentation.resolve(oversized)

        #expect(
            presentation.countLabel.contains(
                String(BrowserProfile.maximumNoteLength)
            )
        )
        #expect(presentation.validationMessage != nil)
        #expect(!presentation.validationMessage!.contains(privateInput))
    }

    @Test
    func noteCollapsedSummaryNormalizesLineBreaksForOneLinePresentation() {
        let presentation = ProfileNotePresentation.resolve(
            "  Первый шаг\n\nВторой\tшаг  "
        )

        #expect(presentation.collapsedSummary == "Первый шаг Второй шаг")
        #expect(presentation.validationMessage == nil)
    }

    @Test
    func noteExpansionIsOfferedOnlyWhenCompactPresentationCanHideContent() {
        #expect(
            !ProfileNotePresentation.resolve("Короткая заметка").shouldOfferExpansion
        )
        #expect(
            ProfileNotePresentation.resolve("1\n2\n3\n4").shouldOfferExpansion
        )
        #expect(
            ProfileNotePresentation.resolve(
                String(repeating: "Длинный контекст ", count: 14)
            ).shouldOfferExpansion
        )
    }
}
