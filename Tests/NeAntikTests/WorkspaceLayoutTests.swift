import Testing
@testable import NeAntik

struct WorkspaceLayoutTests {
    @Test func sidebarWidthClampsAtTheMinimum() {
        #expect(WorkspaceLayout.sidebarWidth(for: 500) == 240)
        #expect(WorkspaceLayout.sidebarWidth(for: 820) == 240)
    }

    @Test func sidebarWidthGrowsOnlyWithinItsUsefulRange() {
        #expect(WorkspaceLayout.sidebarWidth(for: 1_000) == 250)
        #expect(WorkspaceLayout.sidebarWidth(for: 1_200) == 300)
        #expect(WorkspaceLayout.sidebarWidth(for: 2_000) == 300)
    }
}
