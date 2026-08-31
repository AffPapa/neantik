import SwiftUI

enum WorkspaceKeyboardRegion: Int, CaseIterable, Hashable, Sendable {
    case sidebar
    case profileList
    case inspector

    var accessibilityIdentifier: String {
        switch self {
        case .sidebar: "workspace.sidebar"
        case .profileList: "workspace.profile-list"
        case .inspector: "workspace.inspector"
        }
    }

    var accessibilityPriority: Double {
        Double(WorkspaceKeyboardRegion.allCases.count - rawValue)
    }
}

private struct WorkspaceKeyboardRegionModifier: ViewModifier {
    let region: WorkspaceKeyboardRegion

    func body(content: Content) -> some View {
        content
            .focusSection()
            .accessibilityIdentifier(region.accessibilityIdentifier)
            .accessibilitySortPriority(region.accessibilityPriority)
    }
}

extension View {
    func workspaceKeyboardRegion(
        _ region: WorkspaceKeyboardRegion
    ) -> some View {
        modifier(WorkspaceKeyboardRegionModifier(region: region))
    }
}

enum WorkspaceLayout {
    static let keyboardRegionOrder = WorkspaceKeyboardRegion.allCases
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
