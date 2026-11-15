import SwiftUI

struct RuntimeProvenanceCardView: View {
    let snapshot: RuntimeProvenanceSnapshot

    private var localizedPublicReleaseStatus: String {
        let status = snapshot.publicReleaseStatus
        let prefix = "Ниже baseline "
        let suffix = " — Direct-релиз заблокирован"
        if status.hasPrefix(prefix), status.hasSuffix(suffix) {
            let version = String(status.dropFirst(prefix.count).dropLast(suffix.count))
            return String(format: NSLocalizedString("Ниже baseline %@ — Direct-релиз заблокирован", comment: "Runtime version below baseline"), version)
        }
        return NSLocalizedString(status, comment: "Runtime release status")
    }

    var body: some View {
        ProfileDetailCard(NSLocalizedString("page.613", tableName: "Pages", bundle: .main, value: "Происхождение движка", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(NSLocalizedString("page.614", tableName: "Pages", bundle: .main, value: "Движок", comment: ""), value: NSLocalizedString(snapshot.name, comment: "Runtime provenance value"))
                LabeledContent(NSLocalizedString("page.615", tableName: "Pages", bundle: .main, value: "Версия", comment: ""), value: NSLocalizedString(snapshot.version, comment: "Runtime provenance value"))
                LabeledContent(NSLocalizedString("page.616", tableName: "Pages", bundle: .main, value: "Источник", comment: ""), value: NSLocalizedString(snapshot.source, comment: "Runtime provenance value"))
                LabeledContent(NSLocalizedString("page.617", tableName: "Pages", bundle: .main, value: "Профиль движка", comment: ""), value: NSLocalizedString(snapshot.flavor, comment: "Runtime provenance value"))
                LabeledContent(NSLocalizedString("page.618", tableName: "Pages", bundle: .main, value: "Архитектура", comment: ""), value: NSLocalizedString(snapshot.architecture, comment: "Runtime provenance value"))
                LabeledContent(NSLocalizedString("page.619", tableName: "Pages", bundle: .main, value: "Подпись", comment: ""), value: NSLocalizedString(snapshot.signature, comment: "Runtime provenance value"))
                LabeledContent(NSLocalizedString("page.620", tableName: "Pages", bundle: .main, value: "Исполняемый файл", comment: ""), value: NSLocalizedString(snapshot.executableDigest, comment: "Runtime provenance value"))
                LabeledContent("Framework", value: NSLocalizedString(snapshot.frameworkDigest, comment: "Runtime provenance value"))
                LabeledContent(NSLocalizedString("page.621", tableName: "Pages", bundle: .main, value: "Проверка запуска", comment: ""), value: NSLocalizedString(snapshot.preflight, comment: "Runtime provenance value"))
                LabeledContent(
                    NSLocalizedString("page.622", tableName: "Pages", bundle: .main, value: "Статус Direct-релиза", comment: ""),
                    value: localizedPublicReleaseStatus
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
