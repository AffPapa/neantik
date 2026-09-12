import Foundation
import SwiftUI

/// A transient, local-only way to narrow the Home list. It deliberately does
/// not become profile metadata or alter the Catalog's composable query state.
enum WorkplaceHomeQuickFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case running
    case attention
    case unfiled
    case untagged

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Все"
        case .running: "Запущено"
        case .attention: "Требуют внимания"
        case .unfiled: "Без папки"
        case .untagged: "Без тегов"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "rectangle.stack"
        case .running: "play.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .unfiled: "folder.badge.questionmark"
        case .untagged: "tag.slash"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "Нет активных рабочих мест"
        case .running: "Нет запущенных рабочих мест"
        case .attention: "Всё в порядке"
        case .unfiled: "Все рабочие места распределены по папкам"
        case .untagged: "У всех рабочих мест есть теги"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Рабочие места в архиве сохраняют ваши данные. Их можно вернуть и продолжить работу."
        case .running: "Открой рабочее место — оно появится здесь."
        case .attention: "Нет ошибок подключения и состояний, требующих действия."
        case .unfiled: "Новые рабочие места без папки появляются в этом списке."
        case .untagged: "Теги помогают быстрее находить рабочие места."
        }
    }
}

struct WorkplaceHomeSummary: Equatable, Sendable {
    let activeCount: Int
    let runningCount: Int
    let attentionCount: Int
    let unfiledCount: Int
    let untaggedCount: Int

    static let empty = Self(
        activeCount: 0,
        runningCount: 0,
        attentionCount: 0,
        unfiledCount: 0,
        untaggedCount: 0
    )

    func count(for filter: WorkplaceHomeQuickFilter) -> Int {
        switch filter {
        case .all: activeCount
        case .running: runningCount
        case .attention: attentionCount
        case .unfiled: unfiledCount
        case .untagged: untaggedCount
        }
    }
}

/// A view of existing profiles, never another profile store. No browser data or
/// credentials are inspected to build the home screen.
struct WorkplaceHomeProjection: Equatable, Sendable {
    let profiles: [BrowserProfile]
    let matchCount: Int
    let summary: WorkplaceHomeSummary
    private let matchesByQuickFilter: [WorkplaceHomeQuickFilter: [BrowserProfile]]

    init(
        profiles: [BrowserProfile],
        matchCount: Int,
        summary: WorkplaceHomeSummary = .empty,
        matchesByQuickFilter: [WorkplaceHomeQuickFilter: [BrowserProfile]] = [:]
    ) {
        self.profiles = profiles
        self.matchCount = matchCount
        self.summary = summary
        self.matchesByQuickFilter = matchesByQuickFilter.isEmpty
            ? [.all: profiles]
            : matchesByQuickFilter
    }

    static func resolve(
        profiles: [BrowserProfile],
        search: String,
        limit: Int = 24,
        revealProfileID: UUID? = nil,
        processState: (UUID) -> BrowserProfileProcessState = { _ in .stopped },
        proxyHealth: (BrowserProfile) -> ProxyHealthState? = { _ in nil },
        organization: ProfileOrganizationState = .empty
    ) -> Self {
        let index = WorkplaceHomeIndex(
            profiles: profiles,
            organization: organization
        )
        let operational = ProfileOperationalProjection.resolve(
            profiles: index.orderedActiveProfiles,
            processState: processState,
            proxyHealth: proxyHealth
        )
        return index.resolve(
            search: search,
            operational: operational,
            limit: limit,
            revealProfileID: revealProfileID
        )
    }

    func profiles(
        for quickFilter: WorkplaceHomeQuickFilter,
        limit: Int = 24,
        revealProfileID: UUID? = nil
    ) -> [BrowserProfile] {
        Self.visibleProfiles(
            matches: matchesByQuickFilter[quickFilter] ?? [],
            limit: limit,
            revealProfileID: revealProfileID
        )
    }

    func matchCount(for quickFilter: WorkplaceHomeQuickFilter) -> Int {
        (matchesByQuickFilter[quickFilter] ?? []).count
    }

    static func visibleProfiles(
        matches: [BrowserProfile],
        limit: Int,
        revealProfileID: UUID?
    ) -> [BrowserProfile] {
        let effectiveLimit = max(0, limit)
        var visibleProfiles = Array(matches.prefix(effectiveLimit))
        if effectiveLimit > 0,
           let revealProfileID,
           let revealed = matches.first(where: { $0.id == revealProfileID }),
           !visibleProfiles.contains(where: { $0.id == revealProfileID })
        {
            if visibleProfiles.isEmpty { visibleProfiles = [revealed] }
            else { visibleProfiles[visibleProfiles.index(before: visibleProfiles.endIndex)] = revealed }
        }
        return visibleProfiles
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
    @State private var quickFilter: WorkplaceHomeQuickFilter = .all

    var body: some View {
        let profiles = projection.profiles(
            for: quickFilter, revealProfileID: revealProfileID
        )
        let matchCount = projection.matchCount(for: quickFilter)
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
                            if matchCount == 1, let profile = profiles.first {
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
                quickFilterBar
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                        ForEach(profiles) { profile in
                            workplaceRow(profile)
                                .id(profile.id)
                            Divider()
                        }
                        if matchCount == 0 {
                            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ContentUnavailableView(
                                    quickFilter.emptyTitle,
                                    systemImage: quickFilter.systemImage,
                                    description: Text(quickFilter.emptyMessage)
                                )
                                if quickFilter == .all {
                                    Button("Открыть архив", systemImage: "archivebox", action: onArchive)
                                } else {
                                    Button("Показать все", action: { quickFilter = .all })
                                }
                            } else {
                                ContentUnavailableView("Ничего не найдено",
                                    systemImage: "magnifyingglass",
                                    description: Text("Попробуй другое название, тег или слово из заметки."))
                                    .padding(.top, 24)
                                Button("Очистить поиск", action: clearSearch)
                            }
                        }
                        if matchCount > profiles.count {
                            Button("Все рабочие места (\(matchCount))", action: onCatalog)
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

    @ViewBuilder
    private var quickFilterBar: some View {
        let filters = WorkplaceHomeQuickFilter.allCases.filter {
            $0 == .all || projection.summary.count(for: $0) > 0 || $0 == quickFilter
        }
        if filters.count > 1 || quickFilter != .all {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(filters) { filter in
                        quickFilterButton(filter)
                    }
                }
            }
            .accessibilityLabel("Состояние рабочих мест")
        }
    }

    private func quickFilterButton(
        _ filter: WorkplaceHomeQuickFilter
    ) -> some View {
        let selected = filter == quickFilter
        let count = projection.matchCount(for: filter)
        return Button {
            quickFilter = filter
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.systemImage)
                    .accessibilityHidden(true)
                Text(filter.title)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
            }
            .font(.caption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(
                (filter == .attention ? Color.orange : Color.accentColor)
                    .opacity(selected ? 0.18 : 0.07),
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(
                    selected
                        ? (filter == .attention ? Color.orange : Color.accentColor).opacity(0.55)
                        : Color.clear,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title): \(count)")
        .accessibilityValue(selected ? "Выбрано" : "Не выбрано")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func scrollToRevealedProfile(using proxy: ScrollViewProxy) {
        guard let revealProfileID,
              projection.profiles(
                  for: quickFilter,
                  revealProfileID: revealProfileID
              ).contains(where: { $0.id == revealProfileID })
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
                Menu("Папка", systemImage: "folder") {
                    ForEach(commands.folderOptions) { option in
                        Button {
                            commands.moveToFolder(option.folderID)
                        } label: {
                            Label(
                                option.title,
                                systemImage: option.isSelected
                                    ? "checkmark"
                                    : "folder"
                            )
                        }
                        .disabled(option.isSelected)
                    }
                    if commands.hasMoreFolderOptions {
                        Divider()
                        Button("Выбрать папку…", action: commands.chooseFolder)
                    }
                }
                Button("Теги…", systemImage: "tag", action: commands.editTags)
                    .disabled(!commands.presentation.editIsEnabled)
                Button("Создать похожее", systemImage: "plus.square.on.square", action: commands.duplicate)
                    .disabled(!commands.presentation.editIsEnabled)
                Button("Изменить…", systemImage: "pencil", action: commands.edit)
                    .disabled(!commands.presentation.editIsEnabled)
                Button("Сведения", systemImage: "info.circle") { onInspect(profile) }
                if canStop(profile) {
                    Divider()
                    Button("Остановить", systemImage: "stop.fill", action: commands.toggleRunning)
                        .disabled(!commands.presentation.launchIsEnabled)
                }
                Button("Чистый запуск", systemImage: "sparkles", action: commands.cleanLaunch)
                    .disabled(!commands.presentation.launchIsEnabled)
                    .help("Открыть без сохранённых вкладок и временных данных")
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
