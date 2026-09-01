import SwiftUI

struct ProfileBatchSelectionPresentation: Equatable, Sendable {
    let selectedProfileIDs: Set<UUID>
    let visibleProfileIDs: Set<UUID>
    let allVisibleSelected: Bool
    let allSelectedPinned: Bool
    let allSelectedArchived: Bool
    let containsRunningProfile: Bool

    var selectedCount: Int { selectedProfileIDs.count }
    var hasSelection: Bool { !selectedProfileIDs.isEmpty }

    static func resolve(
        visibleProfiles: [BrowserProfile],
        selectedProfileIDs: Set<UUID>,
        runningProfileIDs: Set<UUID>
    ) -> Self {
        let visibleProfileIDs = Set(visibleProfiles.map(\.id))
        let selectedProfileIDs = selectedProfileIDs.intersection(
            visibleProfileIDs
        )
        let selectedProfiles = visibleProfiles.filter {
            selectedProfileIDs.contains($0.id)
        }
        return Self(
            selectedProfileIDs: selectedProfileIDs,
            visibleProfileIDs: visibleProfileIDs,
            allVisibleSelected:
                !visibleProfileIDs.isEmpty &&
                selectedProfileIDs == visibleProfileIDs,
            allSelectedPinned:
                !selectedProfiles.isEmpty &&
                selectedProfiles.allSatisfy(\.isPinned),
            allSelectedArchived:
                !selectedProfiles.isEmpty &&
                selectedProfiles.allSatisfy(\.isArchived),
            containsRunningProfile:
                !selectedProfileIDs.isDisjoint(with: runningProfileIDs)
        )
    }
}

struct ProfileBatchActionBar: View {
    let presentation: ProfileBatchSelectionPresentation
    let canUndo: Bool
    let onToggleAllVisible: () -> Void
    let onClear: () -> Void
    let onTogglePinned: () -> Void
    let onChooseFolder: () -> Void
    let onEditTag: () -> Void
    let onToggleArchived: () -> Void
    let onUndo: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if presentation.hasSelection {
                    Text("Выбрано: \(presentation.selectedCount)")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityLabel(
                            "Выбрано профилей: \(presentation.selectedCount)"
                        )
                } else {
                    Text("Массовые действия")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Button(
                    presentation.allVisibleSelected
                        ? "Снять все"
                        : "Выбрать все",
                    systemImage:
                        presentation.allVisibleSelected
                            ? "checkmark.square.fill"
                            : "square.stack.3d.up"
                ) {
                    onToggleAllVisible()
                }

                if presentation.hasSelection {
                    Button("Снять", systemImage: "xmark") {
                        onClear()
                    }

                    Divider().frame(height: 18)

                    Button(
                        presentation.allSelectedPinned
                            ? "Открепить"
                            : "Закрепить",
                        systemImage:
                            presentation.allSelectedPinned
                                ? "pin.slash"
                                : "pin"
                    ) {
                        onTogglePinned()
                    }
                    Button("Папка", systemImage: "folder") {
                        onChooseFolder()
                    }
                    Button("Тег", systemImage: "tag") {
                        onEditTag()
                    }
                    Button(
                        presentation.allSelectedArchived
                            ? "Вернуть"
                            : "В архив",
                        systemImage:
                            presentation.allSelectedArchived
                                ? "arrow.uturn.backward"
                                : "archivebox"
                    ) {
                        onToggleArchived()
                    }
                    .disabled(presentation.containsRunningProfile)
                    .help(
                        presentation.containsRunningProfile
                            ? "Сначала останови выбранные профили"
                            : ""
                    )
                }

                if canUndo {
                    Divider().frame(height: 18)
                    Button("Отменить", systemImage: "arrow.uturn.backward") {
                        onUndo()
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
