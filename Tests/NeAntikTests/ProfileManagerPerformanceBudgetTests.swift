import Testing
@testable import NeAntik

struct ProfileManagerPerformanceBudgetTests {
    @Test
    func scanBudgetStopsBeforeEntryOrByteLimit() {
        var budget = ProfileManagerScanBudget(
            maximumEntries: 2,
            maximumBytes: 10
        )

        let first = budget.consume(entryBytes: 6)
        let tooLarge = budget.consume(entryBytes: 5)
        let second = budget.consume(entryBytes: 4)
        let tooMany = budget.consume(entryBytes: 0)

        #expect(first)
        #expect(!tooLarge)
        #expect(second)
        #expect(!tooMany)
        #expect(budget.entries == 2)
        #expect(budget.bytes == 10)
    }

    @Test
    func managerBudgetsAreBoundedAndSeparateFromChromiumRuntime() {
        #expect(ProfileManagerPerformanceBudgets.maximumProfileListItems > 0)
        #expect(
            ProfileManagerPerformanceBudgets.maximumArtifactScanEntries <
                ProfileManagerPerformanceBudgets.maximumLifecycleScanEntries
        )
        #expect(
            ProfileManagerPerformanceBudgets.maximumSynchronousScanBytes > 0
        )
    }
}
