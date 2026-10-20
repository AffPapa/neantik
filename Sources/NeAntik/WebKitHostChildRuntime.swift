import AppKit
import Darwin
import Foundation

/// Early child entry point. It authenticates the nested helper and loaded
/// runtime before reading profile metadata, then accepts only the parent's
/// exact session and route activation. No system-WebKit fallback exists.
enum WebKitHostChildRuntime {
    @MainActor
    static func runAndExit() -> Never {
        var bootstrap: WebKitHostChildBootstrap?
        defer { bootstrap?.releaseAfterClose() }
        do {
            recordStartupStage("child-entry")
            guard WebKitHostCodeIdentity.isSupportedHostIdentifier(Bundle.main.bundleIdentifier) else {
                throw WebKitHostCodeIdentity.Failure.unsafeBundle
            }
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            try WebKitHostCodeIdentity.verifyCurrentHostAndParent(
                executablePath: executable, expectedParentPID: getppid())
            recordStartupStage("identity-verified")
            let runtime = try WebKitRuntimeImageAttestation.attestCurrentProcess()
            recordStartupStage("runtime-attested")

            try ProxyRelayPrivatePipe.prepare(STDIN_FILENO, writable: false)
            try ProxyRelayPrivatePipe.prepare(STDOUT_FILENO, writable: true)
            recordStartupStage("pipes-ready")
            let bootstrapFrame = try WebKitHostIPC.read(from: STDIN_FILENO, timeout: 10)
            guard case .bootstrap(let session) = bootstrapFrame,
                  session.runtimeSHA256 == runtime.sha256 else {
                throw WebKitHostIPC.ProtocolError.invalidSession
            }
            recordStartupStage("bootstrap-received")

            let child = try WebKitHostChildBootstrap.acquire(
                session: session, expectedRuntimeSHA256: runtime.sha256)
            bootstrap = child
            recordStartupStage("profile-acquired")
            try WebKitHostIPC.write(.bootstrapAccepted(session), to: STDOUT_FILENO)
            recordStartupStage("bootstrap-accepted")

            let capabilityFrame = try WebKitHostIPC.read(from: STDIN_FILENO, timeout: 10)
            guard case .relayCapability(let capabilitySession, let credential) = capabilityFrame,
                  capabilitySession == session, credential.belongs(to: session) else {
                throw WebKitHostIPC.ProtocolError.invalidCapability
            }

            let sessionStore = WebKitSessionStore(paths: child.paths)
            var restored: WebKitSessionSnapshot?
            var sessionWarning: String?
            if child.profile.startupMode == .restoreSession {
                do { restored = try sessionStore.load(for: child.profile.id) }
                catch { sessionWarning = "Сохранённые вкладки недоступны. Открыта стартовая страница; исходные данные не изменены." }
            }
            let guards = try child.browserGuardLeases()
            let browser = try WebKitProfileBrowser(
                profile: child.profile, lease: guards.session,
                metadataLease: guards.metadata, sessionGeneration: session.generation,
                sessionStore: sessionStore, restoredSession: restored,
                sessionWarning: sessionWarning,
                runtime: .owned(session: session, relayCredential: credential),
                onSessionSaveError: {
                    try? WebKitHostIPC.write(.saveFailed(session, reason: .writeFailed),
                                             to: STDOUT_FILENO)
                },
                onClose: {
                    try? WebKitHostIPC.write(.saved(session), to: STDOUT_FILENO)
                    try? WebKitHostIPC.write(.closed(session), to: STDOUT_FILENO)
                    NSApplication.shared.terminate(nil)
                })

            let owner = WebKitHostIPC.NetworkProcessOwner(try browser.networkProcessOwnerForBootstrap())
            try WebKitHostIPC.write(.networkProcessOwner(session, owner), to: STDOUT_FILENO)
            var routeGate = WebKitHostChildRouteGate(expected: session)
            let activationFrame = try WebKitHostIPC.read(from: STDIN_FILENO, timeout: 15)
            let permit = try routeGate.acceptRouteActivation(activationFrame)
            guard browser.activateOwnedRoute(permit) else {
                throw WebKitHostIPC.ProtocolError.invalidTransition
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            browser.show()
            try WebKitHostIPC.write(try routeGate.readyFrame(), to: STDOUT_FILENO)
            startCloseListener(session: session, browser: browser)
            app.run()
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            refuse("NEANTIK_WEBKIT_STARTUP_FAILURE code=\(safeFailureCode(error))\n",
                   code: EX_UNAVAILABLE)
        }
    }

    /// Stable diagnostic labels contain only closed error enums or POSIX
    /// numbers; they never include profile paths, URLs, or proxy credentials.
    private static func safeFailureCode(_ error: Error) -> String {
        if let value = error as? WebKitHostCodeIdentity.Failure {
            return "identity-\(value)"
        }
        if let value = error as? WebKitRuntimeImageAttestation.Failure {
            return "runtime-\(value)"
        }
        if let value = error as? ProxyRelayPrivatePipe.Failure {
            return "pipe-\(value)"
        }
        if let value = error as? WebKitHostIPC.ProtocolError {
            return "protocol-\(value)"
        }
        if let value = error as? WebKitHostChildBootstrap.Failure {
            return "profile-\(value)"
        }
        if let value = error as? POSIXError {
            return "posix-\(value.code.rawValue)"
        }
        return "startup-unknown"
    }

    /// The parent may request a close while AppKit is running. An EOF also
    /// closes this child so a lost controller cannot leave a detached browser
    /// with an unobservable broker lease.
    private static func startCloseListener(session: WebKitHostIPC.Session,
                                           browser: WebKitProfileBrowser) {
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                do {
                    let frame = try WebKitHostIPC.read(from: STDIN_FILENO, timeout: 10)
                    guard case .close(let received) = frame, received == session else {
                        Task { @MainActor in browser.close() }
                        return
                    }
                    Task { @MainActor in browser.close() }
                } catch ProxyRelayPrivatePipe.Failure.timeout {
                    continue
                } catch {
                    Task { @MainActor in browser.close() }
                    return
                }
            }
        }
    }

    private static func refuse(_ message: String, code: Int32) -> Never {
        if let data = message.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
        Darwin.exit(code)
    }

    /// Debug-only, fixed startup markers let the parent distinguish a helper
    /// load/identity stall from IPC or profile-lock startup. They contain no
    /// paths, profile data, URLs, or credentials and are absent from Release.
    private static func recordStartupStage(_ stage: String) {
        #if DEBUG
        guard stage.range(of: "^[A-Za-z0-9-]{1,48}$", options: .regularExpression) != nil,
              let data = "NEANTIK_WEBKIT_STARTUP_STAGE stage=\(stage)\n".data(using: .utf8)
        else { return }
        try? FileHandle.standardError.write(contentsOf: data)
        #endif
    }
}
