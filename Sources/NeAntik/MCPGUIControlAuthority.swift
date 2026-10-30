import Foundation

/// Ephemeral consent and launch ownership, separate from socket/code identity.
/// EOF/revocation only removes authority: it never closes a browser window.
struct MCPGUIControlAuthority: Sendable {
    typealias ProtocolValue = MCPGUIControlProtocol
    typealias Failure = ProtocolValue.Failure
    struct Client: Identifiable, Equatable, Sendable {
        let id: UUID
        let generation: UUID
        fileprivate var sequence: UInt64
        fileprivate(set) var approvedProfiles: Set<UUID>?
        fileprivate var authorizedRequest: ProtocolValue.Request?
        fileprivate var committed = false
        var isPending: Bool { approvedProfiles == nil }
    }
    private struct Launch: Sendable {
        let connectionID: UUID
        let connectionGeneration: UUID
        let browserGeneration: UUID
        var stopRequested = false
        var closed = false
    }
    let endpointGeneration: UUID
    let libraryIdentitySHA256: String
    private(set) var clients: [UUID: Client] = [:]
    private var launches: [UUID: Launch] = [:]

    init(endpointGeneration: UUID = UUID(), libraryIdentitySHA256: String) {
        self.endpointGeneration = endpointGeneration; self.libraryIdentitySHA256 = libraryIdentitySHA256
    }

    mutating func connect(_ request: ProtocolValue.Request, transportID: UUID) throws -> Client {
        try validateEndpoint(request)
        guard request.operation == .connect, clients[transportID] == nil else { throw Failure.staleSession }
        guard clients.count < 8 else { throw Failure.busy }
        let client = Client(id: transportID, generation: UUID(), sequence: 1, approvedProfiles: nil, authorizedRequest: nil)
        clients[transportID] = client
        return client
    }

    mutating func approve(transportID: UUID, profiles: Set<UUID>) throws {
        guard var client = clients[transportID], client.isPending else { throw Failure.staleSession }
        guard !profiles.isEmpty, profiles.count <= 64, !profiles.contains(ProtocolValue.Request.zero) else { throw Failure.denied }
        client.approvedProfiles = profiles; clients[transportID] = client
    }

    /// Consume each well-bound request once, including a consent/permission
    /// refusal. An uncertain write response must close the client connection.
    mutating func authorize(_ request: ProtocolValue.Request, transportID: UUID) throws {
        try validateEndpoint(request)
        guard request.operation != .connect, var client = clients[transportID],
              request.connectionGeneration == client.generation, client.sequence < UInt64.max,
              ProtocolValue.Request.decimal(request.sequence) == client.sequence + 1 else { throw Failure.staleSession }
        client.sequence += 1; client.authorizedRequest = nil; client.committed = false
        clients[transportID] = client
        try checkGrant(request, transportID: transportID)
        client.authorizedRequest = request; clients[transportID] = client
    }

    /// Recheck after every suspension; a prior authorize() is not a lease.
    func requireScope(_ request: ProtocolValue.Request, transportID: UUID) throws {
        try validateEndpoint(request)
        guard let client = clients[transportID], client.authorizedRequest == request,
              ProtocolValue.Request.decimal(request.sequence) == client.sequence else { throw Failure.staleSession }
        try checkGrant(request, transportID: transportID)
    }

    private func checkGrant(_ request: ProtocolValue.Request, transportID: UUID) throws {
        guard let client = clients[transportID], request.connectionGeneration == client.generation,
              let profileID = request.profileID else { throw Failure.staleSession }
        guard let scope = client.approvedProfiles else { throw Failure.consentRequired }
        guard scope.contains(profileID) else { throw Failure.denied }
    }

    mutating func recordLaunch(_ request: ProtocolValue.Request, transportID: UUID, browserGeneration: UUID) throws {
        try requireLaunchAvailable(request, transportID: transportID)
        guard request.operation == .start, let profileID = request.profileID,
              let generation = request.connectionGeneration else { throw Failure.malformed }
        guard clients[transportID]?.committed == false else { throw Failure.staleSession }
        guard browserGeneration != ProtocolValue.Request.zero,
              launches[profileID] == nil || launches[profileID]?.closed == true else { throw Failure.busy }
        // Caller can record only the generation returned by a successful fresh
        // canonical launch. This operation never adopts an existing window.
        launches[profileID] = Launch(connectionID: transportID, connectionGeneration: generation, browserGeneration: browserGeneration)
        clients[transportID]!.committed = true
    }

    func requireLaunchAvailable(_ request: ProtocolValue.Request, transportID: UUID) throws {
        try requireScope(request, transportID: transportID)
        guard request.operation == .start, let profileID = request.profileID,
              clients[transportID]?.committed == false else { throw Failure.staleSession }
        guard launches[profileID] == nil || launches[profileID]?.closed == true else { throw Failure.busy }
    }

    func ownedGeneration(_ request: ProtocolValue.Request, transportID: UUID) throws -> UUID {
        try requireScope(request, transportID: transportID)
        guard let profileID = request.profileID, let launch = launches[profileID],
              launch.connectionID == transportID, launch.connectionGeneration == request.connectionGeneration else { throw Failure.ownershipLost }
        return launch.browserGeneration
    }

    func state(_ request: ProtocolValue.Request, transportID: UUID, currentBrowserGeneration: UUID?, saveFailed: Bool) throws -> ProtocolValue.State {
        let owned = try ownedGeneration(request, transportID: transportID)
        guard let currentBrowserGeneration else {
            if saveFailed { return .saveFailed }
            return launches[request.profileID!]?.closed == true ? .stopped : .ownershipLost
        }
        guard currentBrowserGeneration == owned else { return .ownershipLost }
        if saveFailed { return .saveFailed }
        return launches[request.profileID!]?.stopRequested == true ? .stopPending : .managed
    }

    mutating func markStopRequested(_ request: ProtocolValue.Request, transportID: UUID, currentBrowserGeneration: UUID) throws {
        guard request.operation == .stop else { throw Failure.malformed }
        guard try ownedGeneration(request, transportID: transportID) == currentBrowserGeneration else { throw Failure.ownershipLost }
        guard clients[transportID]?.committed == false else { throw Failure.staleSession }
        launches[request.profileID!]!.stopRequested = true
        clients[transportID]!.committed = true
    }

    /// Only the canonical manager's settled-close callback supplies this token.
    /// A stale callback cannot retire a replacement window's ownership.
    @discardableResult mutating func observeClosed(profileID: UUID, browserGeneration: UUID) -> Bool {
        guard launches[profileID]?.browserGeneration == browserGeneration else { return false }
        launches[profileID]!.closed = true
        return true
    }

    mutating func disconnect(_ transportID: UUID) {
        clients.removeValue(forKey: transportID)
        launches = launches.filter { $0.value.connectionID != transportID }
    }
    mutating func revokeAll() { clients.removeAll(); launches.removeAll() }

    private func validateEndpoint(_ request: ProtocolValue.Request) throws {
        try request.validate()
        guard request.endpointGeneration == endpointGeneration,
              request.libraryIdentitySHA256 == libraryIdentitySHA256 else { throw Failure.staleSession }
    }
}
