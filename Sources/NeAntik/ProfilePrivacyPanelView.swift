import SwiftUI

struct ProfilePrivacyPanelView: View {
    let snapshot: ProfilePrivacyPanelSnapshot

    var body: some View {
        ProfileDetailCard(NSLocalizedString("page.653", tableName: "Pages", bundle: .main, value: "Медиа в тестовом окружении", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("page.654", tableName: "Pages", bundle: .main, value: "Результат временной проверки браузера. Разрешения сайтов рабочего профиля могут отличаться.", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(
                    NSLocalizedString("page.655", tableName: "Pages", bundle: .main, value: "Чтение списка устройств", comment: ""),
                    value: snapshot.mediaDevices.title
                )
                LabeledContent(
                    NSLocalizedString("page.656", tableName: "Pages", bundle: .main, value: "Устройств в списке", comment: ""),
                    value: snapshot.mediaDeviceCount.map(String.init)
                        ?? NSLocalizedString("page.657", tableName: "Pages", bundle: .main, value: "Не показывается", comment: "")
                )
                LabeledContent(
                    "Permissions API",
                    value: snapshot.permissionsAPI.title
                )
                LabeledContent(NSLocalizedString("page.658", tableName: "Pages", bundle: .main, value: "Камера", comment: ""), value: snapshot.camera.title)
                LabeledContent(
                    NSLocalizedString("page.659", tableName: "Pages", bundle: .main, value: "Микрофон", comment: ""),
                    value: snapshot.microphone.title
                )
                if let observedAt = snapshot.observedAt {
                    Text(
                        NSLocalizedString("page.660", tableName: "Pages", bundle: .main, value: "Последняя проверка: ", comment: "") +
                            observedAt.neAntikDisplayDateTime
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    NSLocalizedString("page.661", tableName: "Pages", bundle: .main, value: "Список устройств не доказывает, что камера или микрофон работают: для этого сайт запрашивает разрешение и открывает устройство. ID и названия устройств не сохраняются в отчёте.", comment: "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("page.662", tableName: "Pages", bundle: .main, value: "Медиа и разрешения временного тестового окружения", comment: ""))
    }
}
