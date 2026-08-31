import SwiftUI

struct ProfileCommandPresentation: Equatable, Sendable {
    let profileName: String?
    let launchTitle: String
    let launchSystemImage: String
    let launchHelp: String
    let launchIsEnabled: Bool
    let editIsEnabled: Bool
    let pinTitle: String
    let pinSystemImage: String
    let archiveTitle: String
    let archiveSystemImage: String
    let archiveIsEnabled: Bool
    let deleteIsEnabled: Bool

    static let unavailable = ProfileCommandPresentation(
        profileName: nil,
        launchTitle: "Запустить",
        launchSystemImage: "play.fill",
        launchHelp: "Сначала выбери профиль",
        launchIsEnabled: false,
        editIsEnabled: false,
        pinTitle: "Закрепить",
        pinSystemImage: "pin",
        archiveTitle: "В архив",
        archiveSystemImage: "archivebox",
        archiveIsEnabled: false,
        deleteIsEnabled: false
    )

    static func resolve(
        profile: BrowserProfile,
        processState: BrowserProfileProcessState,
        launchAction: BrowserLaunchActionPresentation
    ) -> Self {
        ProfileCommandPresentation(
            profileName: profile.name,
            launchTitle: launchAction.title,
            launchSystemImage: launchAction.systemImage,
            launchHelp: launchAction.help,
            launchIsEnabled: launchAction.isEnabled,
            editIsEnabled:
                processState == .stopped || processState.isConfirmedRunning,
            pinTitle: profile.isPinned ? "Открепить" : "Закрепить",
            pinSystemImage: profile.isPinned ? "pin.slash" : "pin",
            archiveTitle:
                profile.isArchived ? "Вернуть из архива" : "В архив",
            archiveSystemImage:
                profile.isArchived
                    ? "arrow.uturn.backward"
                    : "archivebox",
            archiveIsEnabled: !processState.isRunning,
            deleteIsEnabled: !processState.isRunning
        )
    }
}

struct ProfileFolderCommandOption: Identifiable, Equatable, Sendable {
    let folderID: UUID?
    let title: String
    let isSelected: Bool

    var id: String {
        folderID?.uuidString ?? "unfiled"
    }
}

struct ProfileFolderCommandProjection: Equatable, Sendable {
    static let defaultLimit = 8

    let options: [ProfileFolderCommandOption]
    let hasMore: Bool

    static func resolve(
        folders: [ProfileFolder],
        currentFolderID: UUID?,
        limit: Int = defaultLimit
    ) -> Self {
        // ProfileOrganizationState maintains this array in display order.
        // Keep the command projection linear and never sort it during render.
        let safeLimit = max(1, limit)
        var visibleFolders: [ProfileFolder] = []

        if let currentFolderID,
           let current = folders.first(where: {
               $0.id == currentFolderID
           })
        {
            visibleFolders.append(current)
        }

        let remainingSlots = max(0, safeLimit - 1 - visibleFolders.count)
        visibleFolders.append(
            contentsOf: folders.lazy.filter {
                $0.id != currentFolderID
            }.prefix(remainingSlots)
        )

        let options = [
            ProfileFolderCommandOption(
                folderID: nil,
                title: "Без папки",
                isSelected: currentFolderID == nil
            )
        ] + visibleFolders.map { folder in
            ProfileFolderCommandOption(
                folderID: folder.id,
                title: folder.name,
                isSelected: currentFolderID == folder.id
            )
        }

        return Self(
            options: options,
            hasMore: visibleFolders.count < folders.count
        )
    }
}

@MainActor
struct ProfileCommandSet {
    let presentation: ProfileCommandPresentation
    let folderOptions: [ProfileFolderCommandOption]
    let hasMoreFolderOptions: Bool
    let toggleRunning: () -> Void
    let edit: () -> Void
    let togglePinned: () -> Void
    let duplicate: () -> Void
    let moveToFolder: (UUID?) -> Void
    let chooseFolder: () -> Void
    let toggleArchived: () -> Void
    let revealInFinder: () -> Void
    let delete: () -> Void

    static let unavailable = ProfileCommandSet(
        presentation: .unavailable,
        folderOptions: [],
        hasMoreFolderOptions: false,
        toggleRunning: {},
        edit: {},
        togglePinned: {},
        duplicate: {},
        moveToFolder: { _ in },
        chooseFolder: {},
        toggleArchived: {},
        revealInFinder: {},
        delete: {}
    )

    var hasProfile: Bool {
        presentation.profileName != nil
    }
}

@MainActor
struct WorkspaceCommandSet {
    let isEnabled: Bool
    let selectedFolderName: String?
    let createProfile: () -> Void
    let createFolder: () -> Void
    let focusProfileSearch: () -> Void
    let renameSelectedFolder: () -> Void
    let deleteSelectedFolder: () -> Void

    static let unavailable = WorkspaceCommandSet(
        isEnabled: false,
        selectedFolderName: nil,
        createProfile: {},
        createFolder: {},
        focusProfileSearch: {},
        renameSelectedFolder: {},
        deleteSelectedFolder: {}
    )
}

private struct NeAntikProfileCommandsKey: FocusedValueKey {
    typealias Value = ProfileCommandSet
}

private struct NeAntikWorkspaceCommandsKey: FocusedValueKey {
    typealias Value = WorkspaceCommandSet
}

extension FocusedValues {
    var neAntikProfileCommands: ProfileCommandSet? {
        get { self[NeAntikProfileCommandsKey.self] }
        set { self[NeAntikProfileCommandsKey.self] = newValue }
    }

    var neAntikWorkspaceCommands: WorkspaceCommandSet? {
        get { self[NeAntikWorkspaceCommandsKey.self] }
        set { self[NeAntikWorkspaceCommandsKey.self] = newValue }
    }
}

struct WorkspaceCommandMenu: Commands {
    @FocusedValue(\.neAntikWorkspaceCommands)
    private var commands

    private var resolved: WorkspaceCommandSet {
        commands ?? .unavailable
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новый профиль…", action: resolved.createProfile)
                .keyboardShortcut("n")
                .disabled(!resolved.isEnabled)

            Button("Новая папка…", action: resolved.createFolder)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!resolved.isEnabled)
        }

        CommandGroup(after: .textEditing) {
            Button("Найти профиль", action: resolved.focusProfileSearch)
                .keyboardShortcut("f")
                .disabled(!resolved.isEnabled)
        }

        CommandMenu("Папка") {
            Button(
                "Переименовать…",
                systemImage: "pencil",
                action: resolved.renameSelectedFolder
            )
            .disabled(
                !resolved.isEnabled || resolved.selectedFolderName == nil
            )

            Divider()

            Button(
                "Удалить папку",
                systemImage: "trash",
                role: .destructive,
                action: resolved.deleteSelectedFolder
            )
            .disabled(
                !resolved.isEnabled || resolved.selectedFolderName == nil
            )
        }
    }
}

struct ProfileCommandMenu: Commands {
    @FocusedValue(\.neAntikProfileCommands)
    private var commands

    private var resolved: ProfileCommandSet {
        commands ?? .unavailable
    }

    var body: some Commands {
        CommandMenu("Профиль") {
            Button(
                resolved.presentation.launchTitle,
                systemImage: resolved.presentation.launchSystemImage,
                action: resolved.toggleRunning
            )
            .disabled(!resolved.presentation.launchIsEnabled)

            Button(
                "Изменить…",
                systemImage: "pencil",
                action: resolved.edit
            )
            .disabled(!resolved.presentation.editIsEnabled)

            Divider()

            Button(
                resolved.presentation.pinTitle,
                systemImage: resolved.presentation.pinSystemImage,
                action: resolved.togglePinned
            )
            .disabled(!resolved.hasProfile)

            Button(
                "Создать похожий",
                systemImage: "plus.square.on.square",
                action: resolved.duplicate
            )
            .keyboardShortcut("d")
            .disabled(!resolved.hasProfile)

            Menu("Переместить в папку", systemImage: "folder") {
                ForEach(resolved.folderOptions) { option in
                    Button {
                        resolved.moveToFolder(option.folderID)
                    } label: {
                        Label(
                            option.title,
                            systemImage:
                                option.isSelected
                                    ? "checkmark"
                                    : (option.folderID == nil
                                        ? "tray"
                                        : "folder")
                        )
                    }
                }

                if resolved.hasMoreFolderOptions {
                    Divider()
                    Button(
                        "Выбрать другую папку…",
                        systemImage: "magnifyingglass",
                        action: resolved.chooseFolder
                    )
                }
            }
            .disabled(!resolved.hasProfile)

            Button(
                resolved.presentation.archiveTitle,
                systemImage: resolved.presentation.archiveSystemImage,
                action: resolved.toggleArchived
            )
            .disabled(!resolved.presentation.archiveIsEnabled)

            Divider()

            Button(
                "Показать папку данных в Finder",
                systemImage: "folder",
                action: resolved.revealInFinder
            )
            .disabled(!resolved.hasProfile)

            Divider()

            Button(
                "Удалить профиль",
                systemImage: "trash",
                role: .destructive,
                action: resolved.delete
            )
            .disabled(!resolved.presentation.deleteIsEnabled)
        }
    }
}
