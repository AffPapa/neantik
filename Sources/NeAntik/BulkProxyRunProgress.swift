import Foundation
import SwiftUI

struct BulkProxyRunProgress: Equatable, Sendable {
    let total: Int
    private(set) var completed = 0
    private(set) var succeeded = 0
    private(set) var failedProfileIDs: [UUID] = []
    private var recordedProfileIDs = Set<UUID>()

    var failed: Int { failedProfileIDs.count }

    init(total: Int) {
        self.total = max(0, total)
    }

    mutating func record(
        profileID: UUID,
        outcome: ProxyHealthOutcome?
    ) {
        guard completed < total,
              recordedProfileIDs.insert(profileID).inserted
        else { return }
        completed += 1
        if outcome == .succeeded {
            succeeded += 1
        } else {
            failedProfileIDs.append(profileID)
        }
    }

    var summary: String {
        "Проверено \(completed): успешно \(succeeded), ошибок \(failed)"
    }
}

struct BulkProxyProgressView: View {
    let progress: BulkProxyRunProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(
                value: Double(progress.completed),
                total: Double(max(1, progress.total))
            ) {
                Text("Проверено \(progress.completed) из \(progress.total)")
            }
            Text(
                "Успешно: \(progress.succeeded) · Ошибки: \(progress.failed)"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Проверено \(progress.completed) из \(progress.total). " +
                "Успешно \(progress.succeeded). Ошибки \(progress.failed)."
        )
    }
}
