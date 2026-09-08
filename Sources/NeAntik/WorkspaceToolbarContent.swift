import SwiftUI

enum ProfileInspectorPolicy {
    static func canToggle(isPresented: Bool, hasSelectedProfile: Bool) -> Bool {
        isPresented || hasSelectedProfile
    }
}

struct WorkspaceToolbarContent: ToolbarContent {
    let showsProfileInspector: Bool
    let hasSelectedProfile: Bool
    let onPresentReadiness: () -> Void
    let onToggleInspector: () -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Диагностика приложения…", systemImage: "stethoscope", action: onPresentReadiness)
            } label: {
                Label("Помощь", systemImage: "questionmark.circle")
            }
            .help("Диагностика приложения, если что-то не работает")
            .accessibilityLabel("Помощь и диагностика NeAntik")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: onToggleInspector) {
                Label(inspectorTitle, systemImage: "sidebar.right")
            }
            .disabled(!ProfileInspectorPolicy.canToggle(
                isPresented: showsProfileInspector,
                hasSelectedProfile: hasSelectedProfile
            ))
            .help(inspectorHelp)
            .accessibilityLabel(inspectorAccessibilityLabel)
        }
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

}
