import Foundation
import Testing
@testable import NeAntik

struct ProfileSnapshotSaveSummaryTests {
    @Test
    func workspaceNoticesUseLocalizedTemplatesForAllOutcomes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let en = try #require(Bundle(path: root.appendingPathComponent("Resources/en.lproj").path))
        let ru = try #require(Bundle(path: root.appendingPathComponent("Resources/ru.lproj").path))
        let expected: [(WorkspaceSuccessMessage, String)] = [
            (.profilesExported, "Profile settings exported: 2."),
            (.bookmarksImported, "Profile created. Bookmarks: 2."),
            (.profilesImported, "Profiles imported: 2."),
            (.snapshotRestored, "Profiles created from snapshot: 2, with separate data and a new environment configuration."),
            (.diagnosticsSaved, "Safe diagnostics saved."),
            (.encryptedExported, "Encrypted export saved: 2 profiles."),
            (.encryptedImported, "Profiles imported from encrypted file: 2.")
        ]
        #expect(expected.count == WorkspaceSuccessMessage.allCases.count)
        for (message, translation) in expected {
            #expect(message.localized(count: 2, bundle: en) == translation)
            let russian = message.localized(count: 2, bundle: ru)
            #expect(!russian.isEmpty)
            if message != .diagnosticsSaved { #expect(russian.contains("2")) }
        }
        let summary = ProfileSnapshotSaveSummary(savedProfileCount: 7, skippedRunningProfileCount: 2)
        #expect(summary.localizedStatusMessage(bundle: ru) == summary.statusMessage)
        let localized = summary.localizedStatusMessage(bundle: en)
        #expect(localized.contains("Saved settings for 7 profiles."))
        #expect(localized.contains("Running profiles excluded: 2."))
        #expect(localized.contains("BrowserData and cookies are not saved."))
        let single = ProfileSnapshotSaveSummary(savedProfileCount: 1, skippedRunningProfileCount: 0)
        #expect(single.localizedStatusMessage(bundle: en).contains("1 profile."))
        #expect(WorkspaceSuccessMessage.encryptedExported.localized(count: 1, bundle: en) == "Encrypted export saved: 1 profile.")
        #expect(WorkspaceSuccessMessage.encryptedExported.localized(count: 1, bundle: ru).contains("Зашифрованный экспорт сохранён: 1"))
    }

    @Test
    func reportsSavedSettingsAndSkippedRunningProfiles() {
        let summary = ProfileSnapshotSaveSummary(
            savedProfileCount: 7,
            skippedRunningProfileCount: 2
        )

        #expect(summary.statusMessage.contains("7 профилей"))
        #expect(summary.statusMessage.contains("2 профиля"))
        #expect(summary.statusMessage.contains("BrowserData и cookies не сохраняются"))
    }

    @Test
    func omitsSkippedCountWhenEveryProfileIsStopped() {
        let summary = ProfileSnapshotSaveSummary(
            savedProfileCount: 1,
            skippedRunningProfileCount: 0
        )

        #expect(summary.statusMessage.contains("1 профиль"))
        #expect(!summary.statusMessage.contains("не включены"))
    }
}
