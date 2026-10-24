import AppKit
import Darwin
import Foundation

/// Early child entry point. It authenticates the nested helper and loaded
/// runtime before reading profile metadata, then accepts only the parent's
/// exact session and route activation. No system-WebKit fallback exists.
enum WebKitHostChildRuntime {
    @MainActor
    private final class Lifetime {
        var bootstrap: WebKitHostChildBootstrap?
        var browser: WebKitProfileBrowser?
        var finished = false
    }

    /// The pipe reader runs off the main thread. The custom AppKit pump does
    /// not provide NSApplication.run's MainActor scheduling guarantee, so hand
    /// its close request to the pump instead of enqueuing a MainActor task.
    private final class CloseRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false

        func request() {
            lock.lock()
            pending = true
            lock.unlock()
        }

        func consume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let result = pending
            pending = false
            return result
        }
    }

    @MainActor
    static func runAndExit() -> Never {
        let systemAtEntry = WebKitRuntimeImageAttestation.systemImageCount()
        recordStartupStage("host-entry")
        let lifetime = Lifetime()
        let closeRequest = CloseRequest()
        let app = NSApplication.shared
        let checkpoint = WebKitRuntimeImageAttestation.StartupCheckpoint(
            systemAtEntry: systemAtEntry,
            systemAfterAppKit: WebKitRuntimeImageAttestation.systemImageCount())
        recordStartupStage("appkit-created")
        app.setActivationPolicy(.regular)
        let startup = Task { @MainActor in
            do {
                try await prepareAndShow(lifetime: lifetime,
                                         closeRequest: closeRequest,
                                         startupCheckpoint: checkpoint)
            } catch {
                refuse("NEANTIK_WEBKIT_STARTUP_FAILURE code=\(safeFailureCode(error))\n",
                       code: EX_UNAVAILABLE)
            }
        }
        // NSApplication.run() loads the system WebKit image on macOS even in a
        // host linked only to our bundled framework. Pump AppKit events and the
        // main run loop without calling it; keep the image attestation strict.
        // WebKit's XPC completion still needs the main queue during bootstrap.
        recordStartupStage("event-loop-starting")
        while !lifetime.finished {
            autoreleasepool {
                if let event = app.nextEvent(matching: .any,
                                             until: Date(timeIntervalSinceNow: 0.05),
                                             inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
                app.updateWindows()
                if closeRequest.consume() {
                    recordStartupStage("close-main")
                    lifetime.browser?.close()
                }
            }
        }
        startup.cancel()
        lifetime.bootstrap?.releaseAfterClose()
        Darwin.exit(EXIT_SUCCESS)
    }

    @MainActor
    private static func prepareAndShow(
        lifetime: Lifetime,
        closeRequest: CloseRequest,
        startupCheckpoint: WebKitRuntimeImageAttestation.StartupCheckpoint
    ) async throws {
        recordStartupStage("child-entry")
        guard WebKitHostCodeIdentity.isSupportedHostIdentifier(Bundle.main.bundleIdentifier) else {
            throw WebKitHostCodeIdentity.Failure.unsafeBundle
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        try WebKitHostCodeIdentity.verifyCurrentHostAndParent(
            executablePath: executable, expectedParentPID: getppid())
        recordStartupStage("identity-verified")
        let runtime = try WebKitRuntimeImageAttestation.attestCurrentProcess(
            startupCheckpoint: startupCheckpoint)
        recordStartupStage("runtime-attested")

        try ProxyRelayPrivatePipe.prepare(STDIN_FILENO, writable: false)
        try ProxyRelayPrivatePipe.prepare(STDOUT_FILENO, writable: true)
        recordStartupStage("pipes-ready")
        let bootstrapFrame = try await readStartupFrame(timeout: 10)
        guard case .bootstrap(let session) = bootstrapFrame,
              session.runtimeSHA256 == runtime.sha256 else {
            throw WebKitHostIPC.ProtocolError.invalidSession
        }
        recordStartupStage("bootstrap-received")

        let child = try WebKitHostChildBootstrap.acquire(
            session: session, expectedRuntimeSHA256: runtime.sha256)
        lifetime.bootstrap = child
        recordStartupStage("profile-acquired")
        try WebKitHostIPC.write(.bootstrapAccepted(session), to: STDOUT_FILENO)
        recordStartupStage("bootstrap-accepted")

        let capabilityFrame = try await readStartupFrame(timeout: 10)
        guard case .relayCapability(let capabilitySession, let credential) = capabilityFrame,
              capabilitySession == session, credential.belongs(to: session) else {
            throw WebKitHostIPC.ProtocolError.invalidCapability
        }
        recordStartupStage("capability-received")

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
            onQANavigation: { phase, domain, code in
                // The parent retains only these fixed QA phase names. This
                // survives even when the child's private file marker cannot
                // be written, so a zero-request run has a useful boundary.
                if phase == "started" {
                    recordStartupStage("qa-nav-started")
                } else if phase == "failed", ["url", "webkit", "other"].contains(domain) {
                    recordStartupStage("qa-nav-failed-\(domain)")
                    // The sandboxed child may not write its private QA file.
                    // Forward only a bounded numeric NSURL code, never the URL
                    // or NSError userInfo, through the parent's validated pipe.
                    if domain == "url", (-100_000...100_000).contains(code) {
                        let sign = code < 0 ? "m" : "p"
                        recordStartupStage("qa-nav-url-code-\(sign)\(abs(code))")
                    }
                }
                recordQANavigation(phase: phase, domain: domain, code: code,
                                   profileID: session.profileID, root: child.paths.rootDirectory)
            },
            onClose: {
                recordStartupStage("close-callback")
                try? WebKitHostIPC.write(.saved(session), to: STDOUT_FILENO)
                try? WebKitHostIPC.write(.closed(session), to: STDOUT_FILENO)
                lifetime.finished = true
            })
        lifetime.browser = browser
        recordStartupStage("browser-created")
        #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
        // The public host has no trust override. A private Dev candidate may
        // pin one synthetic CA and exact HTTPS origins in its signed plist.
        // Install this before NetworkProcess activation and first navigation;
        // never load an anchor from a mutable profile, environment or Keychain.
        if let value = Bundle.main.object(forInfoDictionaryKey: "NeAntikQATrustScope") {
            guard Bundle.main.bundleIdentifier == "app.neantik.desktop.dev.webkit-host",
                  let setting = value as? [String: Any],
                  let anchor = setting["anchorDER"] as? Data,
                  let originStrings = setting["origins"] as? [String] else {
                throw WebKitProfileError.unsupported("QA TLS trust scope invalid")
            }
            let origins = originStrings.compactMap { URL(string: $0) }
            guard origins.count == originStrings.count,
                  let scope = try? WebKitQATrustScope(caDER: anchor, origins: origins),
                  browser.installQATrustScope(scope, onStage: { stage in
                      guard isQATLSStage(stage) else { return }
                      recordStartupStage(stage)
                  }) else {
                throw WebKitProfileError.unsupported("QA TLS trust scope invalid")
            }
            recordStartupStage("qa-tls-scope-installed")
        }
        #endif
        // Creating WKWebView must not pull the system framework into this
        // process after the early check. Refuse before route activation.
        _ = try WebKitRuntimeImageAttestation.attestCurrentProcess(
            startupCheckpoint: startupCheckpoint)
        recordStartupStage("browser-runtime-attested")

        let owner = WebKitHostIPC.NetworkProcessOwner(try await browser.networkProcessOwnerForBootstrap())
        recordStartupStage("network-owner-resolved")
        _ = try WebKitRuntimeImageAttestation.attestCurrentProcess(
            startupCheckpoint: startupCheckpoint)
        recordStartupStage("network-runtime-attested")
        var routeGate = WebKitHostChildRouteGate(expected: session)
        let ownerFrame = try routeGate.reportNetworkProcess(owner)
        try WebKitHostIPC.write(ownerFrame, to: STDOUT_FILENO)
        recordStartupStage("network-owner-sent")
        let activationFrame = try await readStartupFrame(timeout: 15)
        let permit = try routeGate.acceptRouteActivation(activationFrame)
        recordStartupStage("route-activation-received")
        guard browser.activateOwnedRoute(permit) else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        recordStartupStage("route-activated")

        browser.show()
        _ = try WebKitRuntimeImageAttestation.attestCurrentProcess(
            startupCheckpoint: startupCheckpoint)
        recordStartupStage("visible-runtime-attested")
        try WebKitHostIPC.write(try routeGate.readyFrame(), to: STDOUT_FILENO)
        recordStartupStage("ready-sent")
        startCloseListener(session: session, closeRequest: closeRequest)
    }

    /// Exactly one startup reader is active at a time. Waiting on the parent
    /// must not prevent WebKit's main-queue XPC launch callbacks from running.
    private static func readStartupFrame(timeout: TimeInterval) async throws -> WebKitHostIPC.Frame {
        let reader = Task.detached(priority: .userInitiated) {
            try WebKitHostIPC.read(from: STDIN_FILENO, timeout: timeout)
        }
        return try await withTaskCancellationHandler(operation: {
            let frame = try await reader.value
            try Task.checkCancellation()
            return frame
        }, onCancel: { reader.cancel() })
    }

    /// Stable diagnostic labels contain only closed error enums or POSIX
    /// numbers; they never include profile paths, URLs, or proxy credentials.
    private static func safeFailureCode(_ error: Error) -> String {
        #if NEANTIK_WEBKIT_STANDALONE_HOST
        if let value = error as? WebKitHostLeaseReservation.Failure {
            return "lease-\(value.diagnosticCode)"
        }
        #endif
        if let value = error as? WebKitRuntimeImageAttestation.AmbiguousImageDiagnostic {
            return "runtime-\(value.code)"
        }
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
        if let value = error as? WebKitOwnedNetworkProcessPID.Failure {
            return "network-\(value)"
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
                                           closeRequest: CloseRequest) {
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                do {
                    let frame = try WebKitHostIPC.read(from: STDIN_FILENO, timeout: 10)
                    guard case .close(let received) = frame, received == session else {
                        closeRequest.request()
                        return
                    }
                    recordStartupStage("close-request-received")
                    closeRequest.request()
                    return
                } catch ProxyRelayPrivatePipe.Failure.timeout {
                    continue
                } catch {
                    closeRequest.request()
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
        #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION
        guard stage.range(of: "^[A-Za-z0-9-]{1,48}$", options: .regularExpression) != nil,
              let data = "NEANTIK_WEBKIT_STARTUP_STAGE stage=\(stage)\n".data(using: .utf8)
        else { return }
        try? FileHandle.standardError.write(contentsOf: data)
        #endif
    }

    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
    /// The browser can forward only these fixed TLS phases and bounded
    /// Security codes. Never forward a URL, certificate, hostname or NSError.
    private static func isQATLSStage(_ stage: String) -> Bool {
        let fixed: Set<String> = [
            "qa-tls-challenge", "qa-tls-no-challenge", "qa-tls-no-scope",
            "qa-tls-unowned", "qa-tls-method-other", "qa-tls-method-trust",
            "qa-tls-scope-mismatch", "qa-tls-no-trust", "qa-tls-eval-ok",
            "qa-tls-eval-no-error", "qa-tls-accepted"
        ]
        if fixed.contains(stage) { return true }
        return stage.range(of:
            "^qa-tls-(?:(?:policies|anchors|anchoronly|netfetch)-(?:ok|m[0-9]{1,6}|p[0-9]{1,6}|other)|eval-(?:m[0-9]{1,6}|p[0-9]{1,6}|other))$",
            options: .regularExpression) != nil
    }
    #endif

    /// A disposable Dev-only route diagnostic. The file contains a fixed
    /// phase and NSError category/code, never a URL or profile contents.
    private static func recordQANavigation(phase: String, domain: String, code: Int,
                                           profileID: UUID, root: URL) {
        #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.dev.webkit-host",
              (phase == "started" || phase == "failed"),
              ["none", "url", "webkit", "other"].contains(domain),
              (-100_000...100_000).contains(code),
              root.path.hasPrefix("/private/tmp/neantik-") else { return }
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_mode & 0o777 == 0o700,
              metadata.st_uid == geteuid() else { return }
        let path = root.appendingPathComponent("qa-nav-\(profileID.uuidString)-\(phase).txt").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let bytes = Array("phase=\(phase) domain=\(domain) code=\(code)\n".utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if count != bytes.count || fsync(descriptor) != 0 { _ = unlink(path) }
        #endif
    }

}
