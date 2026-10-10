import Darwin
import Foundation

/// One exact connected Unix stream and a kernel peer observation. The PID is
/// the socket's last kernel-observed user, not a client-supplied field. Shared
/// descriptors and later peer activity can change this; it is not a lease.
struct ProxyRelayControlPeerEvidence: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let descriptor: Int32
    fileprivate let socketIdentity: ProxyRelayControlSocketIdentity
    fileprivate let processID: pid_t
    fileprivate let process: ProxyRelayOwnerProcessIdentity
    var description: String { "ProxyRelayControlPeerEvidence(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Unix socket stat size is its current receive queue; permissions can change
/// after a half-close. Neither is an immutable kernel object identifier.
fileprivate struct ProxyRelayControlSocketIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let uid: uid_t
    let type: mode_t
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; uid = value.st_uid
        type = value.st_mode & mode_t(S_IFMT)
    }
}

enum ProxyRelayControlPeerResult {
    case matched(ProxyRelayControlPeerEvidence), unrelated, unavailable
}

/// Foundation for the closed session-owner IPC, not a public control server.
/// No payloads, credentials, argv, paths or unrelated processes are read. A
/// caller must separately bind the control request to profile/generation and
/// current session authority; an owner token is correlation, not permission.
enum ProxyRelayControlPeerInspector {
    static func inspect(descriptor: Int32, expectedProcessID: pid_t,
                        expectedProcess: ProxyRelayOwnerProcessIdentity) -> ProxyRelayControlPeerResult {
        guard descriptor >= 0, expectedProcessID > 0, expectedProcess.userID == geteuid() else { return .unrelated }
        guard let first = snapshot(descriptor) else { return .unavailable }
        guard first.pid == expectedProcessID, first.uid == expectedProcess.userID,
              ProxyRelaySocketOwnerInspector.processIdentity(expectedProcessID) == expectedProcess else { return .unrelated }
        guard let second = snapshot(descriptor), first == second,
              ProxyRelaySocketOwnerInspector.processIdentity(expectedProcessID) == expectedProcess else { return .unavailable }
        return .matched(.init(descriptor: descriptor, socketIdentity: first.identity,
                              processID: expectedProcessID, process: expectedProcess))
    }

    static func revalidate(_ evidence: ProxyRelayControlPeerEvidence) -> Bool {
        guard let current = snapshot(evidence.descriptor), current.identity == evidence.socketIdentity,
              current.pid == evidence.processID, current.uid == evidence.process.userID,
              ProxyRelaySocketOwnerInspector.processIdentity(evidence.processID) == evidence.process,
              let again = snapshot(evidence.descriptor), again == current else { return false }
        return true
    }

    /// Exact running code is required in addition to same-user Unix ownership.
    /// This fresh check remains point-in-time; session revocation and request
    /// framing must be checked by the persistent owner before every command.
    static func matchesLiveCode(_ evidence: ProxyRelayControlPeerEvidence, expected: ProxyRelayExpectedCode) -> Bool {
        revalidate(evidence) &&
            ProxyRelayLiveCodeVerifier.matches(processID: evidence.processID, expectedProcess: evidence.process, expectedCode: expected) &&
            revalidate(evidence)
    }

    private struct Snapshot: Equatable {
        let identity: ProxyRelayControlSocketIdentity
        let pid: pid_t
        let uid: uid_t
    }

    private static func snapshot(_ descriptor: Int32) -> Snapshot? {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              value.st_uid == geteuid() else { return nil }
        var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0, address.ss_family == sa_family_t(AF_UNIX) else { return nil }
        var type: Int32 = 0, typeLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &typeLength) == 0,
              typeLength == MemoryLayout<Int32>.size, type == SOCK_STREAM else { return nil }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else { return nil }
        var pid: pid_t = 0, pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0,
              pidLength == MemoryLayout<pid_t>.size, pid > 0 else { return nil }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              ProxyRelayControlSocketIdentity(after) == ProxyRelayControlSocketIdentity(value) else { return nil }
        return .init(identity: .init(after), pid: pid, uid: uid)
    }
}
