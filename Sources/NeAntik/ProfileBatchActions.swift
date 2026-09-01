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
        ViewThatFits(in: .horizontal) {
            expandedActionBar
                .fixedSize(horizontal: true, vertical: false)
            compactActionBar
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var expandedActionBar: some View {
        HStack(spacing: 8) {
            selectionSummary
            toggleAllButton
            if presentation.hasSelection {
                if !presentation.allVisibleSelected {
                    clearSelectionButton
                }
                Divider().frame(height: 18)
                metadataButtons
            }
            if canUndo {
                Divider().frame(height: 18)
                undoButton
            }
        }
    }

    private var compactActionBar: some View {
        HStack(spacing: 8) {
            selectionSummary
            Spacer(minLength: 4)
            toggleAllButton
            if presentation.hasSelection && !presentation.allVisibleSelected {
                clearSelectionButton
            }
            if presentation.hasSelection || canUndo {
                actionMenu
            }
        }
    }

    @ViewBuilder
    private var selectionSummary: some View {
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
    }

    private var toggleAllButton: some View {
        Button(
            presentation.allVisibleSelected ? "Снять все" : "Выбрать все",
            systemImage: presentation.allVisibleSelected
                ? "checkmark.square.fill"
                : "square.stack.3d.up",
            action: onToggleAllVisible
        )
    }

    private var clearSelectionButton: some View {
        Button("Снять выделение", systemImage: "xmark", action: onClear)
    }

    @ViewBuilder
    private var metadataButtons: some View {
        Button(
            presentation.allSelectedPinned ? "Открепить" : "Закрепить",
            systemImage: presentation.allSelectedPinned ? "pin.slash" : "pin",
            action: onTogglePinned
        )
        Button("Папка", systemImage: "folder", action: onChooseFolder)
        Button("Тег", systemImage: "tag", action: onEditTag)
        archiveButton
    }

    private var archiveButton: some View {
        Button(
            presentation.allSelectedArchived ? "Вернуть" : "В архив",
            systemImage: presentation.allSelectedArchived
                ? "arrow.uturn.backward"
                : "archivebox",
            action: onToggleArchived
        )
        .disabled(presentation.containsRunningProfile)
        .help(
            presentation.containsRunningProfile
                ? "Сначала останови выбранные профили"
                : ""
        )
    }

    private var undoButton: some View {
        Button("Отменить", systemImage: "arrow.uturn.backward", action: onUndo)
    }

    private var actionMenu: some View {
        Menu {
            if presentation.hasSelection {
                metadataButtons
            }
            if canUndo {
                if presentation.hasSelection {
                    Divider()
                }
                undoButton
            }
        } label: {
            Label("Действия", systemImage: "ellipsis.circle")
        }
        .accessibilityHint("Открывает массовые действия, которые не поместились")
    }
}
