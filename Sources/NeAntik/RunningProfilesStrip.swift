import SwiftUI

struct RunningProfilesStrip: View {
    let items: [BrowserProcessLifecycleItem]
    let onSelect: (UUID) -> Void
    let onFocus: (UUID) -> Void
    let onStop: (UUID) -> Void
    let onForceStop: (UUID) -> Void

    var body: some View {
        if !items.isEmpty {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityLabel("Запущенные и завершающиеся профили")
        }
    }
}
