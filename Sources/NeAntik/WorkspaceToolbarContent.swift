import SwiftUI

struct WorkspaceToolbarContent: ToolbarContent {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let showsProfileInspector: Bool
    let hasSelectedProfile: Bool
    let onPresentReadiness: () -> Void
    let onToggleInspector: () -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: toggleSidebar) {
                Label(sidebarTitle, systemImage: "sidebar.leading")
            }
            .help(sidebarHelp)
            .accessibilityLabel("\(sidebarTitle) профилей")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: onPresentReadiness) {
                Label("Готовность", systemImage: "checkmark.shield")
            }
            .help("Проверить приложение, движок, данные и процессы")
            .accessibilityLabel("Открыть центр готовности NeAntik")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: onToggleInspector) {
                Label(inspectorTitle, systemImage: "sidebar.right")
            }
            .disabled(!hasSelectedProfile)
            .help(inspectorHelp)
            .accessibilityLabel(inspectorAccessibilityLabel)
        }
    }

    private var sidebarIsHidden: Bool {
        columnVisibility == .detailOnly
    }

    private var sidebarTitle: String {
        sidebarIsHidden ? "Показать боковую панель" : "Скрыть боковую панель"
    }

    private var sidebarHelp: String {
        sidebarIsHidden ? "Показать папки и разделы" : "Скрыть папки и разделы"
    }

    private var inspectorTitle: String {
        showsProfileInspector ? "Скрыть сведения" : "Сведения"
    }

    private var inspectorAccessibilityLabel: String {
        showsProfileInspector
            ? "Скрыть сведения о выбранном профиле"
            : "Показать сведения о выбранном профиле"
    }

    private var inspectorHelp: String {
        showsProfileInspector
            ? "Скрыть сведения о профиле"
            : "Показать сведения о профиле"
    }

    private func toggleSidebar() {
        columnVisibility = sidebarIsHidden ? .all : .detailOnly
    }
}
