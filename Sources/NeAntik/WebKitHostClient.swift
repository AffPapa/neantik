import Darwin
import Foundation

/// Parent-side transport for the pinned WebKit host. It deliberately does not
/// create a window or enable a proxy by itself; BrowserProcessManager must own
/// the profile reservation and broker lease before calling these operations.
actor WebKitHostClient {
    enum Failure: LocalizedError, Equatable {
        case invalidState
        case invalidChild
        case invalidReply
        case childExited
        case childRefusedStartup(code: String)
        case childStartupTimedOut(stage: String)
        case cleanupUnconfirmed

        var errorDescription: String? {
            switch self {
            case .invalidState: return "Состояние запуска WebKit изменилось."
            case .invalidChild: return "Не удалось подтвердить подписанный процесс WebKit."
            case .invalidReply: return "Процесс WebKit вернул неожиданный ответ."
            case .childExited: return "Процесс WebKit завершился во время запуска."
            case .childRefusedStartup(let code):
                return "Встроенный WebKit отказал на проверке запуска (\(code))."
            case .childStartupTimedOut(let stage):
                return "Встроенный WebKit не ответил на этапе запуска (\(stage))."
            case .cleanupUnconfirmed:
                return "Не удалось подтвердить остановку изолированного WebKit."
            }
        }
    }

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    nonisolated let session: WebKitHostIPC.Session
    private let managerBundle: URL
    private let forgetChild: @Sendable (pid_t, Bool) throws -> Void
    private var gate: WebKitHostCloseGate
    private var activeBroker: WebKitLoopbackBroker?
    private var activeScope: WebKitRelayAuthority.Scope?
    private var closed = false

    private init(process: Process, input: FileHandle, output: FileHandle,
                 session: WebKitHostIPC.Session, managerBundle: URL,
                 forgetChild: @escaping @Sendable (pid_t, Bool) throws -> Void) {
        self.process = process
        self.input = input
        self.output = output
        self.session = session
        self.managerBundle = managerBundle
        self.forgetChild = forgetChild
        gate = WebKitHostCloseGate(expected: session)
    }

    /// Start only the nested, hash-pinned host. Persist a conservative child
    /// fence immediately after spawn, authenticate the live code before any
    /// session path or proxy credential crosses the pipe, then wait for the
    /// child to confirm its exact profile lock/revision bootstrap.
    static func launch(
        session: WebKitHostIPC.Session,
        registerChild: @escaping @Sendable (pid_t, String) throws -> Void,
        forgetChild: @escaping @Sendable (pid_t, Bool) throws -> Void
    ) async throws -> WebKitHostClient {
        let task = Task.detached { () throws -> WebKitHostClient in
            try Task.checkCancellation()
            guard session.isValid(),
                  let executable = Bundle.main.executableURL,
                  let managerBundle = NeAntikLaunchIntent.applicationBundleURL(
                    forExecutablePath: executable.path),
                  let expectedManagerIdentifier =
                    WebKitHostCodeIdentity.expectedManagerIdentifier(in: managerBundle),
                  let parentIdentity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()),
                  parentIdentity.userID == geteuid(),
                  let parentCode = try? ProxyRelayExpectedCode.qualifiedPin(
                    at: executable, expectedIdentifier: expectedManagerIdentifier,
                    expectedTeamIdentifier: WebKitHostCodeIdentity.teamIdentifier),
                  ProxyRelayLiveCodeVerifier.matches(processID: getpid(),
                    expectedProcess: parentIdentity, expectedCode: parentCode)
            else { throw Failure.invalidState }

            let (helper, _) = try WebKitHostCodeIdentity.pinnedHelperCode(in: managerBundle)
            let request = Pipe(), reply = Pipe(), child = Process()
            let diagnostic = Pipe()
            child.executableURL = helper
            child.arguments = [NeAntikLaunchIntent.webKitHostChildArgument]
            child.standardInput = request
            child.standardOutput = reply
            #if DEBUG
            // The child writes only fixed, secret-free startup failure codes.
            // Keep them available to disposable QA logs; release builds discard
            // stderr so browser/runtime diagnostics never become a log channel.
            child.standardError = diagnostic
            #else
            child.standardError = FileHandle.nullDevice
            #endif
            // Do not propagate DYLD, proxy, or debugging environment variables.
            child.environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "TMPDIR": FileManager.default.temporaryDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ]

            let input = request.fileHandleForWriting
            let output = reply.fileHandleForReading
            var didRegisterFence = false
            do {
                try child.run()
                #if DEBUG
                try? diagnostic.fileHandleForWriting.close()
                #endif
                didRegisterFence = true
                try registerChild(child.processIdentifier, helper.path)
                try request.fileHandleForReading.close()
                try reply.fileHandleForWriting.close()
                try ProxyRelayPrivatePipe.prepare(input.fileDescriptor, writable: true)
                try ProxyRelayPrivatePipe.prepare(output.fileDescriptor, writable: false)
                guard child.isRunning,
                      WebKitHostCodeIdentity.verifyChild(
                        processID: child.processIdentifier, expectedParentPID: getpid(),
                        managerBundle: managerBundle) != nil
                else { throw Failure.invalidChild }

                try WebKitHostIPC.write(.bootstrap(session), to: input.fileDescriptor, timeout: 2)
                let frame = try WebKitHostIPC.read(from: output.fileDescriptor, timeout: 10)
                var gate = WebKitHostCloseGate(expected: session)
                try gate.accept(frame)
                guard gate.state == .awaitingRelayCapability,
                      child.isRunning,
                      WebKitHostCodeIdentity.verifyChild(
                        processID: child.processIdentifier, expectedParentPID: getpid(),
                        managerBundle: managerBundle) != nil
                else { throw Failure.invalidReply }
                try Task.checkCancellation()
                return WebKitHostClient(process: child, input: input, output: output,
                    session: session, managerBundle: managerBundle,
                    forgetChild: forgetChild)
            } catch {
                try? input.close(); try? output.close()
                guard await terminateBounded(child, managerBundle: managerBundle) else {
                    throw Failure.cleanupUnconfirmed
                }
                if didRegisterFence { try? forgetChild(child.processIdentifier, true) }
                #if DEBUG
                let diagnosticData = (try? diagnostic.fileHandleForReading.readToEnd()) ?? Data()
                if let code = Self.childStartupDiagnosticCode(diagnosticData) {
                    throw Failure.childRefusedStartup(code: code)
                }
                if error as? ProxyRelayPrivatePipe.Failure == .timeout,
                   let stage = Self.childStartupStage(diagnosticData) {
                    throw Failure.childStartupTimedOut(stage: stage)
                }
                #endif
                throw error
            }
        }
        return try await withTaskCancellationHandler(operation: {
            let client = try await task.value
            do { try Task.checkCancellation(); return client }
            catch { guard await client.abort() else { throw Failure.cleanupUnconfirmed }; throw error }
        }, onCancel: { task.cancel() })
    }

    /// Send the one-use capability only after the child acknowledged its exact
    /// locked profile revision. The reported NetworkProcess is immediately
    /// pinned to its live code identity before broker activation.
    func configureRoute(_ capability: WebKitRelayAuthority.Capability,
                        scope: WebKitRelayAuthority.Scope,
                        broker: WebKitLoopbackBroker) async throws
        -> WebKitNetworkProcessCodeIdentity.Lease {
        guard scope == expectedScope, capability.scope == scope else {
            throw Failure.invalidState
        }
        do {
            guard !closed, process.isRunning, childIsTrusted() else { throw Failure.invalidChild }
            let credentialFrame = try gate.issueRelayCapability(capability)
            try WebKitHostIPC.write(credentialFrame, to: input.fileDescriptor, timeout: 2)
            guard process.isRunning, childIsTrusted() else { throw Failure.childExited }
            let frame = try WebKitHostIPC.read(from: output.fileDescriptor, timeout: 10)
            return try gate.attestNetworkProcessOwner(frame, managerBundle: managerBundle)
        } catch {
            await broker.revoke(scope)
            guard await abort() else { throw Failure.cleanupUnconfirmed }
            throw error
        }
    }

    /// Route activation is ordered after live NetworkProcess attestation and
    /// broker lease activation. If either fails, revoke the scope and stop only
    /// this authenticated child; it never receives permission to navigate.
    func activate(scope: WebKitRelayAuthority.Scope,
                  broker: WebKitLoopbackBroker,
                  lease: WebKitNetworkProcessCodeIdentity.Lease) async throws {
        guard scope == expectedScope, lease.scope == scope else { throw Failure.invalidState }
        do {
            guard !closed, process.isRunning, childIsTrusted() else { throw Failure.invalidChild }
            let frame = try gate.activateRoute(scope: scope) { exactScope in
                try broker.activate(scope: exactScope, lease: lease)
            }
            activeBroker = broker
            activeScope = scope
            try WebKitHostIPC.write(frame, to: input.fileDescriptor, timeout: 2)
            guard process.isRunning, childIsTrusted() else { throw Failure.childExited }
            let ready = try WebKitHostIPC.read(from: output.fileDescriptor, timeout: 10)
            try gate.accept(ready)
            guard gate.state == .running else { throw Failure.invalidReply }
        } catch {
            await broker.revoke(scope)
            guard await abort() else { throw Failure.cleanupUnconfirmed }
            throw error
        }
    }

    /// Request a graceful close and require save, close, and process-exit
    /// acknowledgements for the same session before releasing the child fence.
    func close() async throws {
        guard !closed else { return }
        if gate.state != .closed {
            guard process.isRunning, childIsTrusted() else { throw Failure.childExited }
            if gate.state == .running || gate.state == .failed {
                try gate.requestClose()
                try WebKitHostIPC.write(.close(session), to: input.fileDescriptor, timeout: 2)
            } else if gate.state != .closing && gate.state != .saved {
                throw Failure.invalidState
            }
            guard process.isRunning, childIsTrusted() else { throw Failure.childExited }
            if gate.state == .closing {
                try gate.accept(WebKitHostIPC.read(from: output.fileDescriptor, timeout: 30))
            }
            guard gate.state == .saved else { throw Failure.invalidReply }
            try gate.accept(WebKitHostIPC.read(from: output.fileDescriptor, timeout: 5))
            guard gate.state == .closed else { throw Failure.invalidReply }
        }
        for _ in 0..<100 where process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !process.isRunning else { throw Failure.cleanupUnconfirmed }
        try input.close(); try output.close()
        if let activeBroker, let activeScope { await activeBroker.revoke(activeScope) }
        self.activeBroker = nil; self.activeScope = nil
        try forgetChild(process.processIdentifier, true)
        closed = true
    }

    /// Failed startup or manager cancellation. Signal only the process object
    /// created by this launch; if it is still live, require its pinned identity
    /// before escalation to SIGKILL.
    @discardableResult
    func abort() async -> Bool {
        guard !closed else { return !process.isRunning }
        try? input.close(); try? output.close()
        if let activeBroker, let activeScope { await activeBroker.revoke(activeScope) }
        self.activeBroker = nil; self.activeScope = nil
        guard await Self.terminateBounded(process, managerBundle: managerBundle) else { return false }
        do { try forgetChild(process.processIdentifier, true) }
        catch { return false }
        closed = true
        return true
    }

    private func childIsTrusted() -> Bool {
        WebKitHostCodeIdentity.verifyChild(processID: process.processIdentifier,
            expectedParentPID: getpid(), managerBundle: managerBundle) != nil
    }

    private var expectedScope: WebKitRelayAuthority.Scope {
        WebKitRelayAuthority.Scope(profileID: session.profileID,
            storeID: session.profileID, sessionID: session.generation,
            revision: session.revision)
    }

    private static func terminateBounded(_ process: Process,
                                        managerBundle: URL) async -> Bool {
        guard process.isRunning else { return true }
        guard WebKitHostCodeIdentity.verifyChild(processID: process.processIdentifier,
            expectedParentPID: getpid(), managerBundle: managerBundle) != nil else {
            return !process.isRunning
        }
        process.terminate()
        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard process.isRunning else { return true }
        guard WebKitHostCodeIdentity.verifyChild(processID: process.processIdentifier,
            expectedParentPID: getpid(), managerBundle: managerBundle) != nil else {
            return !process.isRunning
        }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }

    /// Only accept the child runtime's fixed, bounded diagnostic token. Never
    /// surface arbitrary stderr, which could include paths or page data.
    static func childStartupDiagnosticCode(_ data: Data?) -> String? {
        guard let data, data.count <= 256,
              let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("NEANTIK_WEBKIT_STARTUP_FAILURE code=") else { return nil }
        let code = String(line.dropFirst("NEANTIK_WEBKIT_STARTUP_FAILURE code=".count))
        guard code.range(of: "^[A-Za-z0-9.-]{1,80}$", options: .regularExpression) != nil else {
            return nil
        }
        return code
    }

    static func childStartupStage(_ data: Data?) -> String? {
        guard let data, data.count <= 256,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "NEANTIK_WEBKIT_STARTUP_STAGE stage="
        let stages = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            let value = String(line.dropFirst(prefix.count))
            return value.range(of: "^[A-Za-z0-9-]{1,48}$", options: .regularExpression) == nil
                ? nil : value
        }
        return stages.last
    }
}
