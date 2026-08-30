import Testing
@testable import NeAntik

struct WorkspaceLayoutTests {
    @Test func listFirstWorkspaceUsesReviewedWidthTokens() {
        #expect(WorkspaceLayout.minimumSourceColumnWidth == 200)
        #expect(WorkspaceLayout.idealSourceColumnWidth == 220)
        #expect(WorkspaceLayout.maximumSourceColumnWidth == 260)

        #expect(WorkspaceLayout.minimumProfileColumnWidth == 520)
        #expect(WorkspaceLayout.idealProfileColumnWidth == 820)
        #expect(WorkspaceLayout.maximumProfileColumnWidth == 1_400)

        #expect(WorkspaceLayout.minimumInspectorWidth == 360)
        #expect(WorkspaceLayout.idealInspectorWidth == 440)
        #expect(WorkspaceLayout.maximumInspectorWidth == 560)
        #expect(WorkspaceLayout.minimumWindowWidth == 820)
        #expect(WorkspaceLayout.minimumWindowHeight == 560)
        #expect(WorkspaceLayout.titlebarContentInset == 40)
    }

    @Test func listAndInspectorWidthRangesAreStrictlyOrdered() {
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
        #expect(
            WorkspaceLayout.minimumInspectorWidth <
                WorkspaceLayout.idealInspectorWidth
        )
        #expect(
            WorkspaceLayout.idealInspectorWidth <
                WorkspaceLayout.maximumInspectorWidth
        )
        #expect(WorkspaceLayout.titlebarContentInset > 0)
        #expect(WorkspaceLayout.titlebarContentInset < 64)
    }
}
