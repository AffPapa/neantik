import Foundation

/// Process-local transport evidence for one relay. No destination, payload,
/// credential, PID or socket identity is retained. The owner must authenticate
/// and bind any exported snapshot to its exact browser/session/configuration.
/// Tunnel/byte activity cannot establish HTTP, TLS-page or DNS-route results.
final class BrowserRelayActivity: @unchecked Sendable {
    enum End: String, Codable, Sendable {
        case completed, cancelled, localSetupFailed, clientNegotiationFailed
        case admissionRevoked, upstreamNegotiationFailed, browserReplyFailed, streamFailed
        var isFailure: Bool { self != .completed && self != .cancelled }
        /// A later task cancellation must not hide an already received concrete
        /// protocol, TLS or socket failure. Transport cancellation emits its own
        /// CancellationError; do not infer it from Task.isCancelled here.
        static func failure(_ error: Error, during phase: End) -> End {
            if error is CancellationError { return .cancelled }
            if (error as? ProxyRelayTransportError) == .authorizationRejected { return .admissionRevoked }
            return phase
        }
    }
    struct Snapshot: Codable, Equatable, Sendable {
        let schema: Int
        let sequence: UInt64
        let admittedConnections: UInt64
        let upstreamTunnels: UInt64
        /// SOCKS success reply processed for sending by the local connection.
        /// This is not acknowledgment by the browser or HTTP request success.
        let successRepliesSent: UInt64
        let completedConnections: UInt64
        let failedConnections: UInt64
        let cancelledConnections: UInt64
        let activeConnections: Int
        let listenerStopped: Bool
        let countersSaturated: Bool
        let lastEnd: End?
        let lastFailure: End?
        let lastFailureSequence: UInt64?
        /// Monotonic elapsed time, not a refreshed success timestamp. Quiet
        /// established streams have no automatic failure/freshness verdict.
        let lastEventAgeMilliseconds: UInt64?
    }
    struct Ticket: Hashable, Sendable { fileprivate let id = UUID() }
    private struct Stream { var tunnel = false; var replySent = false }
    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let counterLimit: UInt64
    private var streams: [Ticket: Stream] = [:]
    private var stopped = false, saturated = false
    private var sequence: UInt64 = 0, admitted: UInt64 = 0, tunnels: UInt64 = 0, repliesSent: UInt64 = 0
    private var completed: UInt64 = 0, failed: UInt64 = 0, cancelled: UInt64 = 0
    private var lastEnd: End?, lastFailure: End?, lastFailureSequence: UInt64?, lastEvent: UInt64?

    init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         counterLimit: UInt64 = 9_007_199_254_740_991) {
        self.clock = clock; self.counterLimit = max(1, counterLimit)
    }
    /// Invoke only after the relay's signed-browser admission succeeds.
    func begin() -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, streams.count < 64 else { return nil }
        let ticket = Ticket(); streams[ticket] = Stream()
        increment(&admitted); event(); return ticket
    }
    func established(_ ticket: Ticket) {
        lock.lock(); defer { lock.unlock() }
        guard var stream = streams[ticket], !stream.tunnel else { return }
        stream.tunnel = true; streams[ticket] = stream; increment(&tunnels); event()
    }
    func replySent(_ ticket: Ticket) {
        lock.lock(); defer { lock.unlock() }
        guard var stream = streams[ticket], stream.tunnel, !stream.replySent else { return }
        stream.replySent = true; streams[ticket] = stream; increment(&repliesSent); event()
    }
    func finish(_ ticket: Ticket, as outcome: End) {
        lock.lock(); defer { lock.unlock() }
        guard streams.removeValue(forKey: ticket) != nil else { return }
        switch outcome {
        case .completed: increment(&completed)
        case .cancelled: increment(&cancelled)
        default: increment(&failed)
        }
        lastEnd = outcome; event()
        if outcome.isFailure { lastFailure = outcome; lastFailureSequence = sequence }
    }
    func listenerDidStop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true; event()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let age = lastEvent.map { now >= $0 ? (now - $0) / 1_000_000 : 0 }
        return .init(schema: 1, sequence: sequence, admittedConnections: admitted,
            upstreamTunnels: tunnels, successRepliesSent: repliesSent,
            completedConnections: completed, failedConnections: failed, cancelledConnections: cancelled,
            activeConnections: streams.count, listenerStopped: stopped, countersSaturated: saturated,
            lastEnd: lastEnd, lastFailure: lastFailure, lastFailureSequence: lastFailureSequence,
            lastEventAgeMilliseconds: age)
    }
    private func increment(_ value: inout UInt64) {
        if value < counterLimit { value += 1 } else { saturated = true }
    }
    private func event() { increment(&sequence); lastEvent = clock() }
}
