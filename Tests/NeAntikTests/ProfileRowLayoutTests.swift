import Testing
@testable import NeAntik

struct ProfileRowLayoutTests {
    @Test func wideRowsReserveSpaceForEveryColumnAndBothListInsets() {
        let columns = ProfileRowLayout.selectionWidth +
            ProfileRowLayout.minimumIdentityWidth + ProfileRowLayout.statusWidth +
            ProfileRowLayout.minimumRouteWidth + ProfileRowLayout.minimumContextWidth +
            ProfileRowLayout.menuWidth + ProfileRowLayout.actionWidth
        let contentWidth = ProfileRowLayout.minimumWideWidth -
            ProfileRowLayout.scrollbarAllowance -
            2 * ProfileRowLayout.selectionGutter -
            2 * ProfileRowLayout.listHorizontalInset -
            2 * ProfileRowLayout.outerHorizontalPadding -
            2 * ProfileRowLayout.horizontalPadding

        #expect(contentWidth >= columns + 6 * ProfileRowLayout.spacing)
        #expect(ProfileRowLayout.minimumWideWidth > 820)
    }

    @Test func sectionHeaderUsesTheSameInnerPaddingAsRows() {
        let expected = ProfileRowLayout.outerHorizontalPadding +
            ProfileRowLayout.horizontalPadding
        #expect(Double(ProfileRowLayout.rowContentHorizontalInset) == Double(expected))
    }
}
