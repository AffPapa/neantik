import Foundation
import Testing
@testable import NeAntik

struct BulkProxyRunProgressTests {
    @Test func countsOutcomesAndRetainsOnlyFailedProfileIdentifiers() {
        let successID = UUID()
        let failureID = UUID()
        var progress = BulkProxyRunProgress(total: 2)

        progress.record(profileID: successID, outcome: .succeeded)
        progress.record(profileID: failureID, outcome: .connectionFailed)

        #expect(progress.completed == 2)
        #expect(progress.succeeded == 1)
        #expect(progress.failed == 1)
        #expect(progress.failedProfileIDs == [failureID])
        #expect(progress.summary.contains("успешно 1"))
    }

    @Test func duplicateOrOverflowCompletionCannotCorruptTotals() {
        let profileID = UUID()
        var progress = BulkProxyRunProgress(total: 1)
        progress.record(profileID: profileID, outcome: nil)
        progress.record(profileID: profileID, outcome: .succeeded)
        progress.record(profileID: UUID(), outcome: .succeeded)

        #expect(progress.completed == 1)
        #expect(progress.succeeded == 0)
        #expect(progress.failed == 1)
    }
}
