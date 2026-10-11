#if DEBUG
import AppKit
import Darwin
import Foundation

/// Isolated signed-parent qualification. Absent from release builds. It runs
/// before stores/Keychain initialization and accepts only fresh owned tmp roots
/// and loopback fixtures with fixed synthetic credentials.
enum ProxyRelayOwnerQualification {
    enum Failure: Error { case noncanonicalRoot, invalidRootParent, invalidRootName, invalidFixtureProtocol, unsafeRoot, nonemptyRoot, missingBundle, invalidRuntimeSignature, missingRuntimeVersion, missingRuntimeHash, quitTimeout, changedQuitLease, changedQuitExecutable, changedQuitDataPath, changedQuitConfiguration }
    static let argument = "--neantik-qualify-relay-owner"
    struct Request: Codable { let root: String; let upstreamPort: UInt16; let kind: ProxyKind; var managerIntegration: Bool? = nil; var mutateBeforeActivation: Bool? = nil; var observeRestart: Bool? = nil; var terminateAfterActivation: Bool? = nil; var cancelBeforeActivation: Bool? = nil; var fixtureSlot: UInt8? = nil; var holdManagerUntilRelease: Bool? = nil; var qualificationAnchorDER: Data? = nil
        var closeAfterRestart: Bool? = nil
        var expectedQuitSnapshot: ProxyRelayQualificationQuit.Snapshot? = nil
        var observeTransport: Bool? = nil
        var expectedLaunchRevision: UInt64? = nil
        var fixtureHost: String { kind == .https ? "localhost" : "127.0.0.1" }
    }
    struct Result: Codable {
        let schemaVersion: Int; let browserPID: pid_t; let ownerPID: pid_t; let relayPort: UInt16
        let runtimeVersion: String; let runtimeExecutableSHA256: String; let runtimeFrameworkSHA256: String
        var restartAdoptedAndDuplicateRefused: Bool? = nil
        var cancelledBeforeActivation: Bool? = nil
        var quitSnapshot: ProxyRelayQualificationQuit.Snapshot? = nil
        var nativeQuitAccepted: Bool? = nil
        var processesDrained: Bool? = nil
        var transportObservation: BrowserRelayActivity.Snapshot? = nil
        var staleRevisionObservationRefused: Bool? = nil
        var launchMetadataObservationVerified: Bool? = nil
        var abandonedObservationDidNotStopSession: Bool? = nil
        var launchRevision: UInt64? = nil
    }
    static func runAndExit() -> Never {
        Task.detached {
            do { try await run(); Darwin.exit(EX_OK) }
            catch {
                // Only the error's static type: never associated native text,
                // paths, endpoints, credentials or fingerprint values.
                let type: String
                if let error = error as? Failure { type = "Qualification." + String(describing: error) }
                else if let error = error as? ProxyRelayObservationProtocol.Failure { type = "Observation." + String(describing: error) }
                else if let error = error as? ProxyRelayQualificationQuit.Failure { type = "QualificationQuit." + String(describing: error) }
                else { type = String(reflecting: Swift.type(of: error)) }
                FileHandle.standardError.write(Data(("relay_qualification_failed type=" + type + "\n").utf8))
                Darwin.exit(EX_NOPERM)
            }
        }
        dispatchMain()
    }
    private static func run() async throws {
        try ProxyRelayPrivatePipe.prepare(STDIN_FILENO, writable: false)
        try ProxyRelayPrivatePipe.prepare(STDOUT_FILENO, writable: true)
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.relay-qualification",
              CommandLine.arguments.count == 2, CommandLine.arguments[1] == argument
        else { throw Failure.missingBundle }
        let request = try JSONDecoder().decode(Request.self, from: ProxyRelayPrivatePipe.readFrame(STDIN_FILENO, timeout: 5))
        let root = try validatedRoot(request)
        guard let resources = Bundle.main.resourceURL, let manager = Bundle.main.executableURL,
              let browser = Bundle(url: resources.appendingPathComponent("NeAntik Browser.app"))?.executableURL
        else { throw Failure.missingBundle }
        let inspection = BrowserRuntimeInspector.inspect(executableURL: browser)
        guard inspection.codeSignatureValid == true else { throw Failure.invalidRuntimeSignature }
        guard let version = inspection.version else { throw Failure.missingRuntimeVersion }
        guard let executableHash = inspection.executableSHA256, let frameworkHash = inspection.frameworkSHA256
        else { throw Failure.missingRuntimeHash }
        if request.observeRestart == true {
            let result = try await observeRestart(request: request, root: root, browser: browser, inspection: inspection)
            try ProxyRelayPrivatePipe.writeFrame(STDOUT_FILENO, data: JSONEncoder().encode(result), timeout: 2)
            return
        }
        if request.managerIntegration == true {
            let result = try await launchThroughManager(request: request, root: root, browser: browser, inspection: inspection)
            try ProxyRelayPrivatePipe.writeFrame(STDOUT_FILENO, data: JSONEncoder().encode(result), timeout: 2)
            if request.holdManagerUntilRelease == true {
                let release = root.appendingPathComponent("qa-release-manager")
                let deadline = ContinuousClock.now + .seconds(35)
                while (try? AppPaths(rootDirectory: root).privateFileEntryKind(release)) != .regular && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard (try? AppPaths(rootDirectory: root).privateFileEntryKind(release)) == .regular else { throw Failure.unsafeRoot }
                let finish = try ProxyRelayPrivatePipe.readFrame(STDIN_FILENO, timeout: 2)
                guard finish == Data("owned-release-manager".utf8) else { throw Failure.unsafeRoot }
            }
            return
        }
        try await launch(request: request, root: root, manager: manager, browser: browser, version: version,
                         executableHash: executableHash, frameworkHash: frameworkHash)
    }
    /// Never available in release and never keyed by a public endpoint/domain.
    /// These arguments exist only for this explicitly invoked signed QA mode.
    static func browserArguments(paths: AppPaths) -> [String] {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.relay-qualification",
              paths.rootDirectory.lastPathComponent.hasPrefix("neantik-relay-owner-qualification-")
        else { return [] }
        return ["--use-mock-keychain", "--disable-background-networking", "--disable-component-update",
                "--disable-sync", "--disable-extensions", "--log-net-log=" + paths.rootDirectory.appendingPathComponent("owned-session-netlog.json").path,
                "--net-log-capture-mode=Default"]
    }
    @MainActor private static func launchThroughManager(request: Request, root: URL, browser: URL,
                                                       inspection: BrowserRuntimeInspection) async throws -> Result {
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: AppPaths(rootDirectory: root))
        // Private synthetic NetLog only. Never enabled by the interactive app.
        let log = paths.rootDirectory.appendingPathComponent("owned-session-netlog.json")
        guard FileManager.default.createFile(atPath: log.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        else { throw Failure.unsafeRoot }
        if request.terminateAfterActivation == true {
            try paths.writePrivateFile(Data("owned-negative-control".utf8), to: root.appendingPathComponent("qa-terminate-after-activation"))
        }
        if request.mutateBeforeActivation == true {
            try paths.writePrivateFile(Data("owned-negative-control".utf8), to: root.appendingPathComponent("qa-mutate-before-activation"))
        }
        if request.cancelBeforeActivation == true {
            try paths.writePrivateFile(Data("owned-negative-control".utf8), to: root.appendingPathComponent("qa-cancel-before-activation"))
        }
        try paths.writePrivateFile(Data("owned-qualification-root-v1".utf8), to: root.appendingPathComponent("qa-owned-root"))
        let username = request.fixtureSlot == 2 ? "qualification-user-2" : "qualification-user"
        let password = request.fixtureSlot == 2 ? "qualification-password-2" : "qualification-password"
        let stamp = Date()
        let profile = try store.upsert(BrowserProfile(name: "Owned relay qualification", startURL: "http://relay-qualification.test/owned",
            proxy: .init(kind: request.kind, host: request.fixtureHost, port: Int(request.upstreamPort), username: username),
            identity: .init(seed: 123, timezoneIdentifier: "Europe/Berlin", localeIdentifier: "de-DE", proxyContextEvidence: .ipAPI(observedAt: stamp))))
        // Synthetic preflight only. Actual HTTP route is independently observed
        // by the fixture, never inferred from this prepared launch capability.
        let health = ProxyHealthUpdatePolicy.success(ProxyTestObservation(observedAt: stamp, responseTimeMilliseconds: 1,
            result: .init(ipAddress: "203.0.113.7", city: "Berlin", countryName: "Germany", countryCode: "DE",
                          timezoneIdentifier: "Europe/Berlin", localeIdentifier: "de-DE"), source: .ipAPI))
        guard let receipt = BrowserLaunchPreparationPolicy.receipt(profile: profile, proxyHealth: health)
        else { throw ProxyRelayOwnerProtocol.Failure.invalidBootstrap }
        let keychain = KeychainStore(backend: DevelopmentFixtureKeychain(), service: "owned-relay-fixture", legacyService: nil)
        try keychain.saveProxyPassword(password, profileID: profile.id)
        let runtime = BrowserRuntime(name: "Qualified public runtime", executableURL: browser, source: "Signed QA bundled", inspection: inspection)
        let processes = BrowserProcessManager(paths: paths)
        if let anchor = request.qualificationAnchorDER { try processes.relayQualificationSetTLS(anchorDER: anchor) }
        @MainActor func launchFixture() async throws {
            // Qualify the same selector as UI/MCP, including HTTPS. The only
            // fixture difference is the DEBUG localhost trust configuration.
            try await processes.launchUserProfile(profile: profile, runtime: runtime, preparationReceipt: receipt, keychain: keychain)
        }
        if request.cancelBeforeActivation == true {
            let task = Task { @MainActor in
                try await launchFixture()
            }
            let marker = root.appendingPathComponent("qa-bound-session")
            let deadline = ContinuousClock.now + .seconds(15)
            while (try? paths.privateFileEntryKind(marker)) != .regular && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard (try? paths.privateFileEntryKind(marker)) == .regular else {
                task.cancel(); _ = try? await task.value; throw Failure.unsafeRoot
            }
            let bound = try JSONDecoder().decode(Result.self, from: Data(contentsOf: marker))
            task.cancel()
            do { try await task.value; throw Failure.unsafeRoot }
            catch is CancellationError { }
            guard processes.relayQualificationReceipt(profileID: profile.id) == nil else { throw Failure.unsafeRoot }
            var result = bound; result.cancelledBeforeActivation = true
            return result
        }
        try await launchFixture()
        guard let session = processes.relayQualificationReceipt(profileID: profile.id),
              let version = inspection.version, let executableHash = inspection.executableSHA256, let frameworkHash = inspection.frameworkSHA256
        else { throw ProxyRelayOwnerProtocol.Failure.invalidBinding }
        let lease = try ManagedSessionLeaseReader.read(paths: paths, profileID: profile.id)
        guard let browserIdentity = ProxyRelaySocketOwnerInspector.processIdentity(session.browserPID),
              let ownerIdentity = ProxyRelaySocketOwnerInspector.processIdentity(session.ownerPID),
              browserIdentity.userID == geteuid(), ownerIdentity.userID == geteuid(),
              lease.pid == session.browserPID, lease.relay?.ownerPID == session.ownerPID
        else { throw Failure.unsafeRoot }
        var result = Result(schemaVersion: 1, browserPID: session.browserPID, ownerPID: session.ownerPID, relayPort: session.port,
            runtimeVersion: version, runtimeExecutableSHA256: executableHash, runtimeFrameworkSHA256: frameworkHash,
            quitSnapshot: .init(lease: lease, browser: .init(browserIdentity), owner: .init(ownerIdentity)))
        if request.observeTransport == true {
            guard let manager = Bundle.main.executableURL, let identifier = Bundle.main.bundleIdentifier,
                  let generation = lease.ownerToken else { throw Failure.unsafeRoot }
            let diagnosticReceipt = ManagedBrowserSessionReceipt(generation: generation, lock: lease,
                runtimeVersion: version, configuredRoute: .httpProxy, profileRevision: profile.revision, browserIdentity: browserIdentity)
            guard let diagnosticBinding = try diagnosticReceipt.relayBinding(profileID: profile.id, expectedRevision: profile.revision) else { throw Failure.unsafeRoot }
            let code = try ProxyRelayExpectedCode.qualifiedPin(at: manager, expectedIdentifier: identifier, expectedTeamIdentifier: "H6VGU2M6JD")
            _ = try await Task.detached {
                try ProxyRelayObservationSocket.abandonReplyForQualification(binding: diagnosticBinding, expectedOwnerCode: code)
            }.value
            _ = try await Task.detached {
                try ProxyRelayObservationSocket.query(binding: diagnosticBinding, expectedOwnerCode: code)
            }.value
            result.abandonedObservationDidNotStopSession = diagnosticBinding.processesAreCurrent
            guard store.markLaunched(profile.id), let recorded = store.profiles.first(where: { $0.id == profile.id }),
                  recorded.revision == profile.revision + 1 else { throw Failure.unsafeRoot }
            processes.recordManagedLaunchMetadata(from: profile, to: recorded)
            let deadline = ContinuousClock.now + .seconds(12)
            repeat {
                let observed = try await processes.observeManagedBrowserSession(profileID: profile.id, expectedRevision: recorded.revision)
                if let transport = observed.relayTransport, transport.admittedConnections > 0,
                   try await processes.revalidateManagedBrowserObservation(observed, profileID: profile.id, expectedProfile: recorded) {
                    result.transportObservation = transport; break
                }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            let stale = try await processes.observeManagedBrowserSession(profileID: profile.id, expectedRevision: profile.revision)
            guard result.transportObservation != nil, stale.relayTransport == nil else { throw Failure.unsafeRoot }
            result.staleRevisionObservationRefused = true
            result.launchMetadataObservationVerified = true
            result.launchRevision = profile.revision
        }
        return result
    }
    @MainActor private static func observeRestart(request: Request, root: URL, browser: URL,
                                                  inspection: BrowserRuntimeInspection) async throws -> Result {
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: AppPaths(rootDirectory: root))
        guard store.hasTrustedMetadata, store.profiles.count == 1, let profile = store.profiles.first,
              profile.name == "Owned relay qualification", profile.proxy?.host == request.fixtureHost, profile.proxy?.port == Int(request.upstreamPort),
              let version = inspection.version, let executableHash = inspection.executableSHA256, let frameworkHash = inspection.frameworkSHA256
        else { throw Failure.unsafeRoot }
        let lease = try ManagedSessionLeaseReader.read(paths: paths, profileID: profile.id)
        let launchRevision = request.expectedLaunchRevision ?? profile.revision
        guard lease.phase == .running, let relay = lease.relay,
              relay.profileID == profile.id, relay.runtimeExecutableSHA256 == executableHash,
              relay.runtimeFrameworkSHA256 == frameworkHash,
              !relay.ownerIsAbsent(inspect: ProxyRelaySocketOwnerInspector.processIdentity, isAlive: DarwinBrowserProcessInventoryProvider.isProcessAlive)
        else { throw Failure.unsafeRoot }
        let processes = BrowserProcessManager(paths: paths)
        processes.reconcile(profiles: store.profiles)
        for _ in 0..<100 {
            if processes.relayQualificationHasAdopted(profileID: profile.id) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard processes.relayQualificationHasAdopted(profileID: profile.id) else { throw Failure.unsafeRoot }
        var duplicateRefused = false
        do { try processes.launch(profile: profile, runtime: .init(name: "Qualified runtime", executableURL: browser, source: "Owned restart", inspection: inspection)) }
        catch NeAntikError.profileAlreadyRunning { duplicateRefused = true }
        guard duplicateRefused, try ManagedSessionLeaseReader.read(paths: paths, profileID: profile.id) == lease else { throw Failure.unsafeRoot }
        var result = Result(schemaVersion: 1, browserPID: lease.pid, ownerPID: relay.ownerPID, relayPort: relay.loopbackPort,
                      runtimeVersion: version, runtimeExecutableSHA256: executableHash, runtimeFrameworkSHA256: frameworkHash,
                      restartAdoptedAndDuplicateRefused: true)
        guard let observedBrowser = ProxyRelaySocketOwnerInspector.processIdentity(lease.pid),
              let observedOwner = ProxyRelaySocketOwnerInspector.processIdentity(relay.ownerPID) else { throw Failure.unsafeRoot }
        result.quitSnapshot = .init(lease: lease, browser: .init(observedBrowser), owner: .init(observedOwner))
        if request.observeTransport == true {
            guard let browserIdentity = ProxyRelaySocketOwnerInspector.processIdentity(lease.pid),
                  let manager = Bundle.main.executableURL, let identifier = Bundle.main.bundleIdentifier else { throw Failure.unsafeRoot }
            let receipt = ManagedBrowserSessionReceipt(generation: relay.sessionGeneration, lock: lease,
                runtimeVersion: version, configuredRoute: .httpProxy, profileRevision: launchRevision, browserIdentity: browserIdentity)
            guard let context = try receipt.relayBinding(profileID: profile.id, expectedRevision: launchRevision) else { throw Failure.unsafeRoot }
            let code = try ProxyRelayExpectedCode.qualifiedPin(at: manager, expectedIdentifier: identifier, expectedTeamIdentifier: "H6VGU2M6JD")
            result.transportObservation = try await Task.detached {
                try ProxyRelayObservationSocket.query(binding: context, expectedOwnerCode: code)
            }.value
            // Core reconnect qualification does not grant the restarted MCP
            // session ownership of an externally running browser.
        }
        if request.closeAfterRestart == true {
            guard let expected = request.expectedQuitSnapshot, expected.lease == lease else { throw Failure.changedQuitLease }
            guard lease.executablePath == browser.standardizedFileURL.path else { throw Failure.changedQuitExecutable }
            guard ProxyRelayQualificationQuit.matchesDataPath(lease, expected: paths.browserDataDirectory(for: profile.id))
            else { throw Failure.changedQuitDataPath }
            guard let proxy = profile.proxy,
                  relay.configurationSHA256 == ProxyRelayOwnerProtocol.Bootstrap.configurationDigest(
                    profileID: profile.id, revision: launchRevision, kind: proxy.kind,
                    host: proxy.host, port: proxy.port, username: proxy.username)
            else { throw Failure.changedQuitConfiguration }
            try paths.withProcessLockGuard(for: profile.id) {
                try ProxyRelayQualificationQuit.request(expected: expected, currentUserID: geteuid(),
                    readLease: { try ManagedSessionLeaseReader.read(paths: paths, profileID: profile.id) },
                    inspectBrowser: { ProxyRelaySocketOwnerInspector.processIdentity(lease.pid) },
                    inspectOwner: { ProxyRelaySocketOwnerInspector.processIdentity(relay.ownerPID) },
                    inspectExactProcess: { DarwinBrowserProcessInventoryProvider().capture().inspectExactQualificationProcess(lease) },
                    nativeQuit: {
                        guard let application = NSRunningApplication(processIdentifier: lease.pid),
                              application.isFinishedLaunching,
                              application.executableURL?.standardizedFileURL == browser.standardizedFileURL,
                              expected.browser.matches(ProxyRelaySocketOwnerInspector.processIdentity(lease.pid))
                        else { return false }
                        return application.terminate()
                    })
            }
            result.nativeQuitAccepted = true
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                if !DarwinBrowserProcessInventoryProvider.isProcessAlive(lease.pid),
                   !DarwinBrowserProcessInventoryProvider.isProcessAlive(relay.ownerPID) {
                    let data = paths.browserDataDirectory(for: profile.id)
                    let remaining = await Task.detached { DarwinBrowserProcessInventoryProvider().capture().inspectBrowserDataProcess(data) }.value
                    if remaining == .absent { result.processesDrained = true; break }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard result.processesDrained == true else { throw Failure.quitTimeout }
        }
        return result
    }

    @MainActor static func mutateBeforeActivationIfRequested(profile: BrowserProfile, paths: AppPaths) throws {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.relay-qualification",
              paths.rootDirectory.path.hasPrefix("/private/tmp/neantik-relay-owner-qualification-"),
              (try? paths.privateFileEntryKind(paths.rootDirectory.appendingPathComponent("qa-mutate-before-activation"))) == .regular
        else { return }
        let store = ProfileStore(paths: paths)
        var changed = profile; changed.startURL = "https://example.com/owned-stale-control"
        _ = try store.upsert(changed)
    }

    /// The parent cancels the actual launch Task only after this durable Bound
    /// receipt. The activation gate stays closed; timeout is a failed control.
    @MainActor static func pauseBeforeActivationIfRequested(process: Process, owner: ProxyRelayOwnerClient,
                                                            runtime: BrowserRuntimeInspection, paths: AppPaths) async throws {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.relay-qualification",
              paths.rootDirectory.path.hasPrefix("/private/tmp/neantik-relay-owner-qualification-"),
              (try? paths.privateFileEntryKind(paths.rootDirectory.appendingPathComponent("qa-cancel-before-activation"))) == .regular
        else { return }
        guard let version = runtime.version, let exe = runtime.executableSHA256, let framework = runtime.frameworkSHA256 else { throw Failure.missingRuntimeHash }
        let receipt = Result(schemaVersion: 1, browserPID: process.processIdentifier, ownerPID: owner.processID, relayPort: owner.port,
                             runtimeVersion: version, runtimeExecutableSHA256: exe, runtimeFrameworkSHA256: framework)
        try paths.writePrivateFile(JSONEncoder().encode(receipt), to: paths.rootDirectory.appendingPathComponent("qa-bound-session"))
        try await Task.sleep(for: .seconds(15))
        throw Failure.unsafeRoot
    }

    @MainActor static func terminateAfterActivationIfRequested(process: Process, paths: AppPaths) async throws {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.relay-qualification",
              paths.rootDirectory.path.hasPrefix("/private/tmp/neantik-relay-owner-qualification-"),
              (try? paths.privateFileEntryKind(paths.rootDirectory.appendingPathComponent("qa-terminate-after-activation"))) == .regular
        else { return }
        try paths.writePrivateFile(Data("owned-active-ack-observed".utf8), to: paths.rootDirectory.appendingPathComponent("qa-active-ack-observed"))
        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !process.isRunning else { throw ProxyRelayOwnerClient.Failure.invalidState }
    }

    static func validatedRoot(_ request: Request) throws -> URL {
        let root = URL(fileURLWithPath: request.root, isDirectory: true)
        var info = stat()
        // Foundation standardization can rewrite the system's /private/tmp
        // alias. Validate the literal single-component path instead; lstat
        // below separately rejects links and proves ownership/permissions.
        guard root.path == request.root, !request.root.hasSuffix("/"),
              ![".", "..", ""].contains(root.lastPathComponent) else { throw Failure.noncanonicalRoot }
        guard request.root == "/private/tmp/" + root.lastPathComponent else { throw Failure.invalidRootParent }
        guard root.lastPathComponent.hasPrefix("neantik-relay-owner-qualification-") else { throw Failure.invalidRootName }
        guard request.upstreamPort != 0, request.kind == .http || request.kind == .socks5 || request.kind == .https,
              request.fixtureSlot == nil || request.fixtureSlot == 1 || request.fixtureSlot == 2,
              request.holdManagerUntilRelease != true || request.managerIntegration == true,
              request.closeAfterRestart != true || (request.observeRestart == true && request.expectedQuitSnapshot != nil),
              request.expectedQuitSnapshot == nil || request.closeAfterRestart == true
        else { throw Failure.invalidFixtureProtocol }
        if request.kind == .https {
            guard let anchor = request.qualificationAnchorDER else { throw Failure.invalidFixtureProtocol }
            _ = try ProxyRelayTLSQualification.Configuration(anchorDER: anchor)
        } else {
            guard request.qualificationAnchorDER == nil else { throw Failure.invalidFixtureProtocol }
        }
        guard lstat(root.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.unsafeRoot }
        if request.observeRestart == true {
            let marker = root.appendingPathComponent("qa-owned-root")
            var markerInfo = stat()
            guard lstat(marker.path, &markerInfo) == 0, markerInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  markerInfo.st_uid == geteuid(), markerInfo.st_nlink == 1, markerInfo.st_size == 27,
                  markerInfo.st_mode & 0o777 == 0o600, try Data(contentsOf: marker) == Data("owned-qualification-root-v1".utf8)
            else { throw Failure.unsafeRoot }
        } else {
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw Failure.nonemptyRoot }
        }
        return root
    }
    private static func launch(request: Request, root: URL, manager: URL, browser: URL, version: String,
                               executableHash: String, frameworkHash: String) async throws {
        let profile = UUID(), generation = UUID(), host = request.fixtureHost, username = "qualification-user"
        var bootstrap = ProxyRelayOwnerProtocol.Bootstrap(schemaVersion: 1, nonce: UUID(), profileID: profile,
            sessionGeneration: generation, profileRevision: 1, kind: request.kind, host: host,
            port: Int(request.upstreamPort), username: username, password: "qualification-password",
            runtimeVersion: version, runtimeExecutableSHA256: executableHash, runtimeFrameworkSHA256: frameworkHash,
            configurationSHA256: ProxyRelayOwnerProtocol.Bootstrap.configurationDigest(profileID: profile, revision: 1,
                kind: request.kind, host: host, port: Int(request.upstreamPort), username: username))
        bootstrap.qualificationAnchorDER = request.qualificationAnchorDER
        let owner = try await ProxyRelayOwnerClient.prepare(executable: manager, bootstrap: bootstrap)
        let process = Process()
        let data = root.appendingPathComponent("BrowserData", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        process.executableURL = browser
        process.arguments = ["--user-data-dir=" + data.path, "--use-mock-keychain", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update", "--disable-sync", "--disable-extensions",
            "--proxy-server=socks5://127.0.0.1:" + String(owner.port), "--proxy-bypass-list=<-loopback>",
            "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1", "--disable-quic",
            "--webrtc-ip-handling-policy=disable_non_proxied_udp", "--new-window", "http://relay-qualification.test/owned"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path, "TMPDIR": root.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do {
            try process.run(); try await owner.bind(browserPID: process.processIdentifier)
            try await owner.activate()
            let result = Result(schemaVersion: 1, browserPID: process.processIdentifier, ownerPID: owner.processID,
                relayPort: owner.port, runtimeVersion: version, runtimeExecutableSHA256: executableHash, runtimeFrameworkSHA256: frameworkHash)
            try ProxyRelayPrivatePipe.writeFrame(STDOUT_FILENO, data: JSONEncoder().encode(result), timeout: 2)
            // Exit now: the harness independently proves manager EOF survival
            // and can kill only the reported synthetic browser generation.
        } catch {
            await owner.abandon(); if process.isRunning { process.terminate() }; throw error
        }
    }
}
#endif
