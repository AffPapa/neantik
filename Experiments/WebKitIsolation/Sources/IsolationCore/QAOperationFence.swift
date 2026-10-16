import Foundation

/// MainActor-owned by the QA controller. A pending NSWorkspace launch holds
/// the same exclusive lease as configuration/extension changes, until its
/// completion arrives. Stale callbacks cannot release a newer operation.
public struct QAOperationFence {
    public enum Kind: Equatable, Sendable { case launchHost, configuration, extensionRequest, providerControl, observation, closeHosts }
    public struct Ticket: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let kind: Kind
    }
    private var active: Ticket?
    public init() {}
    public var isBusy: Bool { active != nil }
    public var pendingLaunches: Int { active?.kind == .launchHost ? 1 : 0 }
    public mutating func begin(_ kind: Kind) -> Ticket? {
        guard active == nil else { return nil }
        let ticket = Ticket(id: UUID(), kind: kind); active = ticket
        return ticket
    }
    @discardableResult public mutating func finish(_ ticket: Ticket) -> Bool {
        guard active == ticket else { return false }
        active = nil; return true
    }
}
