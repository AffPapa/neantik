import Foundation
import Testing
@testable import NeAntik

struct AccessibilityPresentationTests {
    @Test
    func diagnosticsLabelShowsTheActualNextStep() {
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
        #expect(
            preview.accessibilitySummary ==
                "Профилей будет добавлено: 2. Папок будет использовано: 2. " +
                "Существующих папок совпадёт: 1. Новых папок будет создано: 1."
        )
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
        #expect(
            preview.accessibilitySummary ==
                "Профилей будет добавлено: 1. Папок будет использовано: 0. " +
                "Существующих папок совпадёт: 0. Новых папок будет создано: 0."
        )
    }
}
