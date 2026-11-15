import SwiftUI

struct ProfileArtifactProvenanceView: View {
    let snapshot: ProfileArtifactProvenanceSnapshot

    var body: some View {
        ProfileDetailCard(NSLocalizedString("page.646", tableName: "Pages", bundle: .main, value: "Файлы и расширения", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(NSLocalizedString("page.647", tableName: "Pages", bundle: .main, value: "Загрузки", comment: ""), value: snapshot.downloads.title)
                LabeledContent(NSLocalizedString("page.648", tableName: "Pages", bundle: .main, value: "Каталоги расширений", comment: ""), value: snapshot.extensions.title)
                LabeledContent(NSLocalizedString("page.649", tableName: "Pages", bundle: .main, value: "Карантин", comment: ""), value: snapshot.quarantine.title)
                LabeledContent(
                    NSLocalizedString("page.650", tableName: "Pages", bundle: .main, value: "Политика", comment: ""),
                    value: snapshot.quarantinePolicy.title
                )
                Text(
                    NSLocalizedString("page.651", tableName: "Pages", bundle: .main, value: "Показано число локальных каталогов расширений, а не их активность или разрешения. Файлы не запускаются автоматически; карантин перемещает только явно выбранный безопасный объект.", comment: "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("page.652", tableName: "Pages", bundle: .main, value: "Provenance загрузок и расширений", comment: ""))
    }
}
