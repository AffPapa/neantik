import SwiftUI

struct RunningProfilesTimelineStrip: View {
    let itemProvider: (Date) -> [BrowserProcessLifecycleItem]
    let onSelect: (UUID) -> Void
    let onFocus: (UUID) -> Void
    let onStop: (UUID) -> Void
    let onForceStop: (UUID) -> Void
    let onRequestStopAll: ([UUID]) -> Void

    @ViewBuilder
    var body: some View {
        if BrowserProcessLifecycleProjection.requiresPeriodicRefresh(
            for: itemProvider(Date())
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RunningProfilesStrip(
                    items: itemProvider(context.date),
                    onSelect: onSelect,
                    onFocus: onFocus,
                    onStop: onStop,
                    onForceStop: onForceStop,
                    onRequestStopAll: onRequestStopAll
                )
            }
        }
    }
}

struct RunningProfilesStrip: View {
    @State private var stopAllRequest: BrowserProcessStopAllPresentation?

    let items: [BrowserProcessLifecycleItem]
    let onSelect: (UUID) -> Void
    let onFocus: (UUID) -> Void
    let onStop: (UUID) -> Void
    let onForceStop: (UUID) -> Void
    var onRequestStopAll: ([UUID]) -> Void = { _ in }

    var body: some View {
        if !items.isEmpty {
            let stopAll = BrowserProcessStopAllPresentation.resolve(
                items: items
            )
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.systemImage)
                                    .accessibilityHidden(true)
                                Button(item.profileName) {
                                    onSelect(item.id)
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.semibold))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.stateTitle)
                                        .font(.caption2.weight(.medium))
                                    Text(item.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if item.canFocus {
                                    Button {
                                        onFocus(item.id)
                                    } label: {
                                        Image(systemName: "macwindow.on.rectangle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Показать окно браузера")
                                    .accessibilityLabel(
                                        "Показать окно профиля \(item.profileName)"
                                    )
                                }
                                if item.canStop {
                                    Button {
                                        onStop(item.id)
                                    } label: {
                                        Image(systemName: "stop.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Остановить безопасно")
                                    .accessibilityLabel(
                                        "Остановить профиль \(item.profileName)"
                                    )
                                }
                                if item.canForceStop {
                                    Button(role: .destructive) {
                                        onForceStop(item.id)
                                    } label: {
                                        Label(
                                            "Завершить принудительно…",
                                            systemImage: "bolt.trianglebadge.exclamationmark.fill"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.red)
                                    .help("Принудительно остановить с риском потери сессии")
                                    .accessibilityLabel(
                                        "Принудительно остановить профиль \(item.profileName)"
                                    )
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 42)
                            .background(
                                Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 7)
                }

                if stopAll.shouldOfferAction {
                    Button {
                        stopAllRequest = stopAll
                    } label: {
                        Label(
                            "Остановить все…",
                            systemImage: "stop.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help(
                        "Обычная остановка \(stopAll.eligibleCount) профилей; без принудительного завершения"
                    )
                    .accessibilityLabel(
                        "Остановить обычным способом все доступные профили: \(stopAll.eligibleCount)"
                    )
                    .padding(.trailing, 12)
                }
            }
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityLabel("Запущенные и завершающиеся профили")
            .alert(
                "Остановить доступные профили?",
                isPresented: Binding(
                    get: { stopAllRequest != nil },
                    set: { if !$0 { stopAllRequest = nil } }
                ),
                presenting: stopAllRequest
            ) { request in
                Button("Остановить \(request.eligibleCount)") {
                    onRequestStopAll(request.eligibleProfileIDs)
                    stopAllRequest = nil
                }
                Button("Отмена", role: .cancel) {
                    stopAllRequest = nil
                }
            } message: { request in
                Text(request.confirmationMessage)
            }
        }
    }
}
