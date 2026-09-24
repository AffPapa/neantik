import Foundation
import Testing
@testable import NeAntik

struct AccessibilityPresentationTests {
    @Test
    func diagnosticsAnnouncementIncludesTheActualNextStep() {
        for step: ProfileDiagnosticsNextStep in [
            .recoverProfile, .waitForProfile, .retryInspection,
            .runtimeNeedsAttention, .inspectDetails
        ] {
            #expect(step.accessibilityLabel == "Следующий шаг: " + (step.title ?? ""))
            #expect(step.accessibilityLabel?.contains("(nextStep)") == false)
        }
        #expect(ProfileDiagnosticsNextStep.none.accessibilityLabel == nil)
    }

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

    @Test
    func snapshotRestorePreviewCountsFoldersWithoutExposingProfileData() {
        let profile = BrowserProfile(
            name: "private-profile-name",
            note: "private-note",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "private-proxy.example",
                port: 443,
                username: "private-user"
            ),
            identity: BrowserIdentity(seed: 87654321)
        )
        let payload = ProfileSnapshotRestorePayload(
            profiles: [profile, profile],
            folderNames: ["Work", "New"],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let preview = ProfileSnapshotRestorePreview(
            payload: payload,
            existingFolderNames: ["wórk"]
        )

        #expect(preview.profileCount == 2)
        #expect(preview.folderCount == 2)
        #expect(preview.reusedFolderCount == 1)
        #expect(preview.newFolderCount == 1)
        let presentation = String(describing: preview)
        #expect(!presentation.contains("private-profile-name"))
        #expect(!presentation.contains("private-note"))
        #expect(!presentation.contains("private-proxy.example"))
        #expect(!presentation.contains("private-user"))
        #expect(!presentation.contains("87654321"))
    }

    @Test
    func snapshotRestorePreviewIgnoresProfilesWithoutFolders() {
        let payload = ProfileSnapshotRestorePayload(
            profiles: [BrowserProfile(name: "Local")],
            folderNames: [nil],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let preview = ProfileSnapshotRestorePreview(
            payload: payload,
            existingFolderNames: ["Work"]
        )

        #expect(preview.profileCount == 1)
        #expect(preview.folderCount == 0)
        #expect(preview.reusedFolderCount == 0)
        #expect(preview.newFolderCount == 0)
    }
}
