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
        GroupBox {
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

                        Label("Диагностика", systemImage: "stethoscope")
                            .font(.headline)

                        Spacer(minLength: 8)

                        Text(summary.status.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Диагностика профиля")
                .accessibilityValue(
                    "\(summary.status.title). " +
                        (isExpanded ? "Развёрнута" : "Скрыта")
                )
                .accessibilityHint(
                    isExpanded
                        ? "Скрывает подробные локальные проверки"
                        : "Показывает подробные локальные проверки"
                )

                if let nextStep = summary.nextStep.title {
                    Label(nextStep, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            summary.nextStep.accessibilityLabel ?? nextStep
                        )
                }

                if isExpanded {
                    Divider()
                    Text(summary.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var statusColor: Color {
        switch summary.status {
        case .ready:
            .secondary
        case .attention:
            .orange
        case .unavailable:
            .secondary
        }
    }
}
