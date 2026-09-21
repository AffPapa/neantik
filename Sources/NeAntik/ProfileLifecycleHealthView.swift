import SwiftUI

struct ProfileLifecycleHealthView: View {
    let snapshot: ProfileLifecycleHealthSnapshot

    var body: some View {
        GroupBox("Центр состояния") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Блокировка", value: snapshot.lock.title)
                LabeledContent("BrowserData", value: snapshot.browserData.title)
                LabeledContent("Восстановление", value: snapshot.recovery.title)
                LabeledContent(
                    "Последний запуск",
                    value: snapshot.lastLaunchedAt?.neAntikDisplayDateTime
                        ?? "Ещё не запускался"
                )
                Text(
                    "Показываются только агрегированные статусы. Пути, PID и служебные параметры не выводятся."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Центр состояния профиля")
    }
}
