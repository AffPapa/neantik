import CoreGraphics

enum WorkspaceLayout {
    static let minimumWindowWidth: CGFloat = 820
    static let minimumWindowHeight: CGFloat = 560
    static let minimumSidebarWidth: CGFloat = 240
    static let maximumSidebarWidth: CGFloat = 300

    static func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        min(
            maximumSidebarWidth,
            max(minimumSidebarWidth, windowWidth * 0.25)
        )
    }
}
