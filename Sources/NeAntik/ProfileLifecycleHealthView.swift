import SwiftUI

struct ProfileRecoveryWorkspaceNoticeView: View {
    let notice: ProfileRecoveryNotice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("page.604", tableName: "Pages", bundle: .main, value: "Метаданные восстановлены в текущем запуске", comment: ""))
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
        ProfileDetailCard(NSLocalizedString("page.605", tableName: "Pages", bundle: .main, value: "Центр состояния", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(NSLocalizedString("page.606", tableName: "Pages", bundle: .main, value: "Блокировка", comment: ""), value: snapshot.lock.title)
                LabeledContent("BrowserData", value: snapshot.browserData.title)
                LabeledContent(NSLocalizedString("page.607", tableName: "Pages", bundle: .main, value: "Восстановление", comment: ""), value: snapshot.recovery.title)
                LabeledContent(
                    NSLocalizedString("page.608", tableName: "Pages", bundle: .main, value: "Последний запуск", comment: ""),
                    value: snapshot.lastLaunchedAt?.neAntikDisplayDateTime
                        ?? NSLocalizedString("page.609", tableName: "Pages", bundle: .main, value: "Ещё не запускался", comment: "")
                )
                if let recoveryNotice {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(NSLocalizedString("page.610", tableName: "Pages", bundle: .main, value: "Метаданные восстановлены", comment: ""))
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
                    NSLocalizedString("page.611", tableName: "Pages", bundle: .main, value: "Показываются только агрегированные статусы. Пути, PID и служебные параметры не выводятся.", comment: "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("page.612", tableName: "Pages", bundle: .main, value: "Центр состояния профиля", comment: ""))
    }
}
