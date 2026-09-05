import Foundation
import SwiftUI

enum ProfileFolderPickerRowID: Hashable, Sendable {
    case unfiled
    case folder(UUID)
}

struct ProfileFolderPickerCommitState {
    private(set) var errorMessage: String?

    mutating func commit(
        folderID: UUID?,
        using action: (UUID?) throws -> Void
    ) -> Bool {
        do {
            try action(folderID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

enum ProfileFolderPickerKeyboardCommitPolicy {
    static func permitsCommit(
        searchText: String,
        didMoveHighlight: Bool
    ) -> Bool {
        didMoveHighlight ||
            !searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }
}

struct ProfileFolderPickerPresentation: Equatable, Sendable {
    let filteredFolders: [ProfileFolder]
    let returnFolderID: UUID?

    var rowIDs: [ProfileFolderPickerRowID] {
        [.unfiled] + filteredFolders.map { .folder($0.id) }
    }

    func movedHighlight(
        from current: ProfileFolderPickerRowID?,
        offset: Int
    ) -> ProfileFolderPickerRowID? {
        guard !rowIDs.isEmpty else { return nil }
        guard let current,
              let index = rowIDs.firstIndex(of: current)
        else { return offset < 0 ? rowIDs.last : rowIDs.first }
        return rowIDs[min(max(index + offset, 0), rowIDs.count - 1)]
    }

    static func resolve(
        folders: [ProfileFolder],
        searchText: String
    ) -> Self {
        let query = ProfileFolder.comparisonKey(searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ))
        let filteredFolders = folders.filter {
            query.isEmpty ||
                ProfileFolder.comparisonKey($0.name).contains(query)
        }
        return Self(
            filteredFolders: filteredFolders,
            // Return with an empty query must not move a profile by accident.
            returnFolderID: query.isEmpty ? nil : filteredFolders.first?.id
        )
    }
}

struct ProfileFolderPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selectionDescription: String
    let folders: [ProfileFolder]
    let selectedFolderID: UUID?
    let hasMixedSelection: Bool
    let onSelect: (UUID?) throws -> Void

    @State private var commitState = ProfileFolderPickerCommitState()
    @State private var searchText = ""
    @State private var highlightedRowID: ProfileFolderPickerRowID?
    @State private var didMoveKeyboardHighlight = false
    @FocusState private var searchIsFocused: Bool

    private var presentation: ProfileFolderPickerPresentation {
        ProfileFolderPickerPresentation.resolve(
            folders: folders,
            searchText: searchText
        )
    }

    init(
        profileName: String,
        folders: [ProfileFolder],
        selectedFolderID: UUID?,
        onSelect: @escaping (UUID?) throws -> Void
    ) {
        selectionDescription = "Профиль «\(profileName)»"
        self.folders = folders
        self.selectedFolderID = selectedFolderID
        hasMixedSelection = false
        self.onSelect = onSelect
    }

    init(
        selectionDescription: String,
        folders: [ProfileFolder],
        selectedFolderID: UUID?,
        hasMixedSelection: Bool = false,
        onSelect: @escaping (UUID?) throws -> Void
    ) {
        self.selectionDescription = selectionDescription
        self.folders = folders
        self.selectedFolderID = selectedFolderID
        self.hasMixedSelection = hasMixedSelection
        self.onSelect = onSelect
    }

    var body: some View {
        let visibleFolders = presentation.filteredFolders
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Выбрать папку")
                    .font(.headline)
                    .accessibilityHeading(.h1)
                Text(selectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if hasMixedSelection {
                    Text("Текущие папки различаются")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(spacing: 12) {
                TextField("Поиск папок", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchIsFocused)
                    .onSubmit(selectFirstSearchResult)
                    .onKeyPress(.upArrow) {
                        moveHighlight(offset: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveHighlight(offset: 1)
                        return .handled
                    }
                    .accessibilityHint(
                        "Фильтрует список папок по названию. " +
                            "Return выбирает найденную или выделенную стрелками папку."
                    )

                ScrollViewReader { scrollProxy in
                    List {
                        folderButton(
                            title: "Без папки",
                            systemImage: "tray",
                            folderID: nil,
                            rowID: .unfiled
                        )

                        if visibleFolders.isEmpty, !searchText.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(visibleFolders) { folder in
                                folderButton(
                                    title: folder.name,
                                    systemImage: "folder",
                                    folderID: folder.id,
                                    rowID: .folder(folder.id)
                                )
                            }
                        }
                    }
                    .listStyle(.inset)
                    .onChange(of: highlightedRowID) { _, rowID in
                        if let rowID {
                            scrollProxy.scrollTo(rowID)
                        }
                    }
                }
                if let errorMessage = commitState.errorMessage {
                    UserNoticeLabel(notice: UserNotice(errorMessage, level: .failure))
                }
            }
            .padding(16)

            Divider()

            HStack {
                Text("\(visibleFolders.count) из \(folders.count) папок")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 500)
        .onAppear {
            didMoveKeyboardHighlight = false
            highlightedRowID = selectedFolderID.map {
                .folder($0)
            } ?? .unfiled
            Task { @MainActor in
                await Task.yield()
                searchIsFocused = true
            }
        }
        .onChange(of: searchText) { _, _ in
            didMoveKeyboardHighlight = false
            if searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                highlightedRowID = selectedFolderID.map {
                    .folder($0)
                } ?? .unfiled
            } else {
                highlightedRowID = presentation.filteredFolders.first.map {
                    .folder($0.id)
                }
            }
        }
    }

    private func selectFirstSearchResult() {
        guard ProfileFolderPickerKeyboardCommitPolicy.permitsCommit(
            searchText: searchText,
            didMoveHighlight: didMoveKeyboardHighlight
        ) else { return }
        switch highlightedRowID {
        case .unfiled:
            selectFolder(nil)
        case let .folder(folderID):
            selectFolder(folderID)
        case nil:
            guard let folderID = presentation.returnFolderID else { return }
            selectFolder(folderID)
        }
    }

    private func selectFolder(_ folderID: UUID?) {
        if commitState.commit(folderID: folderID, using: onSelect) {
            dismiss()
        }
    }

    private func moveHighlight(offset: Int) {
        didMoveKeyboardHighlight = true
        highlightedRowID = presentation.movedHighlight(
            from: highlightedRowID,
            offset: offset
        )
    }

    private func folderButton(
        title: String,
        systemImage: String,
        folderID: UUID?,
        rowID: ProfileFolderPickerRowID
    ) -> some View {
        let isSelected = !hasMixedSelection && selectedFolderID == folderID
        let isHighlighted = highlightedRowID == rowID
        return Button {
            selectFolder(folderID)
        } label: {
            HStack(spacing: 10) {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .id(rowID)
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelected ? "\(title), выбрано" : title
        )
        .accessibilityValue(
            isHighlighted ? "Выделено клавиатурой" : ""
        )
        .accessibilityHint("Выбрать эту папку")
    }
}

struct ProfileFolderPickerUnavailableSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onClose: () -> Void

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Профиль недоступен",
                systemImage: "exclamationmark.triangle",
                description: Text(
                    "Профиль удалён или изменён в другом окне."
                )
            )
            Button("Закрыть", role: .cancel) {
                onClose()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("Закрывает выбор папки")
        }
        .padding(24)
        .frame(width: 460, height: 280)
    }
}
