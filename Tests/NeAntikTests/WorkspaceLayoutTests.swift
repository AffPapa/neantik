import Testing
@testable import NeAntik

struct WorkspaceLayoutTests {
    @Test func threeColumnWorkspaceUsesReviewedWidthTokens() {
        #expect(WorkspaceLayout.minimumSourceColumnWidth == 200)
        #expect(WorkspaceLayout.idealSourceColumnWidth == 220)
        #expect(WorkspaceLayout.maximumSourceColumnWidth == 260)

        #expect(WorkspaceLayout.minimumProfileColumnWidth == 300)
        #expect(WorkspaceLayout.idealProfileColumnWidth == 360)
        #expect(WorkspaceLayout.maximumProfileColumnWidth == 440)

        #expect(WorkspaceLayout.minimumDetailColumnWidth == 480)
        #expect(WorkspaceLayout.minimumWindowWidth == 820)
        #expect(WorkspaceLayout.minimumWindowHeight == 560)
    }

    @Test func threeColumnWidthRangesAreStrictlyOrdered() {
        #expect(
            WorkspaceLayout.minimumSourceColumnWidth <
                WorkspaceLayout.idealSourceColumnWidth
        )
        #expect(
            WorkspaceLayout.idealSourceColumnWidth <
                WorkspaceLayout.maximumSourceColumnWidth
        )
        #expect(
            WorkspaceLayout.minimumProfileColumnWidth <
                WorkspaceLayout.idealProfileColumnWidth
        )
        #expect(
            WorkspaceLayout.idealProfileColumnWidth <
                WorkspaceLayout.maximumProfileColumnWidth
        )
    }
}
