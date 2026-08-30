import CoreGraphics

enum WorkspaceLayout {
    static let minimumWindowWidth: CGFloat = 820
    static let minimumWindowHeight: CGFloat = 560

    /// Keeps the list command surface below the unified macOS titlebar while
    /// preserving the native navigation title and toolbar hit targets.
    static let titlebarContentInset: CGFloat = 40

    static let minimumSourceColumnWidth: CGFloat = 200
    static let idealSourceColumnWidth: CGFloat = 220
    static let maximumSourceColumnWidth: CGFloat = 260

    static let minimumProfileColumnWidth: CGFloat = 520
    static let idealProfileColumnWidth: CGFloat = 820
    static let maximumProfileColumnWidth: CGFloat = 1_400

    static let minimumInspectorWidth: CGFloat = 360
    static let idealInspectorWidth: CGFloat = 440
    static let maximumInspectorWidth: CGFloat = 560
}
