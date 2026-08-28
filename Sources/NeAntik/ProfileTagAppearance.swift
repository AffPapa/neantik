import SwiftUI

enum ProfileTagTone: String, CaseIterable, Sendable {
    case blue
    case purple
    case teal
    case indigo
    case cyan
    case gray
}

enum ProfileTagAppearance {
    static func tone(for tagID: ProfileTagID) -> ProfileTagTone {
        let tones = ProfileTagTone.allCases
        return tones[Int(stableHash(tagID.rawValue) % UInt32(tones.count))]
    }

    static func tone(for displayName: String) -> ProfileTagTone {
        tone(for: ProfileTagID(displayName: displayName))
    }

    private static func stableHash(_ value: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }
}

extension Color {
    init(profileTagTone tone: ProfileTagTone) {
        switch tone {
        case .blue:
            self = Color(nsColor: .systemBlue)
        case .indigo:
            self = Color(nsColor: .systemIndigo)
        case .purple:
            self = Color(nsColor: .systemPurple)
        case .teal:
            self = Color(nsColor: .systemTeal)
        case .cyan:
            self = Color(nsColor: .systemCyan)
        case .gray:
            self = Color(nsColor: .systemGray)
        }
    }
}

struct ProfileTagMarker: View {
    let tag: String
    var size: CGFloat = 7

    private var color: Color {
        Color(
            profileTagTone: ProfileTagAppearance.tone(for: tag)
        )
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(.primary.opacity(0.16), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

struct ProfileTagChip: View {
    let tag: String
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 2

    @Environment(\.colorSchemeContrast) private var contrast

    private var color: Color {
        Color(
            profileTagTone: ProfileTagAppearance.tone(for: tag)
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            ProfileTagMarker(tag: tag)
            Text(tag)
                .lineLimit(1)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            color.opacity(contrast == .increased ? 0.24 : 0.14),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Тег \(tag)")
    }
}
