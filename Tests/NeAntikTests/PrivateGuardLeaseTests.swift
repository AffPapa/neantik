import Darwin
import Foundation
import Testing
@testable import NeAntik

@_silgen_name("flock")
private func privateGuardTestFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

// This bounded blocking wait runs only inside an explicit detached fixture
// worker. Keep the synchronous boundary visible to Swift concurrency checking.
private func privateGuardWait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

private final class PrivateGuardAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// Guard authority tests use only fresh files and our own process descriptors.
/// No real Keychain or application-support data is accessed.
struct PrivateGuardLeaseTests {
    private enum Outcome: Equatable, Sendable { case acquired, cancelled, unsafeEntry, otherError }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-guard-" + UUID().uuidString,
            isDirectory: true
        )
    }

    @Test func bulkGuardRejectsHardlinkWithoutChangingAliasedFile() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        try paths.prepareBaseDirectories()
        let ownOutside = directory.appendingPathComponent("other-owned-file")
        let bytes = Data("Owned bytes must not change".utf8)
        try bytes.write(to: ownOutside)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: ownOutside.path)
        try FileManager.default.linkItem(at: ownOutside, to: paths.bulkCredentialImportGuardFile)
        #expect(throws: POSIXError.self) {
            let lease = try paths.acquireBulkCredentialImportGuard()
            lease.release()
        }
        #expect(try Data(contentsOf: ownOutside) == bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: ownOutside.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o640)
    }

    @Test func bulkGuardRejectsSymlinkAndFIFOWithoutWaiting() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        try paths.prepareBaseDirectories()
        let ownTarget = directory.appendingPathComponent("owned-target")
        try Data("owned".utf8).write(to: ownTarget)
        try FileManager.default.createSymbolicLink(at: paths.bulkCredentialImportGuardFile, withDestinationURL: ownTarget)
        #expect(throws: POSIXError.self) { try paths.acquireBulkCredentialImportGuard() }
        try FileManager.default.removeItem(at: paths.bulkCredentialImportGuardFile)
        let created = paths.bulkCredentialImportGuardFile.path.withCString {
            Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
        }
        try #require(created == 0)
        let start = ContinuousClock.now
        #expect(throws: POSIXError.self) { try paths.acquireBulkCredentialImportGuard() }
        #expect(start.duration(to: .now) < .milliseconds(200))
        #expect(try Data(contentsOf: ownTarget) == Data("owned".utf8))
    }

    @Test func bulkGuardCancellationFinishesWhileHolderStillOwnsLock() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        let holder = try paths.acquireBulkCredentialImportGuard()
        defer { holder.release() }
        let entered = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var hooked = paths
        hooked.guardAcquisitionHooks.onFirstContention = { entered.signal() }
        let waiterPaths = hooked
        let waiter = Task.detached { () -> Outcome in
            defer { finished.signal() }
            do {
                let lease = try waiterPaths.acquireBulkCredentialImportGuard()
                lease.release()
                return .acquired
            } catch is CancellationError { return .cancelled }
            catch { return .otherError }
        }
        let began = await Task.detached { privateGuardWait(entered, seconds: 2) }.value
        #expect(began)
        waiter.cancel()
        let promptly = await Task.detached { privateGuardWait(finished, seconds: 1) }.value
        // Release on failure too: the regression must fail, not hang the suite.
        holder.release()
        let outcome = await waiter.value
        #expect(promptly)
        #expect(outcome == .cancelled)
        let next = try paths.acquireBulkCredentialImportGuard()
        next.release()
    }

    @Test func waitingBulkLeaseRejectsReplacedPathAfterAcquiringOldInode() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        let holder = try paths.acquireBulkCredentialImportGuard()
        defer { holder.release() }
        let contended = DispatchSemaphore(value: 0)
        var hooked = paths
        hooked.guardAcquisitionHooks.onFirstContention = { contended.signal() }
        let waiterPaths = hooked
        let waiter = Task.detached { () -> Outcome in
            do {
                let lease = try waiterPaths.acquireBulkCredentialImportGuard()
                lease.release()
                return .acquired
            } catch let error as POSIXError where error.code == .ELOOP { return .unsafeEntry }
            catch { return .otherError }
        }
        do {
            let waitingAfterValidation = await Task.detached { privateGuardWait(contended, seconds: 2) }.value
            #expect(waitingAfterValidation)
            if waitingAfterValidation {
                try FileManager.default.removeItem(at: paths.bulkCredentialImportGuardFile)
                try Data().write(to: paths.bulkCredentialImportGuardFile)
            }
        } catch {
            holder.release()
            _ = await waiter.value
            throw error
        }
        holder.release()
        let outcome = await waiter.value
        #expect(outcome == .unsafeEntry)
        let next = try paths.acquireBulkCredentialImportGuard()
        next.release()
    }

    @Test func bulkLeaseReleaseAndDeinitLeavePrivateReusableGuard() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        var lease: PrivateFileGuardLease? = try paths.acquireBulkCredentialImportGuard()
        weak var weakLease = lease
        let mode = try FileManager.default.attributesOfItem(atPath: paths.bulkCredentialImportGuardFile.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        lease?.release()
        lease?.release()
        lease = nil
        #expect(weakLease == nil)
        let second = try paths.acquireBulkCredentialImportGuard()
        second.release()
    }

    @Test func heldBulkLeaseDeinitReleasesKernelLock() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        var lease: PrivateFileGuardLease? = try paths.acquireBulkCredentialImportGuard()
        weak var weakLease = lease
        let observer = paths.bulkCredentialImportGuardFile.path.withCString {
            Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        try #require(observer >= 0)
        defer {
            _ = privateGuardTestFlock(observer, LOCK_UN)
            _ = Darwin.close(observer)
        }
        let whileHeld = privateGuardTestFlock(observer, LOCK_EX | LOCK_NB)
        let heldError = errno
        #expect(whileHeld != 0)
        #expect(heldError == EWOULDBLOCK)
        lease = nil
        #expect(weakLease == nil)
        #expect(privateGuardTestFlock(observer, LOCK_EX | LOCK_NB) == 0)
    }

    @Test func interruptedAcquisitionRetriesButRepeatedInterruptsKeepCommandDeadline() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var paths = AppPaths(rootDirectory: directory)
        let attempts = PrivateGuardAttemptCounter()
        paths.guardAcquisitionHooks.lockAttempt = { fd, flags in
            if attempts.next() == 1 { errno = EINTR; return -1 }
            return privateGuardTestFlock(fd, flags)
        }
        #expect(try paths.withProcessLockGuard(for: UUID()) { true })
        paths.guardAcquisitionHooks.lockAttempt = { _, _ in errno = EINTR; return -1 }
        let start = ContinuousClock.now
        #expect(throws: ProfileProcessBusyError.self) {
            try paths.withProcessLockGuard(for: UUID()) { }
        }
        #expect(start.duration(to: .now) < .milliseconds(200))
    }

    @Test func cancelledWorkerCanStillAcquireUncontendedRollbackAuthority() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        let id = UUID()
        let marker = Data("owned rollback completed".utf8)
        let saved = try await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try paths.withProcessLockGuard(for: id) { marker }
        }.value
        #expect(saved == marker)
    }

    @Test func snapshotGuardWaitRespondsToCancellationBeforeHolderRelease() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            try paths.withSnapshotsGuard {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        let held = await Task.detached { privateGuardWait(entered, seconds: 2) }.value
        #expect(held)
        let finished = DispatchSemaphore(value: 0), contended = DispatchSemaphore(value: 0)
        var hooked = paths
        hooked.guardAcquisitionHooks.onFirstContention = { contended.signal() }
        let waiterPaths = hooked
        let waiter = Task.detached { () -> Outcome in
            defer { finished.signal() }
            do { try waiterPaths.withSnapshotsGuard { }; return .acquired }
            catch is CancellationError { return .cancelled }
            catch { return .otherError }
        }
        let waitingAfterValidation = await Task.detached { privateGuardWait(contended, seconds: 2) }.value
        #expect(waitingAfterValidation)
        waiter.cancel()
        let promptly = await Task.detached { privateGuardWait(finished, seconds: 1) }.value
        release.signal()
        let outcome = await waiter.value
        try await holder.value
        #expect(promptly)
        #expect(outcome == .cancelled)
    }
}
