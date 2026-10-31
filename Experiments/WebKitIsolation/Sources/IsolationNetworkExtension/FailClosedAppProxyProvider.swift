import Foundation
import NetworkExtension
import IsolationCore

/// Provider base for the future signed system extension. This is a compile-
/// checked adapter, not an installable extension or a shipping capability.
/// An authenticated bootstrap, provider packaging, dedicated profile host,
/// and kernel qualification must be supplied before it can start.
open class FailClosedAppProxyProvider: NEAppProxyProvider {
    private let lifetime = ProviderLifetime<IsolatedTCPFlowRouter>()
    private let callbacks = ProviderCallbackSequencer()
    /// Override only after trusted control enrollment. This factory must be
    /// inert/nonblocking; do not wait for IPC or framework completions here.
    /// No persisted config/argv can turn missing authority into a live route.
    open func makeAuthenticatedRouter() throws -> IsolatedTCPFlowRouter {
        throw IsolationRefusal.revoked
    }
    public override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let completion = FrameworkCompletion(completionHandler)
        callbacks.enqueue { [self] in
            let ticket: ProviderLifetime<IsolatedTCPFlowRouter>.StartTicket
            do { ticket = try lifetime.beginStart() }
            catch { completion.finish(IsolationRefusal.revoked); return }
            // No lifecycle lock across the override. FIFO serialization also
            // fences startup completion before a concurrent stop completion.
            let resource = try? makeAuthenticatedRouter()
            let result = lifetime.completeStart(ticket, resource: resource)
            if let work = result.cleanup { drain(work) }
            completion.finish(result.installed ? nil : IsolationRefusal.revoked)
        }
    }
    public override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // NEAppProxyProvider false TERMINATES. Do not change the superclass
        // to NETransparentProxyProvider, whose false means unproxied traffic.
        lifetime.current?.handle(flow) ?? false
    }
    public override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = FrameworkCompletion { _ in completionHandler() }
        callbacks.enqueue { [self] in
            if let work = lifetime.beginStop(completion: { completion.finish(nil) }) { drain(work) }
        }
    }
    private func drain(_ work: ProviderLifetime<IsolatedTCPFlowRouter>.StopWork) {
        let owner = lifetime, sequencer = callbacks
        Task {
            await work.resource?.stopAndDrain()
            sequencer.enqueue { owner.completeStop(work) }
        }
    }
}

/// Imported legacy NetworkExtension completions support asynchronous finishing
/// but are not annotated Sendable. Keep that boundary explicit and invoke each
/// framework completion once, outside this object's lock.
private final class FrameworkCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var body: ((Error?) -> Void)?
    init(_ body: @escaping (Error?) -> Void) { self.body = body }
    func finish(_ error: Error?) {
        lock.lock(); let call = body; body = nil; lock.unlock(); call?(error)
    }
}
