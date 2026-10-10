import Darwin
import Foundation

/// One-shot parent channel to the persistent signed relay owner. The actor
/// keeps bounded pipe waits off MainActor. Successful activation closes only the
/// control pipes; it deliberately does not terminate the owner on deinit.
actor ProxyRelayOwnerClient {
    enum Failure: Error, Equatable {
        case invalidState, invalidReply, ownerExited
        case cleanupUnconfirmed(ProxyRelayPendingOwnerFence?)
        var requiresCleanupRecovery: Bool {
            if case .cleanupUnconfirmed = self { return true }; return false
        }
        var pendingFence: ProxyRelayPendingOwnerFence? {
            if case let .cleanupUnconfirmed(fence) = self { return fence }; return nil
        }
    }
    private enum State { case prepared, bound, active, closed }
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let nonce: UUID
    private let expectedCode: ProxyRelayExpectedCode
    let port: UInt16
    let processID: pid_t
    let processIdentity: ProxyRelayOwnerProcessIdentity
    let pendingFence: ProxyRelayPendingOwnerFence
    private var state = State.prepared

    private init(process: Process, input: FileHandle, output: FileHandle,
                 bootstrap: ProxyRelayOwnerProtocol.Bootstrap,
                 ready: ProxyRelayOwnerProtocol.Ready,
                 identity: ProxyRelayOwnerProcessIdentity, expectedCode: ProxyRelayExpectedCode) {
        self.process = process; self.input = input; self.output = output
        nonce = bootstrap.nonce; port = ready.port
        processID = process.processIdentifier; processIdentity = identity
        self.expectedCode = expectedCode
        pendingFence = .init(profileID: bootstrap.profileID, sessionGeneration: bootstrap.sessionGeneration,
                             ownerPID: process.processIdentifier, identity: identity)
    }

    /// The caller must first acquire its profile's starting lease and freeze
    /// the already-qualified runtime/configuration. No BrowserData is read here.
    static func prepare(executable: URL, bootstrap: ProxyRelayOwnerProtocol.Bootstrap,
                        registerChild: @escaping @Sendable (ProxyRelayPendingOwnerFence) throws -> Void = { _ in }) async throws -> ProxyRelayOwnerClient {
        // A nonisolated async entry can inherit MainActor until its first
        // suspension. Put the whole startup on a separate executor explicitly.
        let task = Task.detached { () throws -> ProxyRelayOwnerClient in
            try Task.checkCancellation(); try bootstrap.validate()
            guard let ownExecutable = Bundle.main.executableURL, let ownID = Bundle.main.bundleIdentifier,
                  ownExecutable.standardizedFileURL == executable.standardizedFileURL,
                  let parent = ProxyRelaySocketOwnerInspector.processIdentity(getpid())
            else { throw Failure.invalidState }
            let expectedCode = try ProxyRelayExpectedCode.qualifiedPin(at: ownExecutable,
                expectedIdentifier: ownID, expectedTeamIdentifier: "H6VGU2M6JD")
            guard ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: parent, expectedCode: expectedCode)
            else { throw Failure.invalidState }
            let request = Pipe(), reply = Pipe(), process = Process()
            process.executableURL = executable
            process.arguments = [NeAntikLaunchIntent.proxyRelayOwnerArgument]
            process.standardInput = request; process.standardOutput = reply
            process.standardError = FileHandle.nullDevice
            // No ambient injected runtime or debugging configuration in owner.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let input = request.fileHandleForWriting, output = reply.fileHandleForReading
            var spawnedFence: ProxyRelayPendingOwnerFence?
            do {
                try process.run()
                // Before any pipe setup, code validation or secret transmission:
                // persist even an uninspectable child as a conservative fence.
                let fence = ProxyRelayPendingOwnerFence(profileID: bootstrap.profileID, sessionGeneration: bootstrap.sessionGeneration,
                    ownerPID: process.processIdentifier, identity: ProxyRelaySocketOwnerInspector.processIdentity(process.processIdentifier))
                spawnedFence = fence
                try registerChild(fence)
                try request.fileHandleForReading.close(); try reply.fileHandleForWriting.close()
                try ProxyRelayPrivatePipe.prepare(input.fileDescriptor, writable: true)
                try ProxyRelayPrivatePipe.prepare(output.fileDescriptor, writable: false)
                guard let child = ProxyRelaySocketOwnerInspector.processIdentity(process.processIdentifier),
                      child.userID == geteuid(), child.parentProcessID == getpid(),
                      ProxyRelayLiveCodeVerifier.matches(processID: process.processIdentifier, expectedProcess: child, expectedCode: expectedCode)
                else { throw Failure.invalidReply }
                try ProxyRelayPrivatePipe.writeFrame(input.fileDescriptor, data: JSONEncoder().encode(bootstrap), timeout: 2)
                let ready = try JSONDecoder().decode(ProxyRelayOwnerProtocol.Ready.self,
                    from: ProxyRelayPrivatePipe.readFrame(output.fileDescriptor, timeout: 10))
                guard ready.schemaVersion == 1, ready.nonce == bootstrap.nonce, ready.port != 0,
                      process.isRunning,
                      let identity = ProxyRelaySocketOwnerInspector.processIdentity(process.processIdentifier),
                      identity == child,
                      ProxyRelayLiveCodeVerifier.matches(processID: process.processIdentifier, expectedProcess: identity, expectedCode: expectedCode)
                else { throw Failure.invalidReply }
                try Task.checkCancellation()
                return ProxyRelayOwnerClient(process: process, input: input, output: output,
                                             bootstrap: bootstrap, ready: ready, identity: identity, expectedCode: expectedCode)
            } catch {
                try? input.close(); try? output.close()
                // The owner has not been acknowledged as bound: no stream
                // can survive cancellation. Signal only this child generation.
                guard terminateBounded(process) else { throw Failure.cleanupUnconfirmed(spawnedFence) }
                throw error
            }
        }
        return try await withTaskCancellationHandler(operation: {
            let owner = try await task.value
            do { try Task.checkCancellation(); return owner }
            catch { guard await owner.abandon() else { throw Failure.cleanupUnconfirmed(owner.pendingFence) }; throw error }
        }, onCancel: { task.cancel() })
    }

    func bind(browserPID: pid_t) throws {
        do {
            guard state == .prepared, process.isRunning,
                  ProxyRelaySocketOwnerInspector.processIdentity(processID) == processIdentity,
                  ProxyRelayLiveCodeVerifier.matches(processID: processID, expectedProcess: processIdentity, expectedCode: expectedCode),
                  let browser = ProxyRelaySocketOwnerInspector.processIdentity(browserPID),
                  browser.userID == geteuid(), browser.parentProcessID == getpid()
            else { throw Failure.invalidState }
            try Task.checkCancellation()
            let bind = ProxyRelayOwnerProtocol.Bind(schemaVersion: 1, nonce: nonce, browserPID: browserPID,
                startSeconds: browser.generation.startSeconds, startMicroseconds: browser.generation.startMicroseconds)
            try ProxyRelayPrivatePipe.writeFrame(input.fileDescriptor, data: JSONEncoder().encode(bind), timeout: 2)
            let bound = try JSONDecoder().decode(ProxyRelayOwnerProtocol.Bound.self,
                from: ProxyRelayPrivatePipe.readFrame(output.fileDescriptor, timeout: 5))
            guard bound.schemaVersion == 1, bound.nonce == nonce, bound.bound, process.isRunning
            else { throw Failure.invalidReply }
            try Task.checkCancellation()
            state = .bound
        } catch { guard abandon() else { throw Failure.cleanupUnconfirmed(pendingFence) }; throw error }
    }

    /// Invoke only after the caller durably commits its running profile lease.
    /// Before this frame the listener cannot open any upstream connection.
    func activate(profile: BrowserProfile? = nil, paths: AppPaths? = nil, expectedLease: BrowserProcessLock? = nil) throws {
        do {
            guard state == .bound, process.isRunning,
                  ProxyRelayLiveCodeVerifier.matches(processID: processID, expectedProcess: processIdentity, expectedCode: expectedCode)
            else { throw Failure.invalidState }
            try Task.checkCancellation()
            let commit = { [self] in
                try ProxyRelayPrivatePipe.writeFrame(input.fileDescriptor,
                    data: JSONEncoder().encode(ProxyRelayOwnerProtocol.Commit(schemaVersion: 1, nonce: nonce)), timeout: 2)
                let active = try JSONDecoder().decode(ProxyRelayOwnerProtocol.Active.self,
                    from: ProxyRelayPrivatePipe.readFrame(output.fileDescriptor, timeout: 5))
                guard active.schemaVersion == 1, active.nonce == nonce, active.active, process.isRunning
                else { throw Failure.invalidReply }
            }
            if let profile, let paths, let expectedLease {
                try paths.withProcessLockGuard(for: profile.id) {
                    guard expectedLease.phase == .running, expectedLease.ownerToken != nil,
                          expectedLease.relay?.ownerPID == self.processID,
                          try ManagedSessionLeaseReader.read(paths: paths, profileID: profile.id) == expectedLease
                    else { throw Failure.invalidState }
                    try ProfileStore.withPersistedLaunchSnapshot(profile, paths: paths, operation: commit)
                }
            } else {
                guard profile == nil, paths == nil, expectedLease == nil else { throw Failure.invalidState }
                try commit()
            }
            try Task.checkCancellation()
            state = .active; try? input.close(); try? output.close()
        } catch { guard abandon() else { throw Failure.cleanupUnconfirmed(pendingFence) }; throw error }
    }

    /// Use only for failed/cancelled startup. A normal manager exit must not
    /// call this after binding: the owner independently follows browser life.
    @discardableResult func abandon() -> Bool {
        guard state != .closed else { return !process.isRunning }
        state = .closed; try? input.close(); try? output.close()
        return Self.terminateBounded(process, expectedIdentity: processIdentity)
    }

    private static func terminateBounded(_ process: Process, expectedIdentity: ProxyRelayOwnerProcessIdentity? = nil) -> Bool {
        guard process.isRunning else { return true }
        guard let identity = ProxyRelaySocketOwnerInspector.processIdentity(process.processIdentifier),
              expectedIdentity == nil || identity == expectedIdentity
        else { return !process.isRunning }
        process.terminate()
        func waitForExit() -> Bool {
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
            return !process.isRunning
        }
        if waitForExit() { return true }
        guard ProxyRelaySocketOwnerInspector.processIdentity(process.processIdentifier) == identity else { return !process.isRunning }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        return waitForExit()
    }
}
