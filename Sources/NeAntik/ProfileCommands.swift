import SwiftUI

struct ProfileCommandPresentation: Equatable, Sendable {
    let profileName: String?
    var openTitle = "Показать в менеджере"
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
    var extensionsIsEnabled = false

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

    static func openTitle(for state: BrowserProfileProcessState) -> String {
        state == .stopped ? "Запустить профиль" : "Показать в менеджере"
    }

    static func resolve(
        profile: BrowserProfile,
        processState: BrowserProfileProcessState,
        launchAction: BrowserLaunchActionPresentation
    ) -> Self {
        ProfileCommandPresentation(
            profileName: profile.name,
            openTitle: openTitle(for: processState),
            launchTitle: launchAction.title,
            launchSystemImage: launchAction.systemImage,
            launchHelp: launchAction.help,
            launchIsEnabled: launchAction.isEnabled,
            editIsEnabled: !processState.isRunning,
            pinTitle: profile.isPinned ? "Открепить" : "Закрепить",
            pinSystemImage: profile.isPinned ? "pin.slash" : "pin",
            archiveTitle:
                profile.isArchived ? "Вернуть из архива" : "В архив",
            archiveSystemImage:
                profile.isArchived
                    ? "arrow.uturn.backward"
                    : "archivebox",
            archiveIsEnabled: !processState.isRunning,
            deleteIsEnabled: !processState.isRunning,
            extensionsIsEnabled: processState == .stopped && !profile.isArchived && launchAction.isEnabled
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
    let openOrShow: () -> Void
    let toggleRunning: () -> Void
    let edit: () -> Void
    let togglePinned: () -> Void
    let duplicate: () -> Void
    let moveToFolder: (UUID?) -> Void
    let chooseFolder: () -> Void
    let toggleArchived: () -> Void
    let revealInFinder: () -> Void
    let delete: () -> Void
    var clearCache: () -> Void = {}
    var openExtensions: () -> Void = {}

    static let unavailable = ProfileCommandSet(
        presentation: .unavailable,
        folderOptions: [],
        hasMoreFolderOptions: false,
        openOrShow: {},
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
    let exportProfiles: () -> Void
    let exportSupportBundle: () -> Void
    let saveSnapshot: () -> Void
    let restoreSnapshot: () -> Void
    let importProfiles: () -> Void
    let importBookmarks: () -> Void
    let exportEncryptedProfiles: () -> Void
    let importEncryptedProfiles: () -> Void
    let canUndoMetadata: Bool
    let undoMetadata: () -> Void
    let showManagerLibrary: () -> Void
    let showQuickCommands: () -> Void
    let focusProfileSearch: () -> Void
    let renameSelectedFolder: () -> Void
    let deleteSelectedFolder: () -> Void

    static let unavailable = WorkspaceCommandSet(
        isEnabled: false,
        selectedFolderName: nil,
        createProfile: {},
        createFolder: {},
        exportProfiles: {},
        exportSupportBundle: {},
        saveSnapshot: {},
        restoreSnapshot: {},
        importProfiles: {},
        importBookmarks: {},
        exportEncryptedProfiles: {},
        importEncryptedProfiles: {},
        canUndoMetadata: false,
        undoMetadata: {},
        showManagerLibrary: {},
        showQuickCommands: {},
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
            Button("Быстрые команды…", action: resolved.showQuickCommands)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!resolved.isEnabled)
            Button("Найти профиль", action: resolved.focusProfileSearch)
                .keyboardShortcut("f")
                .disabled(!resolved.isEnabled)
        }

        CommandMenu("Профили") {
            Button("Отменить изменение метаданных", action: resolved.undoMetadata)
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!resolved.isEnabled || !resolved.canUndoMetadata)

            Button("Шаблоны, фильтры и журнал…", action: resolved.showManagerLibrary)
                .disabled(!resolved.isEnabled)

            Button(
                "Экспортировать настройки профилей…",
                systemImage: "square.and.arrow.up",
                action: resolved.exportProfiles
            )
            .disabled(!resolved.isEnabled)
            .help("Сохранить настройки профилей в файл. BrowserData, cookies и пароли не входят.")

            Button(
                "Экспортировать безопасную диагностику…",
                systemImage: "stethoscope",
                action: resolved.exportSupportBundle
            )
            .disabled(!resolved.isEnabled)

            Button(
                "Сохранить локальный снимок настроек",
                systemImage: "clock.arrow.circlepath",
                action: resolved.saveSnapshot
            )
            .disabled(!resolved.isEnabled)
            .help("Снимок настроек остановленных профилей для создания новых профилей. Это не резервная копия BrowserData, cookies или паролей.")

            Button(
                "Создать профили из снимка настроек…",
                systemImage: "arrow.counterclockwise",
                action: resolved.restoreSnapshot
            )
            .disabled(!resolved.isEnabled)
            .help("Создать новые профили из снимка настроек. Данные сайтов и авторизация не восстановятся.")

            Button(
                "Импортировать настройки профилей…",
                systemImage: "square.and.arrow.down",
                action: resolved.importProfiles
            )
            .disabled(!resolved.isEnabled)
            .help("Импортировать настройки как новые профили без данных сайтов и паролей.")

            Button("Создать профиль из закладок…", systemImage: "bookmark", action: resolved.importBookmarks)
                .disabled(!resolved.isEnabled)
                .help("Перенести закладки HTML или Chromium JSON в новый профиль с новой identity. Cookies и пароли не импортируются.")

            Divider()

            Button(
                "Экспортировать зашифрованные настройки…",
                systemImage: "lock.doc",
                action: resolved.exportEncryptedProfiles
            )
            .disabled(!resolved.isEnabled)
            .help("Зашифровать настройки профилей. BrowserData, cookies и пароли прокси не входят.")

            Button(
                "Импортировать зашифрованные настройки…",
                systemImage: "lock.open",
                action: resolved.importEncryptedProfiles
            )
            .disabled(!resolved.isEnabled)
            .help("Создать новые профили из зашифрованного файла настроек без данных сайтов.")
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
            Button(resolved.presentation.openTitle, action: resolved.openOrShow)
                .disabled(!resolved.hasProfile)

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

            Button("Расширения профиля…", systemImage: "puzzlepiece.extension", action: resolved.openExtensions)
                .disabled(!resolved.presentation.extensionsIsEnabled)
                .help("Запустить выбранный профиль на странице управления расширениями Chromium")

            Divider()

            Button(
                resolved.presentation.pinTitle,
                systemImage: resolved.presentation.pinSystemImage,
                action: resolved.togglePinned
            )
            .disabled(!resolved.hasProfile)

            Button(
                "Копировать настройки",
                systemImage: "plus.square.on.square",
                action: resolved.duplicate
            )
            .keyboardShortcut("d")
            .disabled(!resolved.hasProfile)
            .help("Создать отдельный профиль из настроек; данные сайтов и заметка не копируются")

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

            Button("Очистить кэш…", systemImage: "arrow.triangle.2.circlepath", action: resolved.clearCache)
                .disabled(!resolved.presentation.editIsEnabled)
                .help("Посчитать и удалить HTTP Cache и Code Cache остановленного профиля, сохранив данные сайтов.")

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
