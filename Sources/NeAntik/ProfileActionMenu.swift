import SwiftUI

/// The shared organization actions keep native and per-row menus consistent.
/// Only the application menu registers keyboard shortcuts.
struct ProfileOrganizationActions: View {
    let commands: ProfileCommandSet
    var registersShortcuts = false

    var body: some View {
        Button(commands.presentation.pinTitle,
               systemImage: commands.presentation.pinSystemImage,
               action: commands.togglePinned)
            .disabled(!commands.hasProfile)
        Button("Создать похожий", systemImage: "plus.square.on.square",
               action: commands.duplicate)
            .keyboardShortcut(registersShortcuts ? KeyboardShortcut(
                NeAntikShortcut.duplicateProfile.keyEquivalent,
                modifiers: NeAntikShortcut.duplicateProfile.modifiers
            ) : nil)
            .disabled(!commands.hasProfile)
        ProfileFolderActions(commands: commands)
        Button(commands.presentation.archiveTitle,
               systemImage: commands.presentation.archiveSystemImage,
               action: commands.toggleArchived)
            .disabled(!commands.presentation.archiveIsEnabled)
    }
}

private struct ProfileFolderActions: View {
    let commands: ProfileCommandSet

    var body: some View {
        Menu("Переместить в папку", systemImage: "folder") {
            ForEach(commands.folderOptions) { option in
                Button {
                    commands.moveToFolder(option.folderID)
                } label: {
                    Label(option.title, systemImage: option.isSelected
                          ? "checkmark" : (option.folderID == nil ? "tray" : "folder"))
                }
            }
            if commands.hasMoreFolderOptions {
                Divider()
                Button("Выбрать другую папку…", systemImage: "magnifyingglass",
                       action: commands.chooseFolder)
            }
        }
        .disabled(!commands.hasProfile)
    }
}
