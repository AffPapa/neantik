import Darwin
import Foundation

/// Persistent signed owner for authenticated profile relay sessions.
/// A successful bind survives manager EOF. Browser identity/code loss drains
/// the listener and every established stream. It never owns BrowserData or
/// Keychain and never exposes a public control/debugging endpoint.
enum ProxyRelayOwner {
    private static let team = "H6VGU2M6JD"
    private final class ObservationActivation: @unchecked Sendable {
        private let lock = NSLock(); private var active = false
        func set(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
        var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    }
    private final class AuthorityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ProxyRelaySessionAuthority?
        func bind(_ value: ProxyRelaySessionAuthority) { lock.lock(); self.value = value; lock.unlock() }
        func admit(_ peer: ProxyRelayLoopbackServer.Peer) -> Bool {
            lock.lock(); let value = value; lock.unlock()
            return value?.admits(peer) ?? false
        }
    }

    static func runAndExit() -> Never {
        Task.detached {
            do { try await run(); Darwin.exit(EX_OK) }
            catch { Darwin.exit(EX_NOPERM) } // opaque: native errors can contain paths/secrets
        }
        dispatchMain()
    }
    private static func run() async throws {
        try ProxyRelayPrivatePipe.prepare(STDIN_FILENO, writable: false)
        try ProxyRelayPrivatePipe.prepare(STDOUT_FILENO, writable: true)
        let parentPID = getppid()
        guard parentPID > 1, let parentIdentity = ProxyRelaySocketOwnerInspector.processIdentity(parentPID),
              let ownID = Bundle.main.bundleIdentifier, let ownExecutable = Bundle.main.executableURL
        else { throw ProxyRelayOwnerProtocol.Failure.invalidBootstrap }
        let managerCode = try ProxyRelayExpectedCode.qualifiedPin(at: ownExecutable, expectedIdentifier: ownID, expectedTeamIdentifier: team)
        guard ProxyRelayLiveCodeVerifier.matches(processID: parentPID, expectedProcess: parentIdentity, expectedCode: managerCode)
        else { throw ProxyRelayOwnerProtocol.Failure.invalidBootstrap }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let bootstrap = try decoder.decode(ProxyRelayOwnerProtocol.Bootstrap.self,
            from: ProxyRelayPrivatePipe.readFrame(STDIN_FILENO, timeout: 5))
        try bootstrap.validate()
        guard let resources = Bundle.main.resourceURL else { throw ProxyRelayOwnerProtocol.Failure.invalidBootstrap }
        let app = resources.appendingPathComponent("NeAntik Browser.app", isDirectory: true)
        guard let bundle = Bundle(url: app), let executable = bundle.executableURL,
              bundle.bundleIdentifier == "app.neantik.runtime"
        else { throw ProxyRelayOwnerProtocol.Failure.invalidBootstrap }
        let inspection = BrowserRuntimeInspector.inspect(executableURL: executable)
        guard inspection.codeSignatureValid == true, inspection.supportsAppleSilicon,
              inspection.version == bootstrap.runtimeVersion,
              inspection.executableSHA256 == bootstrap.runtimeExecutableSHA256,
              inspection.frameworkSHA256 == bootstrap.runtimeFrameworkSHA256
        else { throw ProxyRelayOwnerProtocol.Failure.invalidBootstrap }
        let helper = app.appendingPathComponent("Contents/Frameworks/NeAntik Browser Framework.framework/Versions/" + bootstrap.runtimeVersion + "/Helpers/NeAntik Browser Helper.app", isDirectory: true)
        let mainCode = try ProxyRelayExpectedCode.qualifiedPin(at: executable, expectedIdentifier: "app.neantik.runtime", expectedTeamIdentifier: team)
        let helperCode = try ProxyRelayExpectedCode.qualifiedPin(at: helper, expectedIdentifier: "app.neantik.runtime.helper", expectedTeamIdentifier: team)
        guard ProxyRelaySocketOwnerInspector.processIdentity(parentPID) == parentIdentity,
              ProxyRelayLiveCodeVerifier.matches(processID: parentPID, expectedProcess: parentIdentity, expectedCode: managerCode)
        else { throw ProxyRelayOwnerProtocol.Failure.invalidBootstrap }
        let gate = try ProxyRelayBindingGate(), box = AuthorityBox()
        let credentials = bootstrap.username.isEmpty ? nil : try ProxyRelayCredentials(username: bootstrap.username, password: bootstrap.password)
        let routeProbe = try bootstrap.routeProbe.map { try BrowserRouteProbe.Session(plan: $0) }
        let relay: ProxyRelayLoopbackServer
        #if DEBUG
        if let anchor = bootstrap.qualificationAnchorDER {
            guard ownID == "app.neantik.desktop.relay-qualification" else { throw ProxyRelayOwnerProtocol.Failure.invalidBootstrap }
            relay = try ProxyRelayLoopbackServer(qualification: .init(anchorDER: anchor),
                upstream: .init(host: bootstrap.host, port: bootstrap.port), credentials: credentials, routeProbe: routeProbe,
                waitForBinding: { try await gate.wait() }, admit: { box.admit($0) })
        } else {
            relay = try ProxyRelayLoopbackServer(upstreamKind: bootstrap.kind,
                upstream: .init(host: bootstrap.host, port: bootstrap.port), credentials: credentials, routeProbe: routeProbe,
                waitForBinding: { try await gate.wait() }, admit: { box.admit($0) })
        }
        #else
        relay = try ProxyRelayLoopbackServer(upstreamKind: bootstrap.kind,
            upstream: .init(host: bootstrap.host, port: bootstrap.port), credentials: credentials, routeProbe: routeProbe,
            waitForBinding: { try await gate.wait() }, admit: { box.admit($0) })
        #endif
        var authority: ProxyRelaySessionAuthority?
        var observation: ProxyRelayObservationSocket.Server?
        let observationActivation = ObservationActivation()
        do {
            let port = try await relay.start()
            try ProxyRelayPrivatePipe.writeFrame(STDOUT_FILENO,
                data: encoder.encode(ProxyRelayOwnerProtocol.Ready(schemaVersion: 1, nonce: bootstrap.nonce, port: port)), timeout: 2)
            let bind = try decoder.decode(ProxyRelayOwnerProtocol.Bind.self,
                from: ProxyRelayPrivatePipe.readFrame(STDIN_FILENO, timeout: 5))
            guard let browser = ProxyRelaySocketOwnerInspector.processIdentity(bind.browserPID),
                  ProxyRelaySocketOwnerInspector.processIdentity(parentPID) == parentIdentity,
                  ProxyRelayLiveCodeVerifier.matches(processID: parentPID, expectedProcess: parentIdentity, expectedCode: managerCode)
            else { throw ProxyRelayOwnerProtocol.Failure.invalidBinding }
            try bind.validate(bootstrap: bootstrap, observed: browser, originalParentPID: parentPID)
            let binding = try ProxyRelaySessionAuthority.Binding(profileID: bootstrap.profileID, sessionGeneration: bootstrap.sessionGeneration,
                runtimeExecutableSHA256: bootstrap.runtimeExecutableSHA256, runtimeFrameworkSHA256: bootstrap.runtimeFrameworkSHA256,
                configurationSHA256: bootstrap.configurationSHA256, browserPID: bind.browserPID, browserIdentity: browser)
            let admitted = ProxyRelaySessionAuthority(binding: binding, inspector: .live(mainCode: mainCode, helperCode: helperCode))
            guard admitted.browserIsAlive() else { throw ProxyRelayOwnerProtocol.Failure.invalidBinding }
            authority = admitted; box.bind(admitted)
            try ProxyRelayPrivatePipe.writeFrame(STDOUT_FILENO,
                data: encoder.encode(ProxyRelayOwnerProtocol.Bound(schemaVersion: 1, nonce: bootstrap.nonce, bound: true)), timeout: 2)
            // Binding is not activation. Parent must commit its running lease
            // first; broken acknowledgement/EOF keeps held connections inert.
            let commit = try decoder.decode(ProxyRelayOwnerProtocol.Commit.self,
                from: ProxyRelayPrivatePipe.readFrame(STDIN_FILENO, timeout: 5))
            guard commit.schemaVersion == 1, commit.nonce == bootstrap.nonce, admitted.browserIsAlive(),
                  ProxyRelaySocketOwnerInspector.processIdentity(parentPID) == parentIdentity,
                  ProxyRelayLiveCodeVerifier.matches(processID: parentPID, expectedProcess: parentIdentity, expectedCode: managerCode)
            else { throw ProxyRelayOwnerProtocol.Failure.invalidBinding }
            guard let ownerIdentity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()) else { throw ProxyRelayOwnerProtocol.Failure.invalidBinding }
            let observationBinding = ProxyRelayObservationProtocol.Binding(profileID: bootstrap.profileID,
                sessionGeneration: bootstrap.sessionGeneration, profileRevision: bootstrap.profileRevision,
                runtimeExecutableSHA256: bootstrap.runtimeExecutableSHA256, runtimeFrameworkSHA256: bootstrap.runtimeFrameworkSHA256,
                configurationSHA256: bootstrap.configurationSHA256,
                owner: .init(pid: getpid(), identity: ownerIdentity), browser: .init(pid: bind.browserPID, identity: browser))
            observation = try ProxyRelayObservationSocket.start(binding: observationBinding, expectedManagerCode: managerCode,
                sessionValid: { observationActivation.isActive && admitted.browserIsAlive() }, snapshot: { relay.activitySnapshot() },
                routeSnapshot: { routeProbe?.snapshot() })
            try routeProbe?.activate(port: port)
            try ProxyRelayPrivatePipe.writeFrame(STDOUT_FILENO,
                data: encoder.encode(ProxyRelayOwnerProtocol.Active(schemaVersion: 1, nonce: bootstrap.nonce, active: true)), timeout: 2)
            try await gate.open()
            observationActivation.set(true)
            _ = Darwin.close(STDIN_FILENO); _ = Darwin.close(STDOUT_FILENO)
            // Deliberately ignore parent EOF after successful bind. A separate
            // authenticated read-only endpoint observes this same owner; the
            // bootstrap channel and credentials are never reopened.
            while admitted.browserIsAlive() { try await Task.sleep(for: .milliseconds(250)) }
            observationActivation.set(false); observation?.cancel()
            admitted.revoke(); await gate.close(); await relay.stop()
            await observation?.stop()
        } catch {
            observationActivation.set(false); observation?.cancel()
            authority?.revoke(); await gate.close(); await relay.stop()
            await observation?.stop(); throw error
        }
    }
}
