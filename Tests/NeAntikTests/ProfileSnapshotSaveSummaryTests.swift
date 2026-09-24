import Testing
@testable import NeAntik

struct ProfileSnapshotSaveSummaryTests {
    @Test
    func reportsSavedSettingsAndSkippedRunningProfiles() {
        let summary = ProfileSnapshotSaveSummary(
            savedProfileCount: 7,
            skippedRunningProfileCount: 2
        )

        #expect(summary.announcement.contains("7 профилей"))
        #expect(summary.announcement.contains("2 профиля"))
        #expect(summary.announcement.contains("BrowserData и cookies не сохраняются"))
    }

    @Test
    func omitsSkippedCountWhenEveryProfileIsStopped() {
        let summary = ProfileSnapshotSaveSummary(
            savedProfileCount: 1,
            skippedRunningProfileCount: 0
        )

        #expect(summary.announcement.contains("1 профиль"))
        #expect(!summary.announcement.contains("не включены"))
    }
}
