import Foundation

/// Small, versioned control protocol for the future isolated WebKit child.
/// Frames contain session metadata, lifecycle acknowledgements and a
/// session-scoped NetworkProcess locator. One
/// dedicated frame may carry a session-scoped local broker capability after live
/// parent/child code checks; upstream proxy credentials and page/profile data
/// never cross this API. A valid frame is not peer authentication: callers
/// must validate the live process code identity before trusting its contents.
enum WebKitHostIPC {
    static let maximumFrameBytes = 4 * 1_024

    struct Session: Equatable, Sendable {
        let profileID: UUID
        let revision: UInt64
        let generation: UUID
        let dataRoot: String
        let runtimeSHA256: String

        func isValid() -> Bool {
            let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            return profileID != zero && generation != zero && revision > 0 &&
                Self.isCanonicalDataRoot(dataRoot) &&
                runtimeSHA256.utf8.count == 64 &&
                runtimeSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }

        private static func isCanonicalDataRoot(_ path: String) -> Bool {
            guard path.utf8.count <= 1_024, path.hasPrefix("/"),
                  !path.utf8.contains(0),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            else { return false }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path
        }
    }

    /// Kernel locator reported by the host for its current WebKit store.
    /// PPID is diagnostic only because NetworkProcess is an XPC service and
    /// may be launched by launchd. This value alone grants no broker authority.
    struct NetworkProcessOwner: Equatable, Sendable {
        let pid: Int32
        let startedAtSeconds: Int64
        let startedAtMicroseconds: Int32
        let userID: UInt32
        let parentPID: Int32

        init(pid: Int32, startedAtSeconds: Int64,
             startedAtMicroseconds: Int32, userID: UInt32, parentPID: Int32) {
            self.pid = pid
            self.startedAtSeconds = startedAtSeconds
            self.startedAtMicroseconds = startedAtMicroseconds
            self.userID = userID
            self.parentPID = parentPID
        }

        init(_ owner: WebKitOwnedNetworkProcessPID.Owner) {
            pid = owner.pid
            startedAtSeconds = owner.startedAtSeconds
            startedAtMicroseconds = owner.startedAtMicroseconds
            userID = UInt32(owner.userID)
            parentPID = owner.parentPID
        }

        var isValid: Bool {
            pid > 1 && startedAtSeconds > 0 &&
                (0..<1_000_000).contains(startedAtMicroseconds) && parentPID > 0
        }
    }

    /// One-use broker authority for a child that has already passed the live
    /// parent/child code checks. It deliberately exposes credentials only to
    /// a closure and redacts normal debug/reflection output.
    struct RelayCredential: Equatable, Sendable, CustomStringConvertible,
                            CustomDebugStringConvertible, CustomReflectable {
        private let session: Session
        private let username: String
        private let password: String

        var description: String { "WebKitHostRelayCredential(<redacted>)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }

        init(session: Session, capability: WebKitRelayAuthority.Capability) throws {
            let scope = capability.scope
            let credentials = capability.withCredentials { ($0, $1) }
            try self.init(session: session, scope: scope,
                          username: credentials.0, password: credentials.1)
        }

        fileprivate init(session: Session, username: String, password: String) throws {
            try self.init(session: session, scope: nil, username: username,
                          password: password)
        }

        private init(session: Session, scope: WebKitRelayAuthority.Scope?,
                     username: String, password: String) throws {
            let canonicalUsername = username.hasPrefix("wk-") &&
                UUID(uuidString: String(username.dropFirst(3)))?.uuidString.lowercased() ==
                    String(username.dropFirst(3))
            let decodedPassword = Data(base64Encoded: password)
            guard session.isValid(), canonicalUsername,
                  decodedPassword?.count == 32,
                  decodedPassword?.base64EncodedString() == password else {
                throw ProtocolError.invalidCapability
            }
            if let scope {
                guard scope.profileID == session.profileID,
                      scope.storeID == session.profileID,
                      scope.sessionID == session.generation,
                      scope.revision == session.revision else {
                    throw ProtocolError.invalidCapability
                }
            }
            self.session = session
            self.username = username
            self.password = password
        }

        func belongs(to session: Session) -> Bool { self.session == session }

        func withCredentials<T>(_ body: (String, String) throws -> T) rethrows -> T {
            try body(username, password)
        }
    }

    enum Frame: Equatable, Sendable {
        case bootstrap(Session)
        /// Child has authenticated the parent, acquired profile/metadata locks,
        /// and verified the exact profile revision before receiving secrets.
        case bootstrapAccepted(Session)
        case relayCapability(Session, RelayCredential)
        /// Parent-to-child acknowledgement that broker activation succeeded.
        /// The child may navigate only after receiving this exact session.
        case routeActive(Session)
        case ready(Session)
        case networkProcessOwner(Session, NetworkProcessOwner)
        case close(Session)
        case saved(Session)
        case saveFailed(Session, reason: SaveFailure)
        case closed(Session)
    }

    enum SaveFailure: String, Equatable, Sendable {
        case storageUnavailable
        case writeFailed
        case timeout
    }

    enum ProtocolError: Error, Equatable {
        case malformedFrame
        case oversizedFrame
        case invalidSession
        case invalidCapability
        case invalidProcessOwner
        case invalidTransition
        case prematureEOF
    }

    /// Encode exactly one newline-delimited frame for a private pipe.
    static func encode(_ frame: Frame) throws -> Data {
        var object: [String: String] = ["v": "1"]
        switch frame {
        case .bootstrap(let session): object["type"] = "bootstrap"; add(session, to: &object)
        case .bootstrapAccepted(let session): object["type"] = "bootstrapAccepted"; add(session, to: &object)
        case .relayCapability(let session, let credential):
            guard credential.belongs(to: session) else { throw ProtocolError.invalidCapability }
            object["type"] = "relayCapability"; add(session, to: &object)
            credential.withCredentials { object["username"] = $0; object["password"] = $1 }
        case .routeActive(let session): object["type"] = "routeActive"; add(session, to: &object)
        case .ready(let session): object["type"] = "ready"; add(session, to: &object)
        case .networkProcessOwner(let session, let owner):
            guard owner.isValid else { throw ProtocolError.invalidProcessOwner }
            object["type"] = "networkProcessOwner"; add(session, to: &object)
            object["networkProcessPID"] = String(owner.pid)
            object["networkProcessStartedAtSeconds"] = String(owner.startedAtSeconds)
            object["networkProcessStartedAtMicroseconds"] = String(owner.startedAtMicroseconds)
            object["networkProcessUID"] = String(owner.userID)
            object["networkProcessObservedPPID"] = String(owner.parentPID)
        case .close(let session): object["type"] = "close"; add(session, to: &object)
        case .saved(let session): object["type"] = "saved"; add(session, to: &object)
        case .saveFailed(let session, let reason):
            object["type"] = "saveFailed"; object["reason"] = reason.rawValue
            add(session, to: &object)
        case .closed(let session): object["type"] = "closed"; add(session, to: &object)
        }
        guard let type = object["type"], let session = session(from: object), session.isValid(),
              keys(for: type) == Set(object.keys) else { throw ProtocolError.invalidSession }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        guard data.count <= maximumFrameBytes else { throw ProtocolError.oversizedFrame }
        return data
    }

    /// Decode one complete frame. Partial, concatenated, unknown-version, and
    /// extension-key frames fail closed instead of being silently ignored.
    static func decode(_ data: Data) throws -> Frame {
        guard data.count <= maximumFrameBytes else { throw ProtocolError.oversizedFrame }
        guard data.last == 0x0A, data.dropLast().allSatisfy({ $0 != 0x0A && $0 != 0x0D }),
              let raw = try? JSONSerialization.jsonObject(with: Data(data.dropLast())),
              let object = raw as? [String: String], object["v"] == "1",
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              Data(canonical + Data([0x0A])) == data,
              let type = object["type"], keys(for: type) == Set(object.keys),
              let session = session(from: object), session.isValid() else {
            throw ProtocolError.malformedFrame
        }
        switch type {
        case "bootstrap": return .bootstrap(session)
        case "bootstrapAccepted": return .bootstrapAccepted(session)
        case "routeActive": return .routeActive(session)
        case "relayCapability":
            guard let username = object["username"], let password = object["password"] else {
                throw ProtocolError.invalidCapability
            }
            return .relayCapability(session, try RelayCredential(
                session: session, username: username, password: password))
        case "ready": return .ready(session)
        case "networkProcessOwner":
            guard let pidString = object["networkProcessPID"], let pid = Int32(pidString),
                  let secondsString = object["networkProcessStartedAtSeconds"], let seconds = Int64(secondsString),
                  let microsString = object["networkProcessStartedAtMicroseconds"], let micros = Int32(microsString),
                  let uidString = object["networkProcessUID"], let uid = UInt32(uidString),
                  let ppidString = object["networkProcessObservedPPID"], let ppid = Int32(ppidString),
                  String(pid) == pidString, String(seconds) == secondsString,
                  String(micros) == microsString, String(uid) == uidString,
                  String(ppid) == ppidString else {
                throw ProtocolError.invalidProcessOwner
            }
            let owner = NetworkProcessOwner(pid: pid, startedAtSeconds: seconds,
                                            startedAtMicroseconds: micros,
                                            userID: uid, parentPID: ppid)
            guard owner.isValid else { throw ProtocolError.invalidProcessOwner }
            return .networkProcessOwner(session, owner)
        case "close": return .close(session)
        case "saved": return .saved(session)
        case "closed": return .closed(session)
        case "saveFailed":
            guard let reason = object["reason"].flatMap(SaveFailure.init(rawValue:)) else {
                throw ProtocolError.malformedFrame
            }
            return .saveFailed(session, reason: reason)
        default: throw ProtocolError.malformedFrame
        }
    }

    /// Send one control record over an already-private inherited pipe. The
    /// outer length prefix prevents a partial JSON write from being mistaken
    /// for a complete command; the inner newline/canonical JSON rules remain
    /// useful for auditing captured protocol records.
    static func write(_ frame: Frame, to descriptor: Int32, timeout: TimeInterval = 2) throws {
        try ProxyRelayPrivatePipe.writeFrame(descriptor, data: encode(frame), timeout: timeout)
    }

    /// Read and validate exactly one bounded record. EOF, timeout, malformed
    /// framing, and unknown protocol fields are errors and must fail closed.
    static func read(from descriptor: Int32, timeout: TimeInterval = 2) throws -> Frame {
        try decode(ProxyRelayPrivatePipe.readFrame(descriptor, timeout: timeout))
    }

    private static func add(_ session: Session, to object: inout [String: String]) {
        object["profile"] = session.profileID.uuidString.lowercased()
        object["revision"] = String(session.revision)
        object["generation"] = session.generation.uuidString.lowercased()
        object["dataRoot"] = session.dataRoot
        object["runtimeSHA256"] = session.runtimeSHA256
    }

    private static func session(from object: [String: String]) -> Session? {
        guard let profile = object["profile"], let profileID = UUID(uuidString: profile),
              profile == profileID.uuidString.lowercased(),
              let generation = object["generation"], let generationID = UUID(uuidString: generation),
              generation == generationID.uuidString.lowercased(),
              let revisionString = object["revision"],
              let revision = UInt64(revisionString), String(revision) == revisionString,
              let dataRoot = object["dataRoot"],
              let runtimeSHA256 = object["runtimeSHA256"] else { return nil }
        return Session(profileID: profileID, revision: revision, generation: generationID,
                       dataRoot: dataRoot, runtimeSHA256: runtimeSHA256)
    }

    private static func keys(for type: String) -> Set<String> {
        let base: Set<String> = ["v", "type", "profile", "revision", "generation", "dataRoot", "runtimeSHA256"]
        switch type {
        case "saveFailed": return base.union(["reason"])
        case "relayCapability": return base.union(["username", "password"])
        case "networkProcessOwner":
            return base.union(["networkProcessPID", "networkProcessStartedAtSeconds",
                               "networkProcessStartedAtMicroseconds", "networkProcessUID",
                               "networkProcessObservedPPID"])
        default: return base
        }
    }
}

/// Parent-side close gate. A child is not considered stopped until it has
/// acknowledged the exact profile revision's save and then exited normally.
struct WebKitHostCloseGate: Sendable {
    enum State: Equatable, Sendable {
        case awaitingBootstrapAcceptance, awaitingRelayCapability, awaitingNetworkProcessOwner
        case awaitingRouteActivation, awaitingReady
        case running, closing, saved, closed, failed
    }
    private(set) var state: State = .awaitingBootstrapAcceptance
    let expected: WebKitHostIPC.Session

    mutating func accept(_ frame: WebKitHostIPC.Frame) throws {
        switch (state, frame) {
        case (.awaitingBootstrapAcceptance, .bootstrapAccepted(let value)) where value == expected:
            state = .awaitingRelayCapability
        case (.awaitingReady, .ready(let value)) where value == expected:
            state = .running
        case (.closing, .saved(let value)) where value == expected:
            state = .saved
        case (.closing, .saveFailed(let value, _)) where value == expected:
            state = .failed
        case (.saved, .closed(let value)) where value == expected:
            state = .closed
        default:
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
    }

    /// The authenticated child needs this one-use credential to configure its
    /// broker-only store before WebKit starts the NetworkProcess. The broker
    /// still refuses CONNECT until that exact NetworkProcess is attested.
    /// Callers must authenticate the child and verify its live code first.
    mutating func issueRelayCapability(_ capability: WebKitRelayAuthority.Capability)
        throws -> WebKitHostIPC.Frame {
        guard state == .awaitingRelayCapability,
              capability.scope.profileID == expected.profileID,
              capability.scope.storeID == expected.profileID,
              capability.scope.sessionID == expected.generation,
              capability.scope.revision == expected.revision else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        let credential = try WebKitHostIPC.RelayCredential(
            session: expected, capability: capability)
        state = .awaitingNetworkProcessOwner
        return .relayCapability(expected, credential)
    }

    /// Receive the locator after the child has configured the broker-only
    /// store and started its NetworkProcess, but before it navigates to a page.
    mutating func acceptNetworkProcessOwner(_ frame: WebKitHostIPC.Frame) throws
        -> WebKitHostIPC.NetworkProcessOwner {
        guard state == .awaitingNetworkProcessOwner,
              case .networkProcessOwner(let session, let owner) = frame,
              session == expected, owner.isValid else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        state = .awaitingRouteActivation
        return owner
    }

    /// Activate the exact staged broker route before authorizing the child to
    /// navigate. A failed lease check or broker activation leaves the gate in
    /// `.awaitingRouteActivation`, so the caller cannot emit `ready`.
    mutating func activateRoute(scope: WebKitRelayAuthority.Scope,
                                activatingBrokerRoute: (WebKitRelayAuthority.Scope) throws -> Void) throws
        -> WebKitHostIPC.Frame {
        guard state == .awaitingRouteActivation,
              scope.profileID == expected.profileID,
              scope.storeID == expected.profileID,
              scope.sessionID == expected.generation,
              scope.revision == expected.revision else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        // Production callers must pass `broker.activate(scope:lease:)` here.
        // If lease validation or broker registration fails, the gate remains
        // fenced and no routeActive frame can be sent to the child.
        try activatingBrokerRoute(scope)
        state = .awaitingReady
        return .routeActive(expected)
    }

    /// Convert the exact running-session report into a live-code-checked lease.
    /// The IPC transport peer must be authenticated by the caller separately;
    /// this method authenticates the reported NetworkProcess executable.
    mutating func attestNetworkProcessOwner(_ frame: WebKitHostIPC.Frame,
                                            managerBundle: URL = Bundle.main.bundleURL)
        throws -> WebKitNetworkProcessCodeIdentity.Lease {
        let report = try acceptNetworkProcessOwner(frame)
        let owner = WebKitOwnedNetworkProcessPID.Owner(
            pid: report.pid, startedAtSeconds: report.startedAtSeconds,
            startedAtMicroseconds: report.startedAtMicroseconds,
            userID: report.userID, parentPID: report.parentPID)
        return try WebKitNetworkProcessCodeIdentity.lease(
            session: expected, owner: owner, managerBundle: managerBundle)
    }

    mutating func requestClose() throws {
        guard state == .running || state == .failed else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        state = .closing
    }

    func acceptEOF() throws {
        guard state == .closed else { throw WebKitHostIPC.ProtocolError.prematureEOF }
    }
}

/// Child-side navigation fence. The host reports its NetworkProcess only
/// after configuring the broker-only store and starting that process. This
/// gate permits page/session navigation and `ready` only after the parent has
/// authenticated the owner, activated its matching broker lease, and sent the
/// exact `routeActive` session frame.
struct WebKitHostChildRouteGate: Sendable {
    enum State: Equatable, Sendable {
        case awaitingNetworkProcess, awaitingRouteActivation, active
    }
    private(set) var state: State = .awaitingNetworkProcess
    let expected: WebKitHostIPC.Session

    mutating func reportNetworkProcess(_ owner: WebKitHostIPC.NetworkProcessOwner)
        throws -> WebKitHostIPC.Frame {
        guard state == .awaitingNetworkProcess, owner.isValid else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        state = .awaitingRouteActivation
        return .networkProcessOwner(expected, owner)
    }

    mutating func acceptRouteActivation(_ frame: WebKitHostIPC.Frame) throws
        -> WebKitOwnedNavigationPermit {
        guard state == .awaitingRouteActivation,
              case .routeActive(let session) = frame,
              session == expected else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        state = .active
        return WebKitOwnedNavigationPermit(session: expected)
    }

    func readyFrame() throws -> WebKitHostIPC.Frame {
        guard state == .active else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        return .ready(expected)
    }
}

/// In-process proof that the authenticated child route gate accepted this
/// exact session. Its initializer is file-private; browser code cannot mint a
/// navigation permit directly from an arbitrary IPC frame.
struct WebKitOwnedNavigationPermit: Sendable {
    fileprivate let session: WebKitHostIPC.Session
    fileprivate init(session: WebKitHostIPC.Session) { self.session = session }
    func authorizes(_ expected: WebKitHostIPC.Session) -> Bool { session == expected }
}
