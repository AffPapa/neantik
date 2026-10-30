import Darwin
import Foundation

/// Parent-side transport for the pinned WebKit host. It deliberately does not
/// create a window or enable a proxy by itself; BrowserProcessManager must own
/// the profile reservation and broker lease before calling these operations.
actor WebKitHostClient {
    private enum ParentStartStep: String {
        case spawning = "parent-spawning"
        case registering = "parent-registering"
        case closingUnusedEnds = "parent-closing-unused-ends"
        case preparingPipes = "parent-preparing-pipes"
        case verifyingChild = "parent-verifying-child"
        case writingBootstrap = "parent-writing-bootstrap"
        case readingBootstrap = "parent-reading-bootstrap"
        case acceptingBootstrap = "parent-accepting-bootstrap"
    }

    enum ParentWaitPhase: Equatable {
        case bootstrapAcknowledgement
        case networkProcessOwner
        case routeReady

        var userLabel: String {
            switch self {
            case .bootstrapAcknowledgement: "подтверждения профиля"
            case .networkProcessOwner: "идентификации сетевого процесса"
            case .routeReady: "готовности сетевого маршрута"
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        case invalidState
        case invalidChild
        case invalidReply
        case childExited
        case childRefusedStartup(code: String, stage: String? = nil)
        case childStartupTimedOut(stage: String)
        case childStartupClosed(stage: String)
        case parentStartupTimedOut(phase: ParentWaitPhase)
        case cleanupUnconfirmed

        var errorDescription: String? {
            switch self {
            case .invalidState: return "Состояние запуска WebKit изменилось."
            case .invalidChild: return "Не удалось подтвердить подписанный процесс WebKit."
            case .invalidReply: return "Процесс WebKit вернул неожиданный ответ."
            case .childExited: return "Процесс WebKit завершился во время запуска."
            case .childRefusedStartup(let code, _):
                if code == "runtime-ambiguousRuntimeImage" ||
                    code.hasPrefix("runtime-ambiguousImages-") {
                    return "Встроенный WebKit не запущен: одновременно загрузились две версии движка. Это ошибка сборки NeAntik; профиль остался закрыт."
                }
                return "Встроенный WebKit не прошёл проверку запуска. Профиль остался закрыт."
            case .childStartupTimedOut(let stage):
                return "Встроенный WebKit не ответил на этапе запуска (\(stage))."
            case .childStartupClosed(let stage):
                return "Встроенный WebKit закрыл канал на этапе запуска (\(stage))."
            case .parentStartupTimedOut(let phase):
                return "Встроенный WebKit не ответил на этапе \(phase.userLabel)."
            case .cleanupUnconfirmed:
                return "Не удалось подтвердить остановку изолированного WebKit."
            }
        }
    }

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    /// Qualification builds retain only the bounded, fixed-token child trace
    /// through route enrollment. Release builds do not create this channel.
    private let diagnostic: WebKitStartupDiagnosticCapture?
    nonisolated let session: WebKitHostIPC.Session
    private let managerBundle: URL
    private let forgetChild: @Sendable (pid_t, Bool) throws -> Void
    private var gate: WebKitHostCloseGate
    private var activeBroker: WebKitLoopbackBroker?
    private var activeScope: WebKitRelayAuthority.Scope?
    private var closed = false

    private init(process: Process, input: FileHandle, output: FileHandle,
                 diagnostic: WebKitStartupDiagnosticCapture?,
                 session: WebKitHostIPC.Session, managerBundle: URL,
                 acceptedBootstrapGate: WebKitHostCloseGate,
                 forgetChild: @escaping @Sendable (pid_t, Bool) throws -> Void) {
        self.process = process
        self.input = input
        self.output = output
        self.diagnostic = diagnostic
        self.session = session
        self.managerBundle = managerBundle
        self.forgetChild = forgetChild
        // The local launch gate already accepted the child's exact bootstrap.
        // Resetting it here makes issueRelayCapability reject a valid child
        // before any route can be enrolled.
        precondition(acceptedBootstrapGate.expected == session &&
                     acceptedBootstrapGate.state == .awaitingRelayCapability)
        gate = acceptedBootstrapGate
    }

    /// Start only the nested, hash-pinned host. Persist a conservative child
    /// fence immediately after spawn, authenticate the live code before any
    /// session path or proxy credential crosses the pipe, then wait for the
    /// child to confirm its exact profile lock/revision bootstrap.
    static func launch(
        session: WebKitHostIPC.Session,
        registerChild: @escaping @Sendable (pid_t, String) throws -> Void,
        forgetChild: @escaping @Sendable (pid_t, Bool) throws -> Void,
        onUnexpectedTermination: @escaping @Sendable (WebKitHostIPC.Session, Int32) -> Void
    ) async throws -> WebKitHostClient {
        let task = Task.detached { () throws -> WebKitHostClient in
            try Task.checkCancellation()
            guard session.isValid(),
                  let executable = Bundle.main.executableURL,
                  let managerBundle = NeAntikLaunchIntent.applicationBundleURL(
                    forExecutablePath: executable.path),
                  let expectedManagerIdentifier =
                    WebKitHostCodeIdentity.expectedManagerIdentifier(in: managerBundle),
                  let expectedTeamIdentifier =
                    WebKitHostCodeIdentity.expectedTeamIdentifier(in: managerBundle),
                  let parentIdentity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()),
                  parentIdentity.userID == geteuid(),
                  let parentCode = try? ProxyRelayExpectedCode.qualifiedPin(
                    at: executable, expectedIdentifier: expectedManagerIdentifier,
                    expectedTeamIdentifier: expectedTeamIdentifier),
                  ProxyRelayLiveCodeVerifier.matches(processID: getpid(),
                    expectedProcess: parentIdentity, expectedCode: parentCode)
            else { throw Failure.invalidState }

            let (helper, _) = try WebKitHostCodeIdentity.pinnedHelperCode(in: managerBundle)
            let request = Pipe(), reply = Pipe(), child = Process()
            let diagnostic = Pipe()
            child.terminationHandler = { process in
                onUnexpectedTermination(session, process.terminationStatus)
            }
            child.executableURL = helper
            child.arguments = [NeAntikLaunchIntent.webKitHostChildArgument]
            child.standardInput = request
            child.standardOutput = reply
            #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
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
            #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
            let diagnosticReader = WebKitStartupDiagnosticCapture(
                handle: diagnostic.fileHandleForReading)
            #else
            let diagnosticReader: WebKitStartupDiagnosticCapture? = nil
            #endif
            var didRegisterFence = false
            var parentWaitPhase: ParentWaitPhase?
            var parentStartStep: ParentStartStep = .spawning
            do {
                try child.run()
                #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
                try? diagnostic.fileHandleForWriting.close()
                #endif
                didRegisterFence = true
                parentStartStep = .registering
                try registerChild(child.processIdentifier, helper.path)
                parentStartStep = .closingUnusedEnds
                try request.fileHandleForReading.close()
                try reply.fileHandleForWriting.close()
                parentStartStep = .preparingPipes
                try ProxyRelayPrivatePipe.prepare(input.fileDescriptor, writable: true)
                try ProxyRelayPrivatePipe.prepare(output.fileDescriptor, writable: false)
                parentStartStep = .verifyingChild
                guard child.isRunning,
                      WebKitHostCodeIdentity.verifyChild(
                        processID: child.processIdentifier, expectedParentPID: getpid(),
                        managerBundle: managerBundle) != nil
                else { throw Failure.invalidChild }

                parentStartStep = .writingBootstrap
                try WebKitHostIPC.write(.bootstrap(session), to: input.fileDescriptor, timeout: 2)
                parentWaitPhase = .bootstrapAcknowledgement
                parentStartStep = .readingBootstrap
                let frame = try WebKitHostIPC.read(from: output.fileDescriptor, timeout: 10)
                parentWaitPhase = nil
                parentStartStep = .acceptingBootstrap
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
                    diagnostic: diagnosticReader, session: session,
                    managerBundle: managerBundle,
                    acceptedBootstrapGate: gate,
                    forgetChild: forgetChild)
            } catch {
                try? input.close(); try? output.close()
                guard await terminateBounded(child, managerBundle: managerBundle) else {
                    throw Failure.cleanupUnconfirmed
                }
                if didRegisterFence { try? forgetChild(child.processIdentifier, true) }
                #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
                try? diagnostic.fileHandleForWriting.close()
                let diagnosticData = diagnosticReader?.snapshot()
                diagnosticReader?.close()
                if let startupFailure = Self.startupDiagnosticFailure(
                    error: error, data: diagnosticData,
                    parentWaitPhase: parentWaitPhase,
                    parentStartStep: parentStartStep.rawValue) {
                    throw startupFailure
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
        var parentWaitPhase: ParentWaitPhase?
        do {
            guard !closed, process.isRunning, childIsTrusted() else { throw Failure.invalidChild }
            let credentialFrame = try gate.issueRelayCapability(capability)
            try WebKitHostIPC.write(credentialFrame, to: input.fileDescriptor, timeout: 2)
            guard process.isRunning, childIsTrusted() else { throw Failure.childExited }
            parentWaitPhase = .networkProcessOwner
            let frame = try WebKitHostIPC.read(from: output.fileDescriptor, timeout: 10)
            parentWaitPhase = nil
            return try gate.attestNetworkProcessOwner(frame, managerBundle: managerBundle)
        } catch {
            await broker.revoke(scope)
            let beforeAbort = readStartupDiagnostic()
            guard await abort() else { throw Failure.cleanupUnconfirmed }
            let afterAbort = readStartupDiagnostic()
            closeStartupDiagnostic()
            throw Self.startupDiagnosticFailure(
                error: error, data: afterAbort ?? beforeAbort,
                parentWaitPhase: parentWaitPhase) ?? error
        }
    }

    /// Route activation is ordered after live NetworkProcess attestation and
    /// broker lease activation. If either fails, revoke the scope and stop only
    /// this authenticated child; it never receives permission to navigate.
    func activate(scope: WebKitRelayAuthority.Scope,
                  broker: WebKitLoopbackBroker,
                  lease: WebKitNetworkProcessCodeIdentity.Lease) async throws {
        guard scope == expectedScope, lease.scope == scope else { throw Failure.invalidState }
        var parentWaitPhase: ParentWaitPhase?
        do {
            guard !closed, process.isRunning, childIsTrusted() else { throw Failure.invalidChild }
            let frame = try gate.activateRoute(scope: scope) { exactScope in
                try broker.activate(scope: exactScope, lease: lease)
            }
            activeBroker = broker
            activeScope = scope
            try WebKitHostIPC.write(frame, to: input.fileDescriptor, timeout: 2)
            guard process.isRunning, childIsTrusted() else { throw Failure.childExited }
            parentWaitPhase = .routeReady
            let ready = try WebKitHostIPC.read(from: output.fileDescriptor, timeout: 10)
            parentWaitPhase = nil
            try gate.accept(ready)
            guard gate.state == .running else { throw Failure.invalidReply }
        } catch {
            await broker.revoke(scope)
            let beforeAbort = readStartupDiagnostic()
            guard await abort() else { throw Failure.cleanupUnconfirmed }
            let afterAbort = readStartupDiagnostic()
            closeStartupDiagnostic()
            throw Self.startupDiagnosticFailure(
                error: error, data: afterAbort ?? beforeAbort,
                parentWaitPhase: parentWaitPhase) ?? error
        }
    }

    /// Request a graceful close and require save, close, and process-exit
    /// acknowledgements for the same session before releasing the child fence.
    func close() async throws {
        guard !closed else { return }
        if gate.state != .closed {
            if gate.state == .running || gate.state == .failed {
                let childStillRunning = process.isRunning
                if childStillRunning && !childIsTrusted() { throw Failure.invalidChild }
                try gate.requestClose()
                if childStillRunning {
                    do { try WebKitHostIPC.write(.close(session), to: input.fileDescriptor, timeout: 2) }
                    catch {
                        // A user-close can race this write. Only the later
                        // saved+closed frames may prove a successful close.
                        if process.isRunning { throw error }
                    }
                }
            } else if gate.state != .closing && gate.state != .saved {
                throw Failure.invalidState
            }
            // A user-closed child may already have exited, or it may exit as
            // soon as it writes acknowledgements. Drain its authenticated pipe
            // before classifying that normal exit as an unconfirmed save.
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
        _ = readStartupDiagnostic()
        closeStartupDiagnostic()
        closed = true
    }

    var isRunning: Bool { process.isRunning }

    /// Closed-vocabulary QA marker only. Never expose the child's raw stderr.
    func qaCloseStage() -> String? {
        #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
        return Self.childStartupStage(diagnostic?.snapshot())
        #else
        return nil
        #endif
    }

    func qaNavigationStage() -> String? {
        #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
        return Self.childQANavigationStage(diagnostic?.snapshot())
        #else
        return nil
        #endif
    }

    func qaWindowStage() -> String? {
        #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
        return Self.childQAWindowStage(diagnostic?.snapshot())
        #else
        return nil
        #endif
    }

    func qaTLSStage() -> String? {
        #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
        return Self.childQATLSStage(diagnostic?.snapshot())
        #else
        return nil
        #endif
    }

    static func childQATLSStage(_ data: Data?) -> String? {
        guard let data, data.count <= 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "NEANTIK_WEBKIT_QA_TLS stage="
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let value = String(line.dropFirst(prefix.count))
        return WebKitStartupDiagnosticCapture.Tokens.isSafeQATLSStage(value) ? value : nil
    }

    static func childQANavigationStage(_ data: Data?) -> String? {
        guard let data, data.count <= 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "NEANTIK_WEBKIT_QA_NAV stage="
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let value = String(line.dropFirst(prefix.count))
        return WebKitStartupDiagnosticCapture.Tokens.isSafeQANavigationStage(value) ? value : nil
    }

    static func childQAWindowStage(_ data: Data?) -> String? {
        guard let data, data.count <= 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "NEANTIK_WEBKIT_QA_WINDOW stage="
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let value = String(line.dropFirst(prefix.count))
        return WebKitStartupDiagnosticCapture.Tokens.isSafeQAWindowStage(value) ? value : nil
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
        _ = readStartupDiagnostic()
        do { try forgetChild(process.processIdentifier, true) }
        catch { return false }
        closeStartupDiagnostic()
        closed = true
        return true
    }

    /// Drain only already-written bytes from the nonblocking QA pipe. The
    /// child emits fixed stage/error tokens; arbitrary stderr is never shown.
    private func readStartupDiagnostic() -> Data? {
        diagnostic?.snapshot()
    }

    private func closeStartupDiagnostic() {
        diagnostic?.close()
    }

    static func drainAvailableStartupDiagnostic(from fd: Int32, limit: Int = 1024) -> Data {
        guard fd >= 0, (1...1024).contains(limit) else { return Data() }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(1024, limit))
        while result.count < limit {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!, min(raw.count, limit - result.count))
            }
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return result
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
        guard let data, data.count <= 1024,
              let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: {
                  $0.hasPrefix("NEANTIK_WEBKIT_STARTUP_FAILURE code=")
              }) else { return nil }
        let code = String(line.dropFirst("NEANTIK_WEBKIT_STARTUP_FAILURE code=".count))
        guard code.range(of: "^[A-Za-z0-9.-]{1,80}$", options: .regularExpression) != nil else {
            return nil
        }
        return code
    }

    static func childStartupStage(_ data: Data?) -> String? {
        guard let data, data.count <= 1024,
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

    /// Translate only fixed child markers and known pipe termination states.
    /// Arbitrary stderr and error descriptions are never surfaced.
    static func startupDiagnosticFailure(
        error: Error,
        data: Data?,
        parentWaitPhase: ParentWaitPhase? = nil,
        parentStartStep: String? = nil
    ) -> Failure? {
        if let code = childStartupDiagnosticCode(data) {
            #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_DIAGNOSTIC
            if code == "pipe-closed" {
                return .childRefusedStartup(
                    code: "pipe-closed-parent-\(parentStartupCause(error))",
                    stage: childStartupStage(data) ?? parentStartStep)
            }
            #endif
            return .childRefusedStartup(code: code, stage: childStartupStage(data))
        }
        guard let pipeFailure = error as? ProxyRelayPrivatePipe.Failure else {
            return nil
        }
        switch pipeFailure {
        case .timeout:
            if let stage = childStartupStage(data) {
                return .childStartupTimedOut(stage: stage)
            }
            if let parentWaitPhase {
                return .parentStartupTimedOut(phase: parentWaitPhase)
            }
            return nil
        case .closed:
            guard let stage = childStartupStage(data) else { return nil }
            return .childStartupClosed(stage: stage)
        case .unsafeDescriptor, .invalidLimit, .malformed:
            return nil
        }
    }

    /// QA-only closed vocabulary for the manager error that preceded a child
    /// EOF. It distinguishes child failure from a manager abort that closed
    /// its writer; localized error text, paths and profile data are excluded.
    private static func parentStartupCause(_ error: Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .invalidState: return "invalidState"
            case .invalidChild: return "invalidChild"
            case .invalidReply: return "invalidReply"
            case .childExited: return "childExited"
            case .childRefusedStartup: return "childRefused"
            case .childStartupTimedOut, .parentStartupTimedOut: return "timedOut"
            case .childStartupClosed: return "childClosed"
            case .cleanupUnconfirmed: return "cleanupUnconfirmed"
            }
        }
        if let failure = error as? ProxyRelayPrivatePipe.Failure {
            switch failure {
            case .closed: return "pipeClosed"
            case .timeout: return "pipeTimeout"
            case .unsafeDescriptor, .invalidLimit, .malformed: return "pipeInvalid"
            }
        }
        if let failure = error as? WebKitHostLeaseReservation.Failure {
            switch failure {
            case .invalidSession: return "leaseInvalidSession"
            case .dataRootMismatch: return "leaseDataRootMismatch"
            case .invalidProcessIdentity: return "leaseInvalidProcessIdentity"
            case .invalidExecutablePath: return "leaseInvalidExecutablePath"
            case .guardNotHeld: return "leaseGuardNotHeld"
            case .reservationExists: return "leaseReservationExists"
            case .reservationMismatch: return "leaseReservationMismatch"
            case .cleanupUnconfirmed: return "leaseCleanupUnconfirmed"
            }
        }
        if error is WebKitHostIPC.ProtocolError { return "protocol" }
        if error is CancellationError { return "cancelled" }
        if error is POSIXError { return "posix" }
        if error is CocoaError { return "cocoa" }
        return "other"
    }

    /// Close the parent's writer before draining. This also covers a
    /// Process.run() failure where no child inherited the descriptor.
    static func drainStartupDiagnostic(from pipe: Pipe) -> Data {
        try? pipe.fileHandleForWriting.close()
        let capture = WebKitStartupDiagnosticCapture(handle: pipe.fileHandleForReading)
        defer { capture?.close() }
        return capture?.snapshot() ?? Data()
    }
}

/// QA-only stderr observer. Drain concurrently so WebKit logging cannot fill
/// the pipe while the parent waits for IPC. Retain only a last stage and first
/// failure from closed vocabularies, never raw paths, pages or log messages.
final class WebKitStartupDiagnosticCapture: @unchecked Sendable {
    struct Tokens {
        private var line = [UInt8]()
        private var oversized = false
        private var stage: String?
        private var navigationStage: String?
        private var windowStage: String?
        private var tlsStage: String?
        private var failure: String?

        static let qaNavigationStages: Set<String> = [
            "qa-nav-started", "qa-nav-finished", "qa-nav-sentinel", "qa-nav-failed-url", "qa-nav-failed-webkit", "qa-nav-failed-other"
        ]

        static func isSafeQAWindowStage(_ value: String) -> Bool {
            value == "qa-window-visible" || value == "qa-window-not-visible"
        }

        static let qaTLSStages: Set<String> = [
            "qa-tls-challenge", "qa-tls-no-challenge", "qa-tls-no-scope",
            "qa-tls-unowned", "qa-tls-method-other", "qa-tls-method-trust",
            "qa-tls-scope-mismatch", "qa-tls-no-trust", "qa-tls-eval-ok",
            "qa-tls-eval-no-error", "qa-tls-accepted", "qa-tls-scope-installed"
        ]

        static func isSafeQATLSStage(_ value: String) -> Bool {
            if qaTLSStages.contains(value) { return true }
            return value.range(
                of: "^qa-tls-(policies|anchors|anchoronly|netfetch)-(ok|other|(m|p)[0-9]{1,6})$",
                options: .regularExpression) != nil ||
                value.range(
                    of: "^qa-tls-eval-(other|(m|p)[0-9]{1,6})$",
                    options: .regularExpression) != nil
        }

        static func isSafeQANavigationStage(_ value: String) -> Bool {
            if qaNavigationStages.contains(value) { return true }
            guard let prefix = ["qa-nav-url-code-", "qa-nav-webkit-code-", "qa-nav-other-code-"]
                .first(where: value.hasPrefix) else { return false }
            let suffix = String(value.dropFirst(prefix.count))
            guard suffix.range(of: "^[mp](0|[1-9][0-9]{0,5})$", options: .regularExpression) != nil,
                  let number = Int(suffix.dropFirst()), number <= 100_000 else { return false }
            return suffix.first == "m" ? number > 0 : true
        }

        static let stages: Set<String> = [
            "host-entry", "appkit-created", "event-loop-starting", "child-entry",
            "identity-verified", "runtime-attested", "pipes-ready",
            "bootstrap-received", "profile-acquired", "bootstrap-accepted",
            "capability-received", "browser-created", "browser-runtime-attested",
            "network-owner-resolved", "network-runtime-attested",
            "network-owner-sent", "route-activation-received", "route-activated",
            "qa-tls-scope-present", "qa-tls-bundle-authorized", "qa-tls-bundle-denied",
            "qa-tls-root-authorized", "qa-tls-root-denied",
            "qa-tls-host-authorized", "qa-tls-host-denied",
            "qa-tls-settings-invalid", "qa-tls-settings-valid", "qa-tls-scope-created",
            "qa-tls-scope-install-rejected",
            "qa-nav-started", "qa-nav-finished", "qa-nav-sentinel", "qa-nav-failed-url", "qa-nav-failed-webkit", "qa-nav-failed-other",
            "qa-window-visible", "qa-window-not-visible",
            "visible-runtime-attested", "ready-sent", "close-request-received",
            "close-main", "close-callback", "parent-spawning",
            "parent-registering", "parent-closing-unused-ends",
            "parent-preparing-pipes", "parent-verifying-child",
            "parent-writing-bootstrap", "parent-reading-bootstrap",
            "parent-accepting-bootstrap"
        ]
        static let failures: Set<String> = {
            let groups: [String: [String]] = [
                "identity": ["malformedPin", "unsafeBundle", "hostHashMismatch", "codeIdentityMismatch", "parentIdentityMismatch"],
                "runtime": ["malformedPin", "unsafeBundle", "missingRuntimeImage", "ambiguousRuntimeImage", "wrongRuntimeImage", "runtimeHashMismatch", "unsupportedOperatingSystem"],
                "pipe": ["unsafeDescriptor", "invalidLimit", "timeout", "closed", "malformed"],
                "protocol": ["malformedFrame", "oversizedFrame", "invalidSession", "invalidCapability", "invalidProcessOwner", "invalidTransition", "prematureEOF"],
                "profile": ["invalidRoot", "profileUnavailable", "profileMismatch", "runtimeMismatch", "reservationMismatch"],
                "lease": ["invalidSession", "unsafeFile", "unopenableFile", "unreadableFile",
                          "changedFile", "decodeFailed", "schemaMismatch", "pidMismatch",
                          "managerMismatch", "generationMismatch", "executableMismatch",
                          "dataPathMismatch"],
                "network": ["imageNotLoaded", "symbolMissing", "processStarting", "processStartupTimedOut", "invalidProcessIdentifier", "invalidProcessIdentity"]
            ]
            let fixed = Set(groups.flatMap { prefix, values in values.map { prefix + "-" + $0 } })
            let parentCauses = ["invalidState", "invalidChild", "invalidReply", "childExited",
                                "childRefused", "timedOut", "childClosed", "cleanupUnconfirmed",
                                "pipeClosed", "pipeTimeout", "pipeInvalid", "protocol",
                                "cancelled", "posix", "cocoa", "other",
                                "leaseInvalidSession", "leaseDataRootMismatch",
                                "leaseInvalidProcessIdentity", "leaseInvalidExecutablePath",
                                "leaseGuardNotHeld", "leaseReservationExists",
                                "leaseReservationMismatch", "leaseCleanupUnconfirmed"]
            return fixed.union(["startup-unknown"])
                .union(parentCauses.map { "pipe-closed-parent-" + $0 })
        }()

        static func isSafeFailureCode(_ value: String) -> Bool {
            failures.contains(value) || isPOSIXCode(value) || isImageMultiplicity(value)
        }

        mutating func append(_ data: Data) {
            for byte in data {
                if byte == 10 {
                    if !oversized {
                        let data = Data(line)
                        if let value = WebKitHostClient.childStartupStage(data),
                           Self.stages.contains(value) || Self.isSafeQANavigationStage(value) ||
                           Self.isSafeQAWindowStage(value) ||
                           Self.isSafeQATLSStage(value) {
                            stage = value
                            if Self.isSafeQANavigationStage(value) { navigationStage = value }
                            if Self.isSafeQAWindowStage(value) { windowStage = value }
                            if Self.isSafeQATLSStage(value) { tlsStage = value }
                        }
                        if failure == nil, let value = WebKitHostClient.childStartupDiagnosticCode(data),
                           Self.isSafeFailureCode(value) {
                            failure = value
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                    oversized = false
                } else if !oversized {
                    if line.count < 160 { line.append(byte) }
                    else { line.removeAll(keepingCapacity: true); oversized = true }
                }
            }
        }

        private static func isPOSIXCode(_ value: String) -> Bool {
            guard value.hasPrefix("posix-"),
                  let number = Int32(value.dropFirst(6)),
                  value == "posix-\(number)", POSIXErrorCode(rawValue: number) != nil
            else { return false }
            return true
        }

        private static func isImageMultiplicity(_ value: String) -> Bool {
            value.range(of: "^runtime-ambiguousImages-owned[0-9]-system[0-9]-other[0-9](-entry[0-9]-appkit[0-9])?$",
                        options: .regularExpression) != nil
        }

        var snapshot: Data {
            var result = ""
            if let stage { result += "NEANTIK_WEBKIT_STARTUP_STAGE stage=\(stage)\n" }
            if let navigationStage { result += "NEANTIK_WEBKIT_QA_NAV stage=\(navigationStage)\n" }
            if let windowStage { result += "NEANTIK_WEBKIT_QA_WINDOW stage=\(windowStage)\n" }
            if let tlsStage { result += "NEANTIK_WEBKIT_QA_TLS stage=\(tlsStage)\n" }
            if let failure { result += "NEANTIK_WEBKIT_STARTUP_FAILURE code=\(failure)\n" }
            return Data(result.utf8)
        }
    }

    private let queue = DispatchQueue(label: "app.neantik.webkit.startup-diagnostic")
    private let source: DispatchSourceRead
    private let fd: Int32
    private var tokens = Tokens()
    private var closed = false

    init?(handle: FileHandle) {
        fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            try? handle.close()
            return nil
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    func snapshot() -> Data {
        queue.sync { drain(); return tokens.snapshot }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            drain()
            closed = true
            source.cancel()
        }
    }

    deinit { source.cancel() }

    /// Bound each observation even if a producer writes continuously. The
    /// dispatch source schedules remaining bytes separately from IPC work.
    private func drain() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count > 0 { tokens.append(Data(buffer.prefix(count))) }
            else if count < 0, errno == EINTR { continue }
            else {
                if count == 0 { closed = true; source.cancel() }
                break
            }
        }
    }
}
