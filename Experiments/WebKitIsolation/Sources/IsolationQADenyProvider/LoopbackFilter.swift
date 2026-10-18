import Foundation
import NetworkExtension
import OSLog
import IsolationCore
import IsolationNetworkExtension

/// Supplemental QA experiment. It is not advertised as a kill switch: OS
/// behavior on crash/disable and missing WebKit attribution must be measured.
/// Nothing registers this class or broadens signed entitlements automatically.
@objc(NeAntikIsolationQALoopbackFilter)
// Mutable ownership is confined to ProviderLifetime's lock/FIFO. The imported
// framework delivers callbacks on different queues; no unlocked state exists.
final class QALoopbackFilter: NEFilterDataProvider, @unchecked Sendable {
    private struct Configuration: Sendable {
        let scope: QALoopbackFilterScope
        let host: SignedHostPin
        let control: SignedHostPin
        let run: UUID
    }
    private let lifetime = ProviderLifetime<Configuration>()
    private let callbacks = ProviderCallbackSequencer()
    private let log = Logger(subsystem: "app.neantik.desktop.network-qa.proxy", category: "owned-loopback")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.network-qa.proxy",
              let config = filterConfiguration.vendorConfiguration,
              Set(config.keys) == ["runID", "ports", "hostCDHash", "controlCDHash"],
              let text = config["runID"] as? String, let run = UUID(uuidString: text),
              let ownRun = Bundle.main.object(forInfoDictionaryKey: "NeAntikQARunID") as? String,
              UUID(uuidString: ownRun) == run,
              let rawPorts = config["ports"] as? [Int],
              rawPorts.allSatisfy({ (1...65535).contains($0) }),
              let scope = try? QALoopbackFilterScope(ports: rawPorts.map(UInt16.init)),
              let hostHash = Self.hash(config["hostCDHash"]),
              let controlHash = Self.hash(config["controlCDHash"]), hostHash != controlHash,
              let host = try? SignedHostPin(identifier: "app.neantik.desktop.network-qa.profilehost", team: "H6VGU2M6JD", cdHash: hostHash),
              let control = try? SignedHostPin(identifier: "app.neantik.desktop.network-qa.control", team: "H6VGU2M6JD", cdHash: controlHash)
        else { completionHandler(NSError(domain: "app.neantik.isolation.qa.filter", code: 1)); return }
        let next = Configuration(scope: scope, host: host, control: control, run: run)
        let completion = QAFilterCompletion(completionHandler)
        callbacks.enqueue { [self] in
            let ticket: ProviderLifetime<Configuration>.StartTicket
            do { ticket = try lifetime.beginStart() }
            catch { completion.finish(IsolationRefusal.revoked); return }
            apply(QALoopbackFilterSettings.make(scope: scope)) { [self] error in
                callbacks.enqueue { [self] in
                    let publication = lifetime.completeStart(ticket, resource: error == nil ? next : nil)
                    log.info("owned-filter-start success=\(publication.installed, privacy: .public) run=\(next.run.uuidString, privacy: .public)")
                    completion.finish(publication.installed ? nil : (error ?? IsolationRefusal.revoked))
                    // Stop waits for the pending apply callback, and a stale
                    // completion can never publish or clear a newer run.
                    if let work = publication.cleanup { lifetime.completeStop(work) }
                }
            }
        }
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // Inspect no unrelated destination, URL, payload or process identity.
        guard let config = lifetime.current else { return unexpected("configuration-not-running") }
        guard flow.direction == .outbound else { return unexpected("direction") }
        guard let socket = flow as? NEFilterSocketFlow else { return unexpected("flow-type") }
        guard let endpoint = socket.remoteEndpoint as? NWHostEndpoint else { return unexpected("endpoint-unavailable") }
        guard let port = UInt16(endpoint.port), config.scope.contains(host: endpoint.hostname, port: port)
        else { return unexpected("outside-owned-scope") }
        // The original application token matters. A WebKit helper's token or
        // shared UID/team may never substitute for profile ownership.
        let token = flow.sourceAppAuditToken
        let hostCheck = ownerDiagnostic(config.host, token: token)
        if hostCheck.verified {
            log.info("owned-filter-flow role=A verdict=drop run=\(config.run.uuidString, privacy: .public)")
            return .drop()
        }
        let controlCheck = ownerDiagnostic(config.control, token: token)
        if controlCheck.verified {
            log.info("owned-filter-flow role=B verdict=allow run=\(config.run.uuidString, privacy: .public)")
            return .allow()
        }
        // A global unknown-identity deny would harm other apps. Allow only in
        // this owned-port experiment and record the qualification failure.
        // Any unknown observation invalidates confinement acceptance.
        log.info("owned-filter-flow role=unknown verdict=allow UNQUALIFIED run=\(config.run.uuidString, privacy: .public)")
        // Preserve the disqualifying unknown event. These bounded stage/status
        // fields diagnose the failed gate without exposing process metadata.
        log.error("owned-filter-unexpected UNQUALIFIED reason=owner-check host=\(hostCheck.diagnostic, privacy: .public) control=\(controlCheck.diagnostic, privacy: .public)")
        return .allow()
    }

    private struct OwnerCheck {
        let verified: Bool
        let diagnostic: String
    }
    private func ownerDiagnostic(_ pin: SignedHostPin, token: Data?) -> OwnerCheck {
        guard let token else { return .init(verified: false, diagnostic: "missing-token") }
        do { _ = try pin.verify(kernelAuditToken: token); return .init(verified: true, diagnostic: "verified") }
        catch let error as HostVerificationFailure { return .init(verified: false, diagnostic: error.diagnostic) }
        catch { return .init(verified: false, diagnostic: "unexpected-verification-error") }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = QAFilterCompletion { _ in completionHandler() }
        callbacks.enqueue { [self] in
            if let work = lifetime.beginStop(completion: { completion.finish(nil) }) {
                // This deny-only probe retains no forwarded connections/data.
                lifetime.completeStop(work)
            }
            log.info("owned-filter-stop;OS failure behavior remains separately measured")
        }
    }

    private func unexpected(_ reason: String) -> NEFilterNewFlowVerdict {
        log.error("owned-filter-unexpected UNQUALIFIED reason=\(reason, privacy: .public)")
        return .allow() // Preserve unrelated traffic; invalidate qualification.
    }

    private static func hash(_ value: Any?) -> Data? {
        guard let hex = value as? String, hex.utf8.count == 40,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return Data(stride(from: 0, to: 40, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        })
    }
}

private final class QAFilterCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var body: ((Error?) -> Void)?
    init(_ body: @escaping (Error?) -> Void) { self.body = body }
    func finish(_ error: Error?) {
        lock.lock(); let callback = body; body = nil; lock.unlock()
        callback?(error)
    }
}
