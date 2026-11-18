import SwiftUI

struct ProfileFolderParentPickerPresentation: Equatable, Sendable {
    let eligibleFolders: [ProfileFolder]
    let pathByFolderID: [UUID: String]
    let selectedParentFolderID: UUID?
    let blockedParentFolderIDs: Set<UUID>
    let rootDestinationBlocked: Bool

    static func resolve(
        movingFolderID: UUID,
        organization: ProfileOrganizationState,
        searchText: String
    ) -> Self {
        let movingFolder = organization.folder(withID: movingFolderID)
        let foldersByID = Dictionary(uniqueKeysWithValues: organization.folders.map { ($0.id, $0) })
        var childIDsByParent: [UUID: [UUID]] = [:]
        for folder in organization.folders {
            if let parentID = folder.parentFolderID {
                childIDsByParent[parentID, default: []].append(folder.id)
            }
        }
        var excludedIDs: Set<UUID> = [movingFolderID]
        var pendingDescendants = childIDsByParent[movingFolderID] ?? []
        while let id = pendingDescendants.popLast() {
            guard excludedIDs.insert(id).inserted else { continue }
            pendingDescendants.append(contentsOf: childIDsByParent[id] ?? [])
        }
        let eligibleFolders = organization.folders.filter {
            !excludedIDs.contains($0.id)
        }
        var pathComponentsByFolderID: [UUID: [String]] = [:]
        for folder in eligibleFolders where pathComponentsByFolderID[folder.id] == nil {
            var chain: [ProfileFolder] = []
            var seen: Set<UUID> = []
            var cursor: ProfileFolder? = folder
            var hasCycle = false
            while let current = cursor, pathComponentsByFolderID[current.id] == nil {
                guard seen.insert(current.id).inserted else {
                    hasCycle = true
                    break
                }
                chain.append(current)
                cursor = current.parentFolderID.flatMap { foldersByID[$0] }
            }
            if hasCycle {
                pathComponentsByFolderID[folder.id] = [folder.name]
                continue
            }
            var components = cursor.flatMap { pathComponentsByFolderID[$0.id] } ?? []
            for item in chain.reversed() {
                components.append(item.name)
                pathComponentsByFolderID[item.id] = components
            }
        }
        let pathByFolderID = pathComponentsByFolderID.mapValues { $0.joined(separator: " › ") }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredFolders = eligibleFolders.filter {
            query.isEmpty || (pathByFolderID[$0.id] ?? $0.name)
                .localizedCaseInsensitiveContains(query)
        }
        var conflictingDestinationIDs: Set<UUID> = []
        if let movingFolder {
            let movingNameKey = ProfileFolder.comparisonKey(movingFolder.name)
            for sibling in organization.folders where
                sibling.id != movingFolderID &&
                ProfileFolder.comparisonKey(sibling.name) == movingNameKey {
                if let parentID = sibling.parentFolderID {
                    conflictingDestinationIDs.insert(parentID)
                }
            }
        }
        let blockedParentFolderIDs = Set(eligibleFolders.compactMap { folder in
            conflictingDestinationIDs.contains(folder.id) ? folder.id : nil
        })
        let rootDestinationBlocked = movingFolder.map { folder in
            organization.folders.contains {
                $0.id != folder.id && $0.parentFolderID == nil &&
                    ProfileFolder.comparisonKey($0.name) == ProfileFolder.comparisonKey(folder.name)
            }
        } ?? false

        return Self(
            eligibleFolders: filteredFolders,
            pathByFolderID: pathByFolderID,
            selectedParentFolderID: movingFolder?.parentFolderID,
            blockedParentFolderIDs: blockedParentFolderIDs,
            rootDestinationBlocked: rootDestinationBlocked
        )
    }
}

struct ProfileFolderParentPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let folderPath: String
    let folderID: UUID
    let organization: ProfileOrganizationState
    let onMove: (UUID?) throws -> Void

    @State private var searchText = ""
    @State private var errorMessage: String?
    @FocusState private var searchIsFocused: Bool

    private var presentation: ProfileFolderParentPickerPresentation {
        ProfileFolderParentPickerPresentation.resolve(
            movingFolderID: folderID,
            organization: organization,
            searchText: searchText
        )
    }

    var body: some View {
        let resolved = presentation
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("folder.move.title", value: "Переместить папку", comment: "Move folder heading"))
                    .font(.headline)
                    .accessibilityHeading(.h1)
                Text(String(format: NSLocalizedString("folder.move.subtitle", value: "Новая родительская папка для «%@»", comment: "Move folder subtitle"), folderPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(spacing: 12) {
                TextField(NSLocalizedString("folder.move.search", value: "Поиск по папкам", comment: "Search eligible parent folders"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchIsFocused)
                    .accessibilityHint(NSLocalizedString("folder.move.search.hint", value: "Ищет по полному пути. Текущая папка и её подпапки скрыты.", comment: "Search hint for folder parent picker"))

                List {
                    parentButton(
                        title: NSLocalizedString("folder.move.root", value: "Верхний уровень", comment: "Move folder to root"),
                        parentFolderID: nil,
                        selectedParentFolderID: resolved.selectedParentFolderID,
                        isBlocked: resolved.rootDestinationBlocked
                    )
                    if resolved.eligibleFolders.isEmpty, !searchText.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .listRowSeparator(.hidden)
                    } else {
                        ForEach(resolved.eligibleFolders) { folder in
                            parentButton(
                                title: resolved.pathByFolderID[folder.id] ?? folder.name,
                                parentFolderID: folder.id,
                                selectedParentFolderID: resolved.selectedParentFolderID,
                                isBlocked: resolved.blockedParentFolderIDs.contains(folder.id)
                            )
                        }
                    }
                }
                .listStyle(.inset)

                if resolved.rootDestinationBlocked || !resolved.blockedParentFolderIDs.isEmpty {
                    Text(NSLocalizedString("folder.move.conflict", value: "Недоступные места назначения уже содержат папку с таким именем.", comment: "Duplicate sibling names prevent moving a folder"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                }
            }
            .padding(16)

            Divider()

            HStack {
                Text(String(format: NSLocalizedString("folder.move.count", value: "Показано папок: %@", comment: "Number of destination folders shown"), String(resolved.eligibleFolders.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("page.632", tableName: "Pages", bundle: .main, value: "Отмена", comment: ""), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 500)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                searchIsFocused = true
            }
        }
    }

    private func parentButton(
        title: String,
        parentFolderID: UUID?,
        selectedParentFolderID: UUID?,
        isBlocked: Bool
    ) -> some View {
        let isSelected = selectedParentFolderID == parentFolderID
        return Button {
            do {
                try onMove(parentFolderID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        } label: {
            HStack(spacing: 10) {
                Label(title, systemImage: parentFolderID == nil ? "tray.full" : "folder")
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBlocked || isSelected)
        .accessibilityLabel(isSelected
            ? String(format: NSLocalizedString("folder.move.selected", value: "%@, выбрано", comment: "Selected move destination accessibility label"), title)
            : title)
        .accessibilityHint(NSLocalizedString("folder.move.select.hint", value: "Переместить сюда без изменения профилей и данных браузера", comment: "Move folder option hint"))
    }
}
