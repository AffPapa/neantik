import SwiftUI

struct ProfileArtifactProvenanceView: View {
    let snapshot: ProfileArtifactProvenanceSnapshot

    var body: some View {
        GroupBox("Файлы и расширения") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Загрузки", value: snapshot.downloads.title)
                LabeledContent("Каталоги расширений", value: snapshot.extensions.title)
                LabeledContent("Карантин", value: snapshot.quarantine.title)
                LabeledContent(
                    "Политика",
                    value: snapshot.quarantinePolicy.title
                )
                Text(
                    "Показано число локальных каталогов расширений, а не их активность или разрешения. Файлы не запускаются автоматически; карантин перемещает только явно выбранный безопасный объект."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provenance загрузок и расширений")
    }
}
