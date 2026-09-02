import SwiftUI

enum UserNoticeLevel: String, CaseIterable, Sendable {
    case information
    case success
    case warning
    case failure

    var systemImage: String {
        switch self {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .information: "Информация"
        case .success: "Успешно"
        case .warning: "Предупреждение"
        case .failure: "Ошибка"
        }
    }
}

struct UserNotice: Equatable, Sendable {
    let message: String
    let level: UserNoticeLevel

    init(_ message: String, level: UserNoticeLevel) {
        self.message = message
        self.level = level
    }

    var accessibilitySummary: String {
        "\(level.accessibilityTitle). \(message)"
    }
}

struct UserNoticeLabel: View {
    let notice: UserNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: notice.level.systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(notice.message)
                .foregroundStyle(.primary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.accessibilitySummary)
    }

    private var tint: Color {
        switch notice.level {
        case .information: .accentColor
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}
