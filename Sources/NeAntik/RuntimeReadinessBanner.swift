import SwiftUI

/// Shared runtime feedback for the home screen and full catalog.
struct RuntimeReadinessBanner: View {
    let isResolving: Bool
    let statusIcon: String
    let statusColor: Color
    let title: String
    let message: String
    let onDetails: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isResolving {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !isResolving {
                Button("Подробнее", action: onDetails)
                    .controlSize(.small)
                    .help("Открыть центр готовности и повторить проверку")
                    .accessibilityLabel("Открыть центр готовности NeAntik")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .contain)
    }
}
