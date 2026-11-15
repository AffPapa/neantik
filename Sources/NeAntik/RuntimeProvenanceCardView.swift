import SwiftUI

struct RuntimeProvenanceCardView: View {
    let snapshot: RuntimeProvenanceSnapshot

    var body: some View {
        ProfileDetailCard(NSLocalizedString("page.613", tableName: "Pages", bundle: .main, value: "Происхождение движка", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(NSLocalizedString("page.614", tableName: "Pages", bundle: .main, value: "Движок", comment: ""), value: snapshot.name)
                LabeledContent(NSLocalizedString("page.615", tableName: "Pages", bundle: .main, value: "Версия", comment: ""), value: snapshot.version)
                LabeledContent(NSLocalizedString("page.616", tableName: "Pages", bundle: .main, value: "Источник", comment: ""), value: snapshot.source)
                LabeledContent(NSLocalizedString("page.617", tableName: "Pages", bundle: .main, value: "Профиль движка", comment: ""), value: snapshot.flavor)
                LabeledContent(NSLocalizedString("page.618", tableName: "Pages", bundle: .main, value: "Архитектура", comment: ""), value: snapshot.architecture)
                LabeledContent(NSLocalizedString("page.619", tableName: "Pages", bundle: .main, value: "Подпись", comment: ""), value: snapshot.signature)
                LabeledContent(NSLocalizedString("page.620", tableName: "Pages", bundle: .main, value: "Исполняемый файл", comment: ""), value: snapshot.executableDigest)
                LabeledContent("Framework", value: snapshot.frameworkDigest)
                LabeledContent(NSLocalizedString("page.621", tableName: "Pages", bundle: .main, value: "Проверка запуска", comment: ""), value: snapshot.preflight)
                LabeledContent(
                    NSLocalizedString("page.622", tableName: "Pages", bundle: .main, value: "Статус Direct-релиза", comment: ""),
                    value: snapshot.publicReleaseStatus
                )
                Text(
                    NSLocalizedString("page.623", tableName: "Pages", bundle: .main, value: "Показывается только безопасное резюме текущей локальной проверки; пути и полные хэши не выводятся.", comment: "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("page.624", tableName: "Pages", bundle: .main, value: "Карточка происхождения браузерного движка", comment: ""))
    }
}
