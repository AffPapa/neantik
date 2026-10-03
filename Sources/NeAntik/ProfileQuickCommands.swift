import SwiftUI

/// The palette only projects current state; actions are supplied by the same
/// command sets as the native menus. It never owns a profile or launch state.
struct ProfileQuickCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let enabled: Bool
    let action: () -> Void
}

struct ProfileQuickCommandsSheet: View {
    let commands: [ProfileQuickCommand]
    let profiles: [BrowserProfile]
    let profileCommand: (BrowserProfile) -> ProfileQuickCommand
    let performAction: (@escaping () -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isPerforming = false
    @State private var search = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private var matches: [ProfileQuickCommand] {
        let actions = commands.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
        return actions + ProfileQuickCommandProjection.matching(profiles, search: search)
            .map(profileCommand)
    }
    private var selected: ProfileQuickCommand? {
        matches.first(where: { $0.id == selection }) ?? matches.first
    }
    private func perform() {
        guard !isPerforming, let selected, selected.enabled else { return }
        isPerforming = true
        performAction(selected.action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Быстрые команды").font(.title2.bold())
            TextField("Имя профиля или команда", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(perform)
                .onMoveCommand { direction in
                    let items = matches
                    guard !items.isEmpty else { return }
                    let current = items.firstIndex(where: { $0.id == selection }) ?? 0
                    if direction == .down { selection = items[min(current + 1, items.count - 1)].id }
                    if direction == .up { selection = items[max(current - 1, 0)].id }
                }
            List(matches, selection: $selection) { command in
                VStack(alignment: .leading) {
                    Text(command.title).lineLimit(1)
                    Text(command.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .opacity(command.enabled ? 1 : 0.5)
                .tag(command.id)
            }
            .overlay { if matches.isEmpty { Text("Ничего не найдено. Измени запрос.").foregroundStyle(.secondary) } }
            HStack {
                Text("↑ ↓ — выбор • Return — выполнить").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Выполнить", action: perform).keyboardShortcut(.defaultAction)
                    .disabled(selected?.enabled != true)
            }
        }
        .padding(20).frame(width: 580, height: 460)
        .onAppear { searchFocused = true; selection = matches.first?.id }
        .onChange(of: search) { _, _ in selection = matches.first?.id }
    }
}

enum ProfileQuickCommandProjection {
    static func matching(_ profiles: [BrowserProfile], search: String) -> [BrowserProfile] {
        Array(profiles.lazy.filter { search.isEmpty || $0.name.localizedStandardContains(search) }.prefix(100))
    }
}
