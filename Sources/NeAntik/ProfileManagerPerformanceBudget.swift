import Foundation

enum ProfileManagerPerformanceBudgets {
    static let maximumProfileListItems =
        ProfileStorageLimits.maximumProfileCount
    static let maximumLifecycleScanEntries = 50_000
    static let maximumArtifactScanEntries = 10_000
    static let maximumSynchronousScanBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
}

struct ProfileManagerScanBudget: Equatable, Sendable {
    let maximumEntries: Int
    let maximumBytes: Int64
    private(set) var entries = 0
    private(set) var bytes: Int64 = 0

    init(maximumEntries: Int, maximumBytes: Int64) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func consume(entryBytes: Int64) -> Bool {
        guard entryBytes >= 0,
              entries < maximumEntries,
              entryBytes <= maximumBytes - bytes
        else {
            return false
        }
        entries += 1
        bytes += entryBytes
        return true
    }
}
