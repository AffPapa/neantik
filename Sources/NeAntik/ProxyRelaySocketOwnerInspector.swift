import Darwin
import Foundation

/// A socket-owner observation, not permission to use a relay. The product
/// caller must separately bind this PID to its signed browser NetworkService,
/// launch generation, profile and live helper authority before sending auth.
struct ProxyRelaySocketOwnerEvidence: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    let processID: pid_t
    let processGeneration: BrowserProcessKernelIdentity
    let descriptor: Int32
    fileprivate let socketGeneration: UInt64
    fileprivate let socketHandle: UInt64
    var description: String { "ProxyRelaySocketOwnerEvidence(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct ProxyRelayOwnerProcessIdentity: Equatable, Sendable {
    let generation: BrowserProcessKernelIdentity
    let userID: uid_t
    let parentProcessID: pid_t
}

enum ProxyRelaySocketOwnerResult: Sendable {
    case matched(ProxyRelaySocketOwnerEvidence), unrelated, unavailable
}

/// Reads only one explicitly supplied process. It never scans argv, paths,
/// payloads, unrelated processes or credentials. Unknown inspection refuses
/// proof; loopback source ports alone are never an authorization mechanism.
enum ProxyRelaySocketOwnerInspector {
    static let maximumDescriptors = 8192

    static func processIdentity(_ pid: pid_t) -> ProxyRelayOwnerProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let count = withUnsafeMutableBytes(of: &info) { bytes in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, bytes.baseAddress, Int32(bytes.count))
        }
        guard count == MemoryLayout<proc_bsdinfo>.size, info.pbi_pid == pid,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        return .init(generation: .init(startSeconds: Int64(info.pbi_start_tvsec), startMicroseconds: Int32(info.pbi_start_tvusec)),
                     userID: info.pbi_uid, parentProcessID: pid_t(info.pbi_ppid))
    }

    static func inspect(processID: pid_t, expected: ProxyRelayOwnerProcessIdentity,
                        clientPort: UInt16, relayPort: UInt16) -> ProxyRelaySocketOwnerResult {
        guard clientPort > 0, relayPort > 0, expected.userID == geteuid(), processID > 0 else { return .unrelated }
        guard let before = processIdentity(processID) else { return .unavailable }
        guard before == expected else { return .unrelated }
        let requiredBytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard requiredBytes >= 0, Int(requiredBytes) % stride == 0 else { return .unavailable }
        let capacity = min(maximumDescriptors, max(64, Int(requiredBytes) / stride + 128))
        guard Int(requiredBytes) / stride < maximumDescriptors else { return .unavailable }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let count = descriptors.withUnsafeMutableBytes { bytes in
            proc_pidinfo(processID, PROC_PIDLISTFDS, 0, bytes.baseAddress, Int32(bytes.count))
        }
        guard count >= 0, Int(count) % stride == 0, Int(count) < capacity * stride else { return .unavailable }
        var unreadableSocket = false
        for fd in descriptors.prefix(Int(count) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            guard let socket = readSocket(processID, fd.proc_fd) else { unreadableSocket = true; continue }
            guard matches(socket, clientPort: clientPort, relayPort: relayPort) else { continue }
            // Pin the FD's kernel socket instance as well as PID start time.
            // Reject changes observed between these reads. This is not an
            // atomic lease: revalidate immediately before use. A descriptor
            // can also be shared; this does not prove exclusive ownership.
            guard let again = readSocket(processID, fd.proc_fd),
                  matches(again, clientPort: clientPort, relayPort: relayPort),
                  again.psi.soi_so == socket.psi.soi_so,
                  again.psi.soi_proto.pri_tcp.tcpsi_ini.insi_gencnt == socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_gencnt,
                  processIdentity(processID) == expected else { return .unavailable }
            return .matched(.init(processID: processID, processGeneration: expected.generation,
                                  descriptor: fd.proc_fd, socketGeneration: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_gencnt,
                                  socketHandle: socket.psi.soi_so))
        }
        guard processIdentity(processID) == expected else { return .unavailable }
        return unreadableSocket ? .unavailable : .unrelated
    }

    static func revalidate(_ evidence: ProxyRelaySocketOwnerEvidence, expected: ProxyRelayOwnerProcessIdentity,
                           clientPort: UInt16, relayPort: UInt16) -> Bool {
        guard evidence.processGeneration == expected.generation, expected.userID == geteuid(),
              processIdentity(evidence.processID) == expected,
              let socket = readSocket(evidence.processID, evidence.descriptor),
              socket.psi.soi_so == evidence.socketHandle,
              socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_gencnt == evidence.socketGeneration,
              matches(socket, clientPort: clientPort, relayPort: relayPort),
              processIdentity(evidence.processID) == expected else { return false }
        return true
    }

    private static func readSocket(_ pid: pid_t, _ fd: Int32) -> socket_fdinfo? {
        var socket = socket_fdinfo()
        let count = withUnsafeMutableBytes(of: &socket) { bytes in
            proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, bytes.baseAddress, Int32(bytes.count))
        }
        return count == MemoryLayout<socket_fdinfo>.size ? socket : nil
    }
    private static func matches(_ socket: socket_fdinfo, clientPort: UInt16, relayPort: UInt16) -> Bool {
        let s = socket.psi, tcp = s.soi_proto.pri_tcp, ip = tcp.tcpsi_ini
        let loopback = inet_addr("127.0.0.1")
        return s.soi_family == AF_INET && s.soi_type == SOCK_STREAM && s.soi_protocol == IPPROTO_TCP && s.soi_kind == SOCKINFO_TCP &&
            tcp.tcpsi_state == TSI_S_ESTABLISHED && ip.insi_vflag == INI_IPV4 &&
            ip.insi_laddr.ina_46.i46a_addr4.s_addr == loopback && ip.insi_faddr.ina_46.i46a_addr4.s_addr == loopback &&
            UInt16(truncatingIfNeeded: ip.insi_lport).bigEndian == clientPort &&
            UInt16(truncatingIfNeeded: ip.insi_fport).bigEndian == relayPort
    }
}
