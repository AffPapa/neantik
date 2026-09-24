import SwiftUI

struct ProfileRecoveryWorkspaceNoticeView: View {
    let notice: ProfileRecoveryNotice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Метаданные восстановлены в текущем запуске")
                    .font(.subheadline.weight(.medium))
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "arrow.counterclockwise.circle")
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.accessibilityLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary)
    }
}

struct ProfileLifecycleHealthView: View {
    let snapshot: ProfileLifecycleHealthSnapshot
    var recoveryNotice: ProfileRecoveryNotice? = nil

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
                if let recoveryNotice {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Метаданные восстановлены")
                                .font(.subheadline.weight(.medium))
                            Text(recoveryNotice.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(recoveryNotice.accessibilityLabel)
                }
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
