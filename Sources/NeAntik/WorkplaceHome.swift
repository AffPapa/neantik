import Foundation
import SwiftUI

/// A view of existing profiles, never another profile store. No browser data or
/// credentials are inspected to build the home screen.
struct WorkplaceHomeProjection: Equatable, Sendable {
    let profiles: [BrowserProfile]
    let matchCount: Int

    static func resolve(
        profiles: [BrowserProfile],
        search: String,
        limit: Int = 24,
        revealProfileID: UUID? = nil
    ) -> Self {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = profiles.filter { profile in
            !profile.isArchived && (query.isEmpty ||
                ([profile.name, profile.note] + profile.tags).contains {
                    $0.localizedStandardContains(query)
                })
        }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            let left = lhs.lastLaunchedAt ?? lhs.createdAt
            let right = rhs.lastLaunchedAt ?? rhs.createdAt
            if left != right { return left > right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let effectiveLimit = max(0, limit)
        var visibleProfiles = Array(matches.prefix(effectiveLimit))

        // A newly created workplace must be visible immediately, even when a
        // full Home list is headed by pinned workplaces. This is presentation
        // only: it never changes pinning or the stored ordering.
        if effectiveLimit > 0,
           let revealProfileID,
           let revealedProfile = matches.first(where: { $0.id == revealProfileID }),
           !visibleProfiles.contains(where: { $0.id == revealProfileID })
        {
            if visibleProfiles.isEmpty {
                visibleProfiles = [revealedProfile]
            } else {
                visibleProfiles[visibleProfiles.index(before: visibleProfiles.endIndex)] = revealedProfile
            }
        }

        return Self(profiles: visibleProfiles, matchCount: matches.count)
    }
}

struct WorkplaceOpenPresentation: Equatable, Sendable {
    enum Action: Equatable, Sendable { case launch, activate, cancel, unavailable }
    let action: Action
    let title: String
    let detail: String
    let systemImage: String
    var showsInlineDetail = true

    static func resolve(
        state: BrowserProfileProcessState,
        archived: Bool,
        runtime: BrowserRuntimeAvailability,
        preparing: Bool = false,
        testing: Bool = false
    ) -> Self {
        guard !archived else {
            return Self(action: .unavailable, title: "В архиве",
                        detail: "Верни рабочее место из архива", systemImage: "archivebox")
        }
        switch state {
        case .managed, .externalVerified, .externalManualOnly:
            return Self(action: .activate, title: "Продолжить",
                        detail: "Перейти в открытый браузер этого рабочего места",
                        systemImage: "arrow.up.forward.app")
        default:
            let presentation = BrowserLaunchActionPresentation.resolve(
                processState: state, isArchived: archived,
                runtimeAvailability: runtime, isProxyTesting: testing,
                isLaunchPreparation: preparing
            )
            return Self(
                action: preparing ? .cancel :
                    (presentation.isEnabled && state == .stopped ? .launch : .unavailable),
                title: preparing ? "Отменить" :
                    (state == .stopped && !testing ? "Открыть" : presentation.title),
                detail: presentation.help,
                systemImage: preparing ? "xmark" :
                    (state == .stopped ? "arrow.up.right" : presentation.systemImage),
                showsInlineDetail: state != .stopped || runtime == .ready
            )
        }
    }
}

struct WorkplaceHomeView: View {
    let projection: WorkplaceHomeProjection
    let revealProfileID: UUID?
    let isFirstRun: Bool
    let runtimeAvailability: BrowserRuntimeAvailability
    let isCreatingProfile: Bool
    @Binding var search: String
    let searchFocus: FocusState<Bool>.Binding
    let presentation: (BrowserProfile) -> WorkplaceOpenPresentation
    let onOpen: (BrowserProfile) -> Void
    let onInspect: (BrowserProfile) -> Void
    let onCreate: () -> Void
    let onCatalog: () -> Void
    let profileCommands: (BrowserProfile) -> ProfileCommandSet
    let canStop: (BrowserProfile) -> Bool
    let onCreateAndOpen: () -> Void
    let onRetryRuntimeCheck: () -> Void
    let onArchive: () -> Void
    var notice: (BrowserProfile) -> String? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Рабочие места").font(.largeTitle.bold())
                    Text("У каждого дела — свой интернет")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isFirstRun {
                    Button("Создать…", systemImage: "plus", action: onCreate)
                }
            }
            if isFirstRun {
                FirstProfileOnboardingView(
                    runtimeAvailability: runtimeAvailability,
                    isCreatingProfile: isCreatingProfile,
                    onCreateAndOpen: onCreateAndOpen,
                    onRetryRuntimeCheck: onRetryRuntimeCheck,
                    onConfigure: onCreate
                )
            } else {
                HStack(spacing: 8) {
                    TextField("Найти рабочее место, тег или заметку", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .focused(searchFocus)
                        .accessibilityLabel("Поиск рабочих мест")
                        .onExitCommand {
                            if search.isEmpty {
                                searchFocus.wrappedValue = false
                            } else {
                                clearSearch()
                            }
                        }
                        .onSubmit {
                            if projection.matchCount == 1, let profile = projection.profiles.first {
                                onOpen(profile)
                            }
                        }
                    if !search.isEmpty {
                        Button(action: clearSearch) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Очистить поиск рабочих мест")
                        .help("Очистить поиск")
                    }
                }
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                        ForEach(projection.profiles) { profile in
                            workplaceRow(profile)
                                .id(profile.id)
                            Divider()
                        }
                        if projection.matchCount == 0 {
                            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ContentUnavailableView("Нет активных рабочих мест",
                                    systemImage: "square.grid.2x2",
                                    description: Text("Рабочие места в архиве сохраняют ваши данные. Их можно вернуть и продолжить работу."))
                                Button("Открыть архив", systemImage: "archivebox", action: onArchive)
                            } else {
                                ContentUnavailableView("Ничего не найдено",
                                    systemImage: "magnifyingglass",
                                    description: Text("Попробуй другое название, тег или слово из заметки."))
                                    .padding(.top, 24)
                                Button("Очистить поиск", action: clearSearch)
                            }
                        }
                        if projection.matchCount > projection.profiles.count {
                            Button("Все рабочие места (\(projection.matchCount))", action: onCatalog)
                                .padding(.top, 16)
                        }
                        }
                    }
                    .onAppear {
                        scrollToRevealedProfile(using: scrollProxy)
                    }
                    .onChange(of: revealProfileID) { _, _ in
                        scrollToRevealedProfile(using: scrollProxy)
                    }
                }
            }
            Text("Входы на сайты и данные сохраняются отдельно в каждом рабочем месте.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func clearSearch() {
        search = ""
        searchFocus.wrappedValue = true
    }

    private func scrollToRevealedProfile(using proxy: ScrollViewProxy) {
        guard let revealProfileID,
              projection.profiles.contains(where: { $0.id == revealProfileID })
        else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(revealProfileID, anchor: .center)
        }
    }

    private func workplaceRow(_ profile: BrowserProfile) -> some View {
        let action = presentation(profile)
        let commands = profileCommands(profile)
        return HStack(spacing: 14) {
            Image(systemName: ProfileAppearance.displaySymbol(profile.symbolName, profileID: profile.id))
                .font(.title2)
                .foregroundStyle(Color(hex: profile.colorHex))
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(profile.name).font(.headline).lineLimit(1)
                    if profile.isPinned {
                        Image(systemName: "pin.fill").font(.caption)
                            .accessibilityLabel("Закреплено")
                    }
                }
                if let message = notice(profile), !message.isEmpty {
                    Text(message)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if action.action == .unavailable && action.showsInlineDetail {
                    Text(action.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let note = profile.note.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !note.isEmpty {
                        Text(note).lineLimit(1)
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !profile.tags.isEmpty {
                        Text(profile.tags.joined(separator: " · ")).lineLimit(1)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if profile.proxy != nil {
                    Label("Через прокси", systemImage: "network")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(action.title, systemImage: action.systemImage) { onOpen(profile) }
                .disabled(action.action == .unavailable)
                .help(action.detail)
                .accessibilityLabel("\(action.title): \(profile.name)")
                .accessibilityHint(action.detail)
            Menu {
                Button(commands.presentation.pinTitle,
                       systemImage: commands.presentation.pinSystemImage,
                       action: commands.togglePinned)
                Button("Изменить…", systemImage: "pencil", action: commands.edit)
                    .disabled(!commands.presentation.editIsEnabled)
                Button("Сведения", systemImage: "info.circle") { onInspect(profile) }
                if canStop(profile) {
                    Divider()
                    Button("Остановить", systemImage: "stop.fill", action: commands.toggleRunning)
                        .disabled(!commands.presentation.launchIsEnabled)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Действия: \(profile.name)")
            .help("Действия с рабочим местом")
        }
        .padding(.vertical, 16)
    }
}
