import Foundation

/// One stdio session keeps one GUI connection. Failed/uncertain exchanges are
/// never retried automatically and a new connection cannot inherit windows.
@MainActor
final class MCPGUIControlClient {
    typealias Wire = MCPGUIControlProtocol
    private let root: URL
    private let connector: @Sendable (URL) throws -> MCPGUIControlSocket.Client
    private var socket: MCPGUIControlSocket.Client?
    private var generation: UUID?
    private var sequence: UInt64 = 1
    private(set) var ownedProfiles: Set<UUID> = []
    private var active = false
    private var disconnected = false
    init(root: URL) {
        self.root = root
        connector = { try MCPGUIControlSocket.Client.connect(root: $0, expectedServerCode: MCPGUIControlSocket.currentExecutableCode()) }
    }
#if DEBUG
    init(root: URL, connector: @escaping @Sendable (URL) throws -> MCPGUIControlSocket.Client) {
        self.root = root; self.connector = connector
    }
#endif
    var hasConnection: Bool { socket != nil && !disconnected }
    func close() {
        disconnected = true; socket?.invalidate(); socket = nil; generation = nil; ownedProfiles.removeAll()
    }
    func start(profileID: UUID, revision: UInt64) async throws -> Wire.Reply {
        guard !active, !disconnected else { throw Wire.Failure.unavailable }
        active = true; defer { active = false }
        if socket == nil {
            let root = root, connector = connector
            let connected = try await Task.detached(priority: .utility) {
                try connector(root)
            }.value
            guard !disconnected, !Task.isCancelled else { connected.invalidate(); throw Wire.Failure.unavailable }
            socket = connected
            let request = Wire.Request(endpointGeneration: connected.endpointGeneration,
                libraryIdentitySHA256: connected.libraryIdentitySHA256, sequence: 1, operation: .connect)
            let reply = try await exchange(connected, request)
            guard let generation = reply.connectionGeneration, reply.failure == nil else { close(); throw reply.failure ?? .unavailable }
            self.generation = generation
            // Keep this pending connection while the person chooses scope.
            if reply.state == .pendingConsent { throw Wire.Failure.consentRequired }
        }
        let reply = try await command(.start, profileID: profileID, revision: revision)
        ownedProfiles.insert(profileID)
        return reply
    }
    func lifecycle(_ operation: Wire.Command, profileID: UUID) async throws -> Wire.Reply {
        guard [.status, .stop].contains(operation), !active, !disconnected, ownedProfiles.contains(profileID) else { throw Wire.Failure.ownershipLost }
        active = true; defer { active = false }
        return try await command(operation, profileID: profileID, revision: nil)
    }
    private func command(_ operation: Wire.Command, profileID: UUID, revision: UInt64?) async throws -> Wire.Reply {
        guard let socket, let generation, sequence < UInt64.max, !disconnected else { throw Wire.Failure.unavailable }
        sequence += 1
        let request = Wire.Request(endpointGeneration: socket.endpointGeneration, libraryIdentitySHA256: socket.libraryIdentitySHA256,
            connectionGeneration: generation, sequence: sequence, operation: operation, profileID: profileID, expectedRevision: revision)
        let reply = try await exchange(socket, request)
        if let failure = reply.failure { throw failure }
        return reply
    }
    private func exchange(_ socket: MCPGUIControlSocket.Client, _ request: Wire.Request) async throws -> Wire.Reply {
        let task = Task.detached(priority: .utility) { try socket.exchange(request) }
        do {
            let reply = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel(); socket.invalidate() })
            guard !disconnected, !Task.isCancelled else { throw Wire.Failure.unavailable }
            return reply
        } catch { close(); throw Wire.Failure.unavailable }
    }
}
