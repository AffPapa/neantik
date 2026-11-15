import SwiftUI

struct ProxyCheckSummaryView: View {
    let summary: ProxyCheckSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.title)
                .font(.subheadline)
            Text(ProxyCheckSummary.routeScopeNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let checkedAt = summary.checkedAt {
                (Text(NSLocalizedString("page.600", tableName: "Pages", bundle: .main, value: "Последняя проверка: ", comment: "")) + Text(checkedAt, style: .relative))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if summary.status == .latestCheckFailed,
               let lastSuccessfulCheckAt = summary.lastSuccessfulCheckAt
            {
                (Text(NSLocalizedString("page.601", tableName: "Pages", bundle: .main, value: "Последний успех: ", comment: "")) + Text(lastSuccessfulCheckAt, style: .relative))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var value = "\(summary.title). \(ProxyCheckSummary.routeScopeNotice)"
        guard let checkedAt = summary.checkedAt else {
            return value
        }
        value += String(format: NSLocalizedString("page.602", tableName: "Pages", bundle: .main, value: " Последняя проверка: %@.", comment: ""), String(describing: checkedAt.formatted(date: .abbreviated, time: .shortened)))
        if summary.status == .latestCheckFailed,
           let lastSuccessfulCheckAt = summary.lastSuccessfulCheckAt
        {
            value += String(format: NSLocalizedString("page.603", tableName: "Pages", bundle: .main, value: " Последний успех: %@.", comment: ""), String(describing: lastSuccessfulCheckAt.formatted(date: .abbreviated, time: .shortened)))
        }
        return value
    }
}
