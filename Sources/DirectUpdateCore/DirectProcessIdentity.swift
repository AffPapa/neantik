import Darwin
import Foundation

package struct BrowserProcessKernelIdentity: Equatable, Sendable {
    package let startSeconds: Int64
    package let startMicroseconds: Int32
    package init(startSeconds: Int64, startMicroseconds: Int32) {
        self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
}

package struct ProxyRelayOwnerProcessIdentity: Equatable, Sendable {
    package let generation: BrowserProcessKernelIdentity
    package let userID: uid_t
    package let parentProcessID: pid_t
    package init(generation: BrowserProcessKernelIdentity, userID: uid_t, parentProcessID: pid_t) {
        self.generation = generation; self.userID = userID; self.parentProcessID = parentProcessID
    }
}

package enum DirectProcessIdentityInspector {
    package static func processIdentity(_ pid: pid_t) -> ProxyRelayOwnerProcessIdentity? {
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

}
