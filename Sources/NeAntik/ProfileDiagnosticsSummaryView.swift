import SwiftUI

struct ProfileDiagnosticsSummaryView: View {
    let lifecycle: ProfileLifecycleHealthSnapshot
    let privacyPanel: ProfilePrivacyPanelSnapshot
    let artifactProvenance: ProfileArtifactProvenanceSnapshot
    let runtimeProvenance: RuntimeProvenanceSnapshot
    @Binding var isExpanded: Bool

    private var summary: ProfileDiagnosticsSummary {
        ProfileDiagnosticsSummary.resolve(
            lifecycle: lifecycle,
            privacyPanel: privacyPanel,
            artifactProvenance: artifactProvenance,
            runtimeProvenance: runtimeProvenance
        )
    }

    var body: some View {
        ProfileDetailCard(accessibilityTitle: NSLocalizedString("page.744", tableName: "Pages", bundle: .main, value: "Диагностика профиля", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: isExpanded
                                ? "chevron.down"
                                : "chevron.right"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                        Label(NSLocalizedString("page.745", tableName: "Pages", bundle: .main, value: "Диагностика", comment: ""), systemImage: "stethoscope")
                            .font(.headline)

                        Spacer(minLength: 8)

                        Text(verbatim: localizedProfileStatus(summary.status.title))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("page.744", tableName: "Pages", bundle: .main, value: "Диагностика профиля", comment: ""))
                .accessibilityValue(
                    "\(localizedProfileStatus(summary.status.title)). " +
                        (isExpanded ? NSLocalizedString("page.746", tableName: "Pages", bundle: .main, value: "Развёрнута", comment: "") : NSLocalizedString("page.747", tableName: "Pages", bundle: .main, value: "Скрыта", comment: ""))
                )
                .accessibilityHint(
                    isExpanded
                        ? NSLocalizedString("page.748", tableName: "Pages", bundle: .main, value: "Скрывает подробные локальные проверки", comment: "")
                        : NSLocalizedString("page.749", tableName: "Pages", bundle: .main, value: "Показывает подробные локальные проверки", comment: "")
                )

                if let nextStep = summary.nextStep.title {
                    Label(localizedProfileStatus(nextStep), systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            String(format: localizedProfileStatus("Следующий шаг: %@"), localizedProfileStatus(nextStep))
                        )
                }

                if isExpanded {
                    Divider()
                    Text(verbatim: localizedProfileStatus(summary.detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("page.744", tableName: "Pages", bundle: .main, value: "Диагностика профиля", comment: ""))
    }

    private var statusColor: Color {
        switch summary.status {
        case .ready:
            .secondary
        case .attention:
            .orange
        case .checking:
            .secondary
        case .partial:
            .secondary
        case .unavailable:
            .secondary
        }
    }
}
