import SwiftUI

/// A small, keyboard-first surface for actions that are otherwise distributed
/// across the toolbar and contextual menus. It deliberately renders the same
/// command vocabulary as `WorkspaceCommand`, so labels and search terms cannot
/// drift from the action model.
struct WorkspaceCommandPalette: View {
    let isEnabled: Bool
    let action: (WorkspaceCommand) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var commands: [WorkspaceCommand] {
        guard isEnabled else { return [] }
        return WorkspaceCommand.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Найти действие…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { runFirstCommand() }
                Button("Отмена", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
            }
            .padding(14)

            Divider()

            if commands.isEmpty {
                ContentUnavailableView("Ничего не найдено", systemImage: "magnifyingglass", description: Text("Попробуйте другое слово."))
                    .frame(minHeight: 140)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(commands) { command in
                            Button {
                                run(command)
                            } label: {
                                Label(command.title, systemImage: command.symbolName)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 430)
        .onAppear { isSearchFocused = true }
    }

    private func runFirstCommand() {
        guard let command = commands.first else { return }
        run(command)
    }

    private func run(_ command: WorkspaceCommand) {
        dismiss()
        // Let the sheet finish dismissing before opening another sheet or
        // changing focus. This avoids SwiftUI's "already presenting" race.
        DispatchQueue.main.async {
            action(command)
        }
    }
}

private extension WorkspaceCommand {
    var symbolName: String {
        switch self {
        case .newProfile: "plus"
        case .search: "magnifyingglass"
        case .reopenLast: "arrow.uturn.left"
        case .cleanLaunch: "sparkles"
        case .duplicate: "plus.square.on.square"
        case .inspectFingerprint: "checkmark.shield"
        }
    }
}
