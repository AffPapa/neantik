import SwiftUI

/// The palette only projects current state; actions are supplied by the same
/// command sets as the native menus. It never owns a profile or launch state.
struct ProfileQuickCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let enabled: Bool
    let action: () -> Void
    var openAction: (() -> Void)? = nil
    var openEnabled: Bool = false
    var openTitle: String = NSLocalizedString("page.737", tableName: "Pages", bundle: .main, value: "Запустить профиль", comment: "")
}

struct ProfileQuickCommandsSheet: View {
    let commands: [ProfileQuickCommand]
    let profiles: [BrowserProfile]
    let organization: ProfileOrganizationState
    let profileCommand: (BrowserProfile) -> ProfileQuickCommand
    let performAction: (@escaping () -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isPerforming = false
    @State private var search = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private var matches: [ProfileQuickCommand] {
        let actions = commands.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
        return actions + ProfileQuickCommandProjection.matching(
            profiles, search: search, organization: organization
        )
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

    private func openSelectedProfile() {
        guard !isPerforming, let selected, selected.openEnabled,
              let action = selected.openAction else { return }
        isPerforming = true
        performAction(action)
    }

    private var openProfileButton: some View {
        Button(selected?.openTitle ?? NSLocalizedString("page.737", tableName: "Pages", bundle: .main, value: "Запустить профиль", comment: ""), action: openSelectedProfile)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(selected?.openEnabled != true)
            .help(NSLocalizedString("page.738", tableName: "Pages", bundle: .main, value: "⌘Return — запустить остановленный профиль или выбрать его в менеджере; Return — только выбрать в менеджере", comment: ""))
    }

    private func moveSelection(by offset: Int) {
        let items = matches
        guard !items.isEmpty else { return }
        let current = items.firstIndex(where: { $0.id == selection }) ?? 0
        selection = items[min(max(current + offset, 0), items.count - 1)].id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("page.739", tableName: "Pages", bundle: .main, value: "Быстрые команды", comment: "")).font(.title2.bold())
            TextField(NSLocalizedString("page.740", tableName: "Pages", bundle: .main, value: "Команда, профиль, тег, заметка или папка", comment: ""), text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(perform)
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
            List(matches, selection: $selection) { command in
                VStack(alignment: .leading) {
                    Text(command.title)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(command.title)
                    Text(command.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(command.subtitle)
                }
                .opacity(command.enabled ? 1 : 0.5)
                .tag(command.id)
            }
            .overlay { if matches.isEmpty { Text(NSLocalizedString("page.741", tableName: "Pages", bundle: .main, value: "Ничего не найдено. Измени запрос.", comment: "")).foregroundStyle(.secondary) } }
            ViewThatFits(in: .horizontal) {
                footer
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("page.742", tableName: "Pages", bundle: .main, value: "↑ ↓ — выбор • Return — выполнить", comment: "")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        openProfileButton
                        Button(NSLocalizedString("page.637", tableName: "Pages", bundle: .main, value: "Закрыть", comment: ""), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                        Button(NSLocalizedString("page.743", tableName: "Pages", bundle: .main, value: "Выполнить", comment: ""), action: perform).keyboardShortcut(.defaultAction)
                            .disabled(selected?.enabled != true)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 620, maxWidth: 800,
               minHeight: 360, idealHeight: 480, maxHeight: 640)
        .onAppear { searchFocused = true; selection = matches.first?.id }
        .onChange(of: search) { _, _ in selection = matches.first?.id }
    }

    private var footer: some View {
        HStack {
            Text(NSLocalizedString("page.742", tableName: "Pages", bundle: .main, value: "↑ ↓ — выбор • Return — выполнить", comment: "")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            openProfileButton
            Button(NSLocalizedString("page.637", tableName: "Pages", bundle: .main, value: "Закрыть", comment: ""), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(NSLocalizedString("page.743", tableName: "Pages", bundle: .main, value: "Выполнить", comment: ""), action: perform).keyboardShortcut(.defaultAction)
                .disabled(selected?.enabled != true)
        }
    }
}

enum ProfileQuickCommandProjection {
    static func matching(
        _ profiles: [BrowserProfile],
        search: String,
        organization: ProfileOrganizationState = .empty
    ) -> [BrowserProfile] {
        let query = ProfileSearchText.query(search)
        guard !query.isEmpty else { return Array(profiles.prefix(100)) }
        let folderNames = Dictionary(uniqueKeysWithValues:
            organization.folders.map { ($0.id, ProfileSearchText.fold($0.name)) })
        return Array(profiles.lazy.filter { profile in
            if ProfileSearchText.document(
                profileValues: [profile.name] + profile.tags + [profile.note]
            ).contains(query) { return true }
            guard let folderID = organization.folderID(forProfileID: profile.id),
                  let folderName = folderNames[folderID]
            else { return false }
            return folderName.contains(query)
        }.prefix(100))
    }
}
