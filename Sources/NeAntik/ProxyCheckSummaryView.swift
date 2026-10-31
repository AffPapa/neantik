import SwiftUI

struct ProxyCheckSummaryView: View {
    let summary: ProxyCheckSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.title)
                .font(.subheadline)
            if let checkedAt = summary.checkedAt {
                Text("Последняя проверка: \(checkedAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if summary.status == .latestCheckFailed,
               let lastSuccessfulCheckAt = summary.lastSuccessfulCheckAt
            {
                Text("Последний успех: \(lastSuccessfulCheckAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let checkedAt = summary.checkedAt else {
            return summary.title
        }
        var value = "\(summary.title). Последняя проверка: \(checkedAt.formatted(date: .abbreviated, time: .shortened))."
        if summary.status == .latestCheckFailed,
           let lastSuccessfulCheckAt = summary.lastSuccessfulCheckAt
        {
            value += " Последний успех: \(lastSuccessfulCheckAt.formatted(date: .abbreviated, time: .shortened))."
        }
        return value
    }
}
