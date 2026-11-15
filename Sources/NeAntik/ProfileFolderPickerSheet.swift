import Foundation
import SwiftUI

struct ProfileFolderPickerPresentation: Equatable, Sendable {
    let filteredFolders: [ProfileFolder]
    let returnFolderID: UUID?

    static func resolve(
        folders: [ProfileFolder],
        searchText: String
    ) -> Self {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let filteredFolders = folders.filter {
            query.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(query)
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

    let profileName: String
    let folders: [ProfileFolder]
    let selectedFolderID: UUID?
    let onSelect: (UUID?) -> Void

    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

    private var presentation: ProfileFolderPickerPresentation {
        ProfileFolderPickerPresentation.resolve(
            folders: folders,
            searchText: searchText
        )
    }

    var body: some View {
        let visibleFolders = presentation.filteredFolders
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("page.625", tableName: "Pages", bundle: .main, value: "Выбрать папку", comment: ""))
                    .font(.headline)
                    .accessibilityHeading(.h1)
                Text(String(format: NSLocalizedString("page.626", tableName: "Pages", bundle: .main, value: "Профиль «%@»", comment: ""), String(describing: profileName)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(spacing: 12) {
                TextField(NSLocalizedString("page.627", tableName: "Pages", bundle: .main, value: "Поиск папок", comment: ""), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchIsFocused)
                    .onSubmit(selectFirstSearchResult)
                    .accessibilityHint(
                        NSLocalizedString("page.628", tableName: "Pages", bundle: .main, value: "Фильтрует список папок по названию. ", comment: "") +
                            NSLocalizedString("page.629", tableName: "Pages", bundle: .main, value: "Return выбирает первый найденный результат.", comment: "")
                    )

                List {
                    folderButton(
                        title: NSLocalizedString("page.630", tableName: "Pages", bundle: .main, value: "Без папки", comment: ""),
                        systemImage: "tray",
                        folderID: nil
                    )

                    if visibleFolders.isEmpty, !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(visibleFolders) { folder in
                            folderButton(
                                title: folder.name,
                                systemImage: "folder",
                                folderID: folder.id
                            )
                        }
                    }
                }
                .listStyle(.inset)
            }
            .padding(16)

            Divider()

            HStack {
                Text(String(format: NSLocalizedString("page.631", tableName: "Pages", bundle: .main, value: "%@ из %@ папок", comment: ""), String(describing: visibleFolders.count), String(describing: folders.count)))
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

    private func selectFirstSearchResult() {
        guard let folderID = presentation.returnFolderID else { return }
        onSelect(folderID)
        dismiss()
    }

    private func folderButton(
        title: String,
        systemImage: String,
        folderID: UUID?
    ) -> some View {
        let isSelected = selectedFolderID == folderID
        return Button {
            onSelect(folderID)
            dismiss()
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelected ? String(format: NSLocalizedString("page.633", tableName: "Pages", bundle: .main, value: "%@, выбрано", comment: ""), String(describing: title)) : title
        )
        .accessibilityHint(NSLocalizedString("page.634", tableName: "Pages", bundle: .main, value: "Переместить профиль в эту папку", comment: ""))
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
                NSLocalizedString("page.635", tableName: "Pages", bundle: .main, value: "Профиль недоступен", comment: ""),
                systemImage: "exclamationmark.triangle",
                description: Text(
                    NSLocalizedString("page.636", tableName: "Pages", bundle: .main, value: "Профиль удалён или изменён в другом окне.", comment: "")
                )
            )
            Button(NSLocalizedString("page.637", tableName: "Pages", bundle: .main, value: "Закрыть", comment: ""), role: .cancel) {
                onClose()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityHint(NSLocalizedString("page.638", tableName: "Pages", bundle: .main, value: "Закрывает выбор папки", comment: ""))
        }
        .padding(24)
        .frame(width: 460, height: 280)
    }
}
