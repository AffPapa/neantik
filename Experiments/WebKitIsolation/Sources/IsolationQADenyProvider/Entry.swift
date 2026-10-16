import Foundation
import NetworkExtension
import IsolationNetworkExtension
import Darwin

/// First kernel-boundary probe only: it never forwards a byte. A real proxy
/// data plane comes after app-rule attribution and disconnected-state tests.
@objc(NeAntikIsolationQADenyProvider)
final class DenyProvider: NEAppProxyProvider {
    private let lock = NSLock()
    private var pin: SignedHostPin?
    private var runID: UUID?
    private var tcp = 0, udp = 0, matching = 0, unknown = 0
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.network-qa.proxy",
              let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let run = config["runID"] as? String, let id = UUID(uuidString: run),
              let hex = config["hostCDHash"] as? String, hex.count == 40 else { completionHandler(refused()); return }
        let bytes = stride(from: 0, to: 40, by: 2).compactMap { index -> UInt8? in
            let start = hex.index(hex.startIndex, offsetBy: index), end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        }
        guard bytes.count == 20,
              let expected = try? SignedHostPin(identifier: "app.neantik.desktop.network-qa.profilehost", team: "H6VGU2M6JD", cdHash: Data(bytes)) else { completionHandler(refused()); return }
        lock.lock(); pin = expected; runID = id; tcp = 0; udp = 0; matching = 0; unknown = 0; lock.unlock()
        completionHandler(nil)
    }
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        lock.lock(); let expected = pin; lock.unlock()
        let recognized = flow.metaData.sourceAppAuditToken.flatMap { try? expected?.verify(kernelAuditToken: $0) } != nil
        lock.lock()
        if flow is NEAppProxyTCPFlow { tcp += 1 } else { udp += 1 }
        if recognized { matching += 1 } else { unknown += 1 }
        lock.unlock()
        return false // Regular app proxy terminates; no pass-through path.
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard messageData == Data("owned-qa-counters-v1".utf8) else { completionHandler?(nil); return }
        lock.lock()
        let value: [String: Any] = ["schemaVersion":1,"runID":runID?.uuidString ?? "", "tcp":tcp,"udp":udp,"matchingHost":matching,"unknownHost":unknown,"forwarded":0]
        lock.unlock(); completionHandler?(try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lock.lock(); pin = nil; runID = nil; lock.unlock(); completionHandler()
    }
    private func refused() -> NSError { NSError(domain: "app.neantik.isolation.qa", code: 1) }
}
@main enum Main {
    static func main() {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.network-qa.proxy" else { exit(78) }
        NEProvider.startSystemExtensionMode(); dispatchMain()
    }
}
