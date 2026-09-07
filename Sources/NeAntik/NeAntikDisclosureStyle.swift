import SwiftUI

/// Native disclosure state with a full-width keyboard-accessible header.
struct NeAntikDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var minimumHeight: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if reduceMotion {
                    configuration.isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        configuration.isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Развёрнуто" : "Свёрнуто")
            .accessibilityHint(configuration.isExpanded ? "Скрывает раздел" : "Показывает раздел")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
