import SwiftUI

struct RuntimeProvenanceCardView: View {
    let snapshot: RuntimeProvenanceSnapshot

    var body: some View {
        GroupBox("Происхождение движка") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Движок", value: snapshot.name)
                LabeledContent("Версия", value: snapshot.version)
                LabeledContent("Источник", value: snapshot.source)
                LabeledContent("Профиль движка", value: snapshot.flavor)
                LabeledContent("Архитектура", value: snapshot.architecture)
                LabeledContent("Подпись", value: snapshot.signature)
                LabeledContent("Исполняемый файл", value: snapshot.executableDigest)
                LabeledContent("Framework", value: snapshot.frameworkDigest)
                LabeledContent("Проверка запуска", value: snapshot.preflight)
                Text(
                    "Показывается только безопасное резюме текущей локальной проверки; пути и полные хэши не выводятся."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Карточка происхождения браузерного движка")
    }
}
