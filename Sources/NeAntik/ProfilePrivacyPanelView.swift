import SwiftUI

struct ProfilePrivacyPanelView: View {
    let snapshot: ProfilePrivacyPanelSnapshot

    var body: some View {
        ProfileDetailCard("Медиа в тестовом окружении") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Результат временной проверки браузера. Разрешения сайтов рабочего профиля могут отличаться.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(
                    "Чтение списка устройств",
                    value: snapshot.mediaDevices.title
                )
                LabeledContent(
                    "Устройств в списке",
                    value: snapshot.mediaDeviceCount.map(String.init)
                        ?? "Не показывается"
                )
                LabeledContent(
                    "Permissions API",
                    value: snapshot.permissionsAPI.title
                )
                LabeledContent("Камера", value: snapshot.camera.title)
                LabeledContent(
                    "Микрофон",
                    value: snapshot.microphone.title
                )
                if let observedAt = snapshot.observedAt {
                    Text(
                        "Последняя проверка: " +
                            observedAt.neAntikDisplayDateTime
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "Список устройств не доказывает, что камера или микрофон работают: для этого сайт запрашивает разрешение и открывает устройство. ID и названия устройств не сохраняются в отчёте."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Медиа и разрешения временного тестового окружения")
    }
}
