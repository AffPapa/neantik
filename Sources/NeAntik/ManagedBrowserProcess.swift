import Foundation

/// A starting lease and its eventual process share one lifetime. A failed
/// launch can keep a live process without claiming a successful start time.
struct ManagedBrowserProcess {
    let ownerToken: UUID
    let browserDataDirectory: URL
    var process: Process?
    var startedAt: Date?
    var stopTask: Task<Void, Never>?
    var wasForced = false
    var startupFailed = false
}
