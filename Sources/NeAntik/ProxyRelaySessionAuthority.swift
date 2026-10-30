import Darwin
import Foundation

/// Authorizes a socket from one signed browser profile. This deliberately
/// trusts that profile's signed helpers; it does not assert a NetworkService
/// role. A renderer or extension inside that profile is within this boundary.
/// No process arguments, cookies, destinations or credentials are inspected.
final class ProxyRelaySessionAuthority: @unchecked Sendable {
    struct Binding: Sendable {
        let profileID: UUID
        let sessionGeneration: UUID
        let runtimeExecutableSHA256: String
        let runtimeFrameworkSHA256: String
        let configurationSHA256: String
        let browserPID: pid_t
        let browserIdentity: ProxyRelayOwnerProcessIdentity

        init(profileID: UUID, sessionGeneration: UUID, runtimeExecutableSHA256: String,
             runtimeFrameworkSHA256: String, configurationSHA256: String,
             browserPID: pid_t, browserIdentity: ProxyRelayOwnerProcessIdentity) throws {
            let hashes = [runtimeExecutableSHA256, runtimeFrameworkSHA256, configurationSHA256]
            guard browserPID > 0, browserIdentity.userID == geteuid(),
                  browserIdentity.generation.startSeconds > 0,
                  (0..<1_000_000).contains(browserIdentity.generation.startMicroseconds),
                  hashes.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } })
            else { throw Failure.invalidBinding }
            self.profileID = profileID; self.sessionGeneration = sessionGeneration
            self.runtimeExecutableSHA256 = runtimeExecutableSHA256
            self.runtimeFrameworkSHA256 = runtimeFrameworkSHA256
            self.configurationSHA256 = configurationSHA256
            self.browserPID = browserPID; self.browserIdentity = browserIdentity
        }
    }
    enum Failure: Error { case invalidBinding }

    /// Injection exists for deterministic negative controls. Production uses
    /// kernel observations and fresh dynamic code verification on every admit.
    struct Inspector: Sendable {
        let identity: @Sendable (pid_t) -> ProxyRelayOwnerProcessIdentity?
        let children: @Sendable (pid_t) -> [pid_t]?
        let mainCode: @Sendable (pid_t, ProxyRelayOwnerProcessIdentity) -> Bool
        let helperCode: @Sendable (pid_t, ProxyRelayOwnerProcessIdentity) -> Bool
        let socket: @Sendable (pid_t, ProxyRelayOwnerProcessIdentity, ProxyRelayLoopbackServer.Peer) -> Bool

        static func live(mainCode: ProxyRelayExpectedCode, helperCode: ProxyRelayExpectedCode) -> Self {
            .init(identity: ProxyRelaySocketOwnerInspector.processIdentity,
                  children: ProxyRelaySessionAuthority.children,
                  mainCode: { ProxyRelayLiveCodeVerifier.matches(processID: $0, expectedProcess: $1, expectedCode: mainCode) },
                  helperCode: { ProxyRelayLiveCodeVerifier.matches(processID: $0, expectedProcess: $1, expectedCode: helperCode) },
                  socket: { pid, identity, peer in
                      guard case .matched(let evidence) = ProxyRelaySocketOwnerInspector.inspect(
                        processID: pid, expected: identity, clientPort: peer.clientPort, relayPort: peer.relayPort)
                      else { return false }
                      return ProxyRelaySocketOwnerInspector.revalidate(evidence, expected: identity,
                        clientPort: peer.clientPort, relayPort: peer.relayPort)
                  })
        }
    }

    static let maximumChildren = 512
    private let binding: Binding
    private let inspector: Inspector
    private let lock = NSLock()
    private var revoked = false

    init(binding: Binding, inspector: Inspector) { self.binding = binding; self.inspector = inspector }

    /// Linearizes revocation with admission. The owner must also cancel the
    /// listener and established streams; refusal of new auth alone is not stop.
    func revoke() { lock.lock(); revoked = true; lock.unlock() }

    func browserIsAlive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !revoked && liveMain() != nil
    }

    func admits(_ peer: ProxyRelayLoopbackServer.Peer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !revoked, peer.clientPort > 0, peer.relayPort > 0,
              let main = liveMain(), let candidates = inspector.children(binding.browserPID),
              candidates.count <= Self.maximumChildren,
              Set(candidates).count == candidates.count,
              candidates.allSatisfy({ $0 > 0 && $0 != binding.browserPID })
        else { return false }
        var matched: (pid_t, ProxyRelayOwnerProcessIdentity)?
        for pid in candidates {
            // An unreadable child cannot confer authority. Other roles may
            // legitimately lack sockets; only an exact positive match counts.
            guard let child = inspector.identity(pid), child.userID == main.userID,
                  child.parentProcessID == binding.browserPID,
                  inspector.socket(pid, child, peer), inspector.helperCode(pid, child)
            else { continue }
            guard matched == nil else { return false } // shared/ambiguous ownership
            matched = (pid, child)
        }
        guard let (pid, child) = matched,
              inspector.identity(pid) == child,
              inspector.helperCode(pid, child), inspector.socket(pid, child, peer),
              liveMain() != nil
        else { return false }
        return true
    }

    private func liveMain() -> ProxyRelayOwnerProcessIdentity? {
        guard let current = inspector.identity(binding.browserPID),
              current.generation == binding.browserIdentity.generation,
              current.userID == binding.browserIdentity.userID,
              inspector.mainCode(binding.browserPID, current)
        else { return nil }
        // Parent is intentionally not pinned after bootstrap: macOS reparents
        // a live browser when its manager exits. PID generation/UID/live code
        // remain mandatory, and every helper must still be its direct child.
        return current
    }

    private static func children(_ pid: pid_t) -> [pid_t]? {
        var values = [pid_t](repeating: 0, count: maximumChildren + 1)
        let count = values.withUnsafeMutableBytes {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        // Unlike proc_listpids, Apple's proc_listchildpids wrapper returns a
        // PID count (it already divides the kernel byte count by sizeof(int)).
        return decodedChildren(values, count: count)
    }

    static func decodedChildren(_ buffer: [pid_t], count: Int32) -> [pid_t]? {
        guard count >= 0, count <= maximumChildren, Int(count) < buffer.count else { return nil }
        let values = Array(buffer.prefix(Int(count)))
        guard values.allSatisfy({ $0 > 0 }), Set(values).count == values.count else { return nil }
        return values
    }
}
