import Dispatch
import Foundation

/// Admission control only: never terminates browsers or touches profile data.
/// A critical OS notification blocks new launches until a normal notification.
/// No notification means unknown, not proof that enough memory is available.
final class BrowserLaunchMemoryGuard {
    static let shared = BrowserLaunchMemoryGuard()
    private let lock = NSLock()
    private var blocked = false
    private var source: DispatchSourceMemoryPressure?

    init(observeSystem: Bool = true) {
        guard observeSystem else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "app.neantik.memory-admission", qos: .utility)
        )
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            self.receive(source.data)
        }
        source.resume()
    }

    deinit { source?.cancel() }

    var isLaunchBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func receive(_ event: DispatchSource.MemoryPressureEvent) {
        lock.lock()
        defer { lock.unlock() }
        if event.contains(.critical) {
            blocked = true
        } else if event.contains(.normal) {
            blocked = false
        }
        // Warning alone cannot clear a previously critical condition.
    }
}
