import Foundation

/// Owns cancellable polling by purpose and profile. Callers retain the exact
/// lease/record identity checks; replacing one observer never cancels another.
@MainActor
final class BrowserProcessObservations {
    enum Key: Hashable {
        case external(UUID)
        case recovery(UUID)
        case tombstone(UUID)
    }

    private var tasks: [Key: Task<Void, Never>] = [:]

    func cancel(_ key: Key) {
        tasks.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func replace(
        _ key: Key,
        enabled: Bool,
        interval: UInt64,
        poll: @escaping @MainActor () -> Bool
    ) {
        cancel(key)
        guard enabled else { return }
        tasks[key] = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard poll() else { return }
            }
        }
    }
}
