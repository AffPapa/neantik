import Foundation

/// One writer per open profile. Autosaves coalesce while disk I/O is in flight;
/// final close cancels its timer, queues the latest snapshot and awaits drain.
/// The browser retains its profile guards until finish returns successfully.
@MainActor
final class WebKitSessionCheckpointer {
    typealias Write = @Sendable (WebKitSessionSnapshot) async -> Bool
    typealias Wait = @Sendable (Duration) async throws -> Void
    private let profileID: UUID
    private let write: Write
    private let delay: Duration
    private let wait: Wait
    private let onAutosave: @MainActor (Bool) -> Void
    private var timer: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var pending: WebKitSessionSnapshot?
    private var requested: WebKitSessionSnapshot?
    private(set) var isFinishing = false
    private var completion: CheckedContinuation<Bool, Never>?
    private var lastWriteSucceeded = false

    convenience init(profileID: UUID, store: WebKitSessionStore, delay: Duration = .milliseconds(400),
                     onAutosave: @escaping @MainActor (Bool) -> Void) {
        self.init(profileID: profileID, delay: delay, write: { snapshot in
            await Task.detached(priority: .utility) {
                do { try store.save(snapshot); return true } catch { return false }
            }.value
        }, onAutosave: onAutosave)
    }

    init(profileID: UUID, delay: Duration = .milliseconds(400),
         wait: @escaping Wait = { try await Task.sleep(for: $0) }, write: @escaping Write,
         onAutosave: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.profileID = profileID
        self.delay = delay; self.wait = wait; self.write = write; self.onAutosave = onAutosave
    }

    @discardableResult func schedule(_ snapshot: WebKitSessionSnapshot) -> Bool {
        guard !isFinishing, valid(snapshot) else { return false }
        guard requested != snapshot else { return true }
        requested = snapshot
        // A busy History API must not postpone persistence forever. One fixed
        // window collects the latest state without creating a task per event.
        guard timer == nil else { return true }
        timer = Task { [weak self, delay, wait] in
            do { try await wait(delay) } catch { return }
            guard !Task.isCancelled, let self, !self.isFinishing,
                  let latest = self.requested else { return }
            self.timer = nil
            self.enqueue(latest)
        }
        return true
    }

    /// The final snapshot is always written, even if unchanged, so the file
    /// custody checks run before guards are released. A failed finish can be
    /// retried explicitly; autosave never retries a failing disk in a loop.
    func finish(_ snapshot: WebKitSessionSnapshot) async -> Bool {
        guard completion == nil, valid(snapshot) else { return false }
        isFinishing = true
        timer?.cancel(); timer = nil
        return await withCheckedContinuation { continuation in
            completion = continuation
            enqueue(snapshot)
        }
    }

    private func enqueue(_ snapshot: WebKitSessionSnapshot) {
        pending = snapshot
        guard worker == nil else { return }
        worker = Task { [self] in
            while let snapshot = pending {
                pending = nil
                lastWriteSucceeded = await write(snapshot)
                if !isFinishing { onAutosave(lastWriteSucceeded) }
            }
            worker = nil
            let callback = completion; completion = nil
            callback?.resume(returning: lastWriteSucceeded)
        }
    }

    private func valid(_ snapshot: WebKitSessionSnapshot) -> Bool {
        do { try snapshot.validate(for: profileID); return true } catch { return false }
    }
}
