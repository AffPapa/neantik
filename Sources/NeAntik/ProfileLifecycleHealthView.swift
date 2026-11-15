import SwiftUI

/// Translate status text only at the presentation boundary; diagnostic models
/// retain their stable source values for existing comparisons and persistence.
func localizedProfileStatus(_ value: String) -> String {
    NSLocalizedString(value, tableName: "Status", bundle: .main, value: value, comment: "Profile status")
}

struct ProfileRecoveryWorkspaceNoticeView: View {
    let notice: ProfileRecoveryNotice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("page.604", tableName: "Pages", bundle: .main, value: "Метаданные восстановлены в текущем запуске", comment: ""))
                    .font(.subheadline.weight(.medium))
                Text(verbatim: localizedProfileStatus(notice.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "arrow.counterclockwise.circle")
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: localizedProfileStatus("Восстановление метаданных в текущем запуске. %@"), localizedProfileStatus(notice.detail)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary)
    }
}

struct ProfileLifecycleHealthView: View {
    let snapshot: ProfileLifecycleHealthSnapshot
    var recoveryNotice: ProfileRecoveryNotice? = nil

    private var browserDataTitle: String {
        if case let .available(bytes, entries) = snapshot.browserData {
            return String(format: localizedProfileStatus("%@ · %ld объектов"),
                          ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), entries)
        }
        return localizedProfileStatus(snapshot.browserData.title)
    }

    var body: some View {
        ProfileDetailCard(NSLocalizedString("page.605", tableName: "Pages", bundle: .main, value: "Центр состояния", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(NSLocalizedString("page.606", tableName: "Pages", bundle: .main, value: "Блокировка", comment: ""), value: localizedProfileStatus(snapshot.lock.title))
                LabeledContent("BrowserData", value: browserDataTitle)
                LabeledContent(NSLocalizedString("page.607", tableName: "Pages", bundle: .main, value: "Восстановление", comment: ""), value: localizedProfileStatus(snapshot.recovery.title))
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
                            Text(verbatim: localizedProfileStatus(recoveryNotice.detail))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(format: localizedProfileStatus("Восстановление метаданных в текущем запуске. %@"), localizedProfileStatus(recoveryNotice.detail)))
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
