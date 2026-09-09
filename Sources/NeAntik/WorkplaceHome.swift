import Foundation
import SwiftUI

/// A view of existing profiles, never another profile store. No browser data or
/// credentials are inspected to build the home screen.
struct WorkplaceHomeProjection: Equatable, Sendable {
    let profiles: [BrowserProfile]
    let matchCount: Int

    static func resolve(
        profiles: [BrowserProfile], search: String, limit: Int = 24
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
        return Self(
            profiles: Array(matches.prefix(max(0, limit))),
            matchCount: matches.count
        )
    }
}

struct WorkplaceOpenPresentation: Equatable, Sendable {
    enum Action: Equatable, Sendable { case launch, activate, cancel, unavailable }
    let action: Action
    let title: String
    let detail: String
    let systemImage: String

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
                    (state == .stopped ? "arrow.up.right" : presentation.systemImage)
            )
        }
    }
}

struct WorkplaceHomeView: View {
    let projection: WorkplaceHomeProjection
    @Binding var search: String
    let searchFocus: FocusState<Bool>.Binding
    let presentation: (BrowserProfile) -> WorkplaceOpenPresentation
    let onOpen: (BrowserProfile) -> Void
    let onInspect: (BrowserProfile) -> Void
    let onCreate: () -> Void
    let onCatalog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Рабочие места").font(.largeTitle.bold())
                    Text("У каждого дела — свой интернет")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Создать…", systemImage: "plus", action: onCreate)
            }
            TextField("Найти рабочее место, тег или заметку", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused(searchFocus)
                .accessibilityLabel("Поиск рабочих мест")
                .onSubmit {
                    if projection.matchCount == 1, let profile = projection.profiles.first {
                        onOpen(profile)
                    }
                }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(projection.profiles) { profile in
                        workplaceRow(profile)
                        Divider()
                    }
                    if projection.matchCount == 0 {
                        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView("Нет активных рабочих мест",
                                systemImage: "square.grid.2x2",
                                description: Text("Создайте рабочее место или верните его из архива в каталоге."))
                        } else {
                            ContentUnavailableView.search(text: search)
                                .padding(.top, 24)
                        }
                    }
                    if projection.matchCount > projection.profiles.count {
                        Button("Все рабочие места (\(projection.matchCount))", action: onCatalog)
                            .padding(.top, 16)
                    }
                }
            }
            Text("Входы на сайты и данные сохраняются отдельно в каждом рабочем месте.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workplaceRow(_ profile: BrowserProfile) -> some View {
        let action = presentation(profile)
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
                Text(profile.proxy == nil ? "Прямое подключение" : "Через прокси")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action.title, systemImage: action.systemImage) { onOpen(profile) }
                .disabled(action.action == .unavailable)
                .help(action.detail)
                .accessibilityLabel("\(action.title): \(profile.name)")
                .accessibilityHint(action.detail)
            Button { onInspect(profile) } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Сведения и настройки: \(profile.name)")
            .help("Сведения и настройки рабочего места")
        }
        .padding(.vertical, 16)
    }
}
