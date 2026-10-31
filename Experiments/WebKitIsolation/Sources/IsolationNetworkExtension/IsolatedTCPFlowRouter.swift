import Foundation
import NetworkExtension
import IsolationCore

public struct TunnelDestination: Sendable, CustomStringConvertible, CustomReflectable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) throws {
        guard !host.isEmpty, host.utf8.count <= 253, port > 0,
              host.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }),
              !host.contains("@"), !host.contains("/"), !host.contains("\\") else { throw IsolationRefusal.invalidScope }
        self.host = host; self.port = port
    }
    public var description: String { "TunnelDestination(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The data plane must supply an authenticated HTTP/SOCKS/HTTPS tunnel to a
/// fixed configured proxy, with remote DNS and default certificate validation.
/// No destination dialer is included here. Installation/IPC/tunnel integration
/// and kernel fail-closed qualification remain separate, uncompleted gates.
public protocol IsolatedProxyTunnel: AnyObject, Sendable {
    // Construction is inert. The adapter attaches cancellation before this
    // starts networking; authorize must be checked before credential writes.
    func establish(authorize: @escaping @Sendable () -> Bool) async throws
    func receive(maximum: Int) async throws -> Data
    func send(_ data: Data) async throws
    func finishWrite() async throws
    func cancel()
}
public typealias IsolatedTunnelConnector = @Sendable (IsolationScope, TunnelDestination) throws -> any IsolatedProxyTunnel

/// Real NE flow adapter. It is deliberately NOT a transparent proxy: its
/// caller must return false on rejection in an NEAppProxyProvider subclass,
/// where Apple's contract terminates the flow. In a transparent provider false
/// means Direct; installing this adapter there would violate the design.
public final class IsolatedTCPFlowRouter: @unchecked Sendable {
    private let ledger: IsolationLedger
    private let pin: SignedHostPin
    private let connector: IsolatedTunnelConnector
    private let lock = NSLock()
    private var active: [UUID: FlowBridge] = [:]
    private var stopped = false
    private let timer: DispatchSourceTimer
    public init(pin: SignedHostPin, ledger: IsolationLedger, connector: @escaping IsolatedTunnelConnector) {
        self.pin = pin; self.ledger = ledger; self.connector = connector
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.neantik.isolation.expiry"))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.ledger.reapExpired() }; timer.resume()
    }
    deinit { timer.cancel(); stop() }
    /// Called only by a future authenticated control channel. The channel must
    /// obtain this token from the kernel's peer metadata, never a client field.
    /// The kernel flow attribution must independently match the same host.
    public func enrollVerifiedPeer(kernelPeerAuditToken: Data, scope: IsolationScope, lifetime: TimeInterval) throws {
        let token = try pin.verify(kernelAuditToken: kernelPeerAuditToken)
        try ledger.registerVerifiedHost(token, scope: scope, lifetime: lifetime)
    }
    public func heartbeatVerifiedPeer(kernelPeerAuditToken: Data, scope: IsolationScope, lifetime: TimeInterval) throws {
        let token = try pin.verify(kernelAuditToken: kernelPeerAuditToken)
        try ledger.heartbeat(token, scope: scope, lifetime: lifetime)
    }
    public func revoke(_ scope: IsolationScope) { ledger.revoke(scope) }
    public func handle(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcp = flow as? NEAppProxyTCPFlow,
              let raw = flow.metaData.sourceAppAuditToken,
              let token = try? pin.verify(kernelAuditToken: raw),
              let endpoint = tcp.remoteEndpoint as? NWHostEndpoint,
              let port = UInt16(endpoint.port),
              let destination = try? TunnelDestination(host: flow.remoteHostname ?? endpoint.hostname, port: port) else { return false }
        let id = UUID(), bridge = FlowBridge(flow: tcp)
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        // Retain before admitting or launching any task. Revocation can now
        // close the flow even in the acquire→connect scheduling interval.
        guard let lease = try? ledger.acquire(token, transport: .tcp, cancel: { [weak bridge] in bridge?.cancel() })
        else { lock.unlock(); return false }
        bridge.lease = lease; active[id] = bridge
        lock.unlock()
        bridge.begin(destination: destination, connector: connector) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.active.removeValue(forKey: id); self.lock.unlock()
        }
        return true
    }
    /// Stops the local adapter and its flows, not the kernel's app rules.
    /// Removing/altering those rules while a host lives is prohibited.
    private func beginStop() -> [FlowBridge] {
        lock.lock(); stopped = true; let pending = Array(active.values); lock.unlock()
        timer.cancel(); ledger.stop(); pending.forEach { $0.cancel() }; return pending
    }
    public func stop() { _ = beginStop() }
    public func stopAndDrain() async {
        let pending = beginStop()
        for bridge in pending { await bridge.drain() }
    }
}

private final class FlowBridge: @unchecked Sendable {
    let flow: NEAppProxyTCPFlow
    var lease: FlowLease?
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var tunnel: (any IsolatedProxyTunnel)?
    private var cancelled = false
    init(flow: NEAppProxyTCPFlow) { self.flow = flow }
    private func requireLease() throws {
        try Task.checkCancellation()
        guard lease?.isValid == true else { throw IsolationRefusal.revoked }
    }
    func begin(destination: TunnelDestination, connector: @escaping IsolatedTunnelConnector,
               finished: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { lease?.release(); finished(); return }
        task = Task { [self] in
            var completed = false
            defer {
                terminate(error: completed ? nil : refusalError())
                lease?.release(); clearTask(); finished()
            }
            do {
                try requireLease()
                guard let lease else { throw IsolationRefusal.revoked }
                let stream = try connector(lease.scope, destination)
                let attached = attach(stream)
                guard attached else { stream.cancel(); throw IsolationRefusal.revoked }
                try requireLease()
                try await stream.establish(authorize: { lease.isValid })
                try requireLease()
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    flow.open(withLocalEndpoint: nil) { error in
                        if let error { c.resume(throwing: error) } else { c.resume() }
                    }
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.outbound(stream) }
                    group.addTask { try await self.inbound(stream) }
                    do { while try await group.next() != nil {} }
                    catch { self.cancel(); group.cancelAll(); throw error }
                }
                completed = true
            } catch {
                // Error detail may contain a URL or endpoint; never log it.
            }
        }
    }
    private func attach(_ stream: any IsolatedProxyTunnel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, lease?.isValid == true else { return false }
        tunnel = stream; return true
    }
    private func outbound(_ stream: any IsolatedProxyTunnel) async throws {
        while true {
            try requireLease()
            let data: Data = try await withCheckedThrowingContinuation { c in
                flow.readData { data, error in
                    if let error { c.resume(throwing: error) }
                    else if let data { c.resume(returning: data) }
                    else { c.resume(throwing: IsolationRefusal.revoked) }
                }
            }
            try requireLease()
            if data.isEmpty { try await stream.finishWrite(); return }
            // NE controls read size; bound each forwarded write without an
            // unbounded work queue. Only one read/write per direction is live.
            var offset = 0
            while offset < data.count {
                try requireLease()
                let end = min(offset + 64 * 1024, data.count)
                try await stream.send(Data(data[offset..<end])); offset = end
            }
        }
    }
    private func inbound(_ stream: any IsolatedProxyTunnel) async throws {
        while true {
            try requireLease()
            let data = try await stream.receive(maximum: 64 * 1024)
            try requireLease()
            guard data.count <= 64 * 1024 else { throw IsolationRefusal.capacity }
            if data.isEmpty { flow.closeWriteWithError(nil); return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                flow.write(data) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
        }
    }
    private func pendingTask() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }; return task
    }
    private func clearTask() { lock.lock(); task = nil; lock.unlock() }
    func drain() async { await pendingTask()?.value }
    private func refusalError() -> NSError {
        NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.refused.rawValue)
    }
    func cancel() { terminate(error: refusalError()) }
    private func terminate(error: Error?) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true; let stream = tunnel, pending = task
        tunnel = nil; lock.unlock()
        // Close both NE directions. Merely cancelling a Swift Task does not
        // terminate outstanding callback-based native I/O.
        flow.closeReadWithError(error); flow.closeWriteWithError(error)
        stream?.cancel(); pending?.cancel()
    }
}
