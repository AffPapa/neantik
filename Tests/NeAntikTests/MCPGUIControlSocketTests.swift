import Darwin
import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct MCPGUIControlSocketTests {
    typealias Wire = MCPGUIControlProtocol
    @MainActor final class Events {
        var disconnected = Set<UUID>()
        var entered = false, revoked = false, release = false, committed = false
        var connection: MCPGUIControlSocket.Connection?
    }
    private func fixture() throws -> (URL, MCPGUIControlEndpoint.Listener) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-own-mcp-socket-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
        return (root, try MCPGUIControlEndpoint.Listener(library: library, generation: UUID()))
    }
    private func request(_ client: MCPGUIControlSocket.Client) -> Wire.Request {
        .init(endpointGeneration: client.endpointGeneration, libraryIdentitySHA256: client.libraryIdentitySHA256, sequence: 1, operation: .connect)
    }
    @Test func actualKernelPeerRoundTripAndStopJoinCleanup() async throws {
        let (root, endpoint) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let generation = UUID()
        let events = Events()
        let server = MCPGUIControlSocket.Server.forTesting(endpoint: endpoint, handler: { request, _, connection in
            #expect(connection.isCurrent)
            return Wire.Reply(request: request, connectionGeneration: generation, state: .pendingConsent)
        }, disconnected: { events.disconnected.insert($0) })
        let client = try await Task.detached { try MCPGUIControlSocket.Client.connectForTesting(root: root) }.value
        let request = request(client)
        let result = try await Task.detached { try client.exchange(request) }.value
        #expect(result.state == .pendingConsent && result.connectionGeneration == generation)
        await server.stop()
        #expect(!endpoint.isCurrent && events.disconnected.count == 1)
        #expect(throws: (any Error).self) { try client.exchange(request) }
        client.invalidate()
    }
    @Test func halfCloseRevokesDuringSuspendedHandlerBeforeMutation() async throws {
        let (root, endpoint) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let events = Events()
        let server = MCPGUIControlSocket.Server.forTesting(endpoint: endpoint, handler: { request, _, connection in
            events.entered = true
            while !events.release { try? await Task.sleep(for: .milliseconds(10)) }
            events.committed = connection.isCurrent && !events.revoked
            return Wire.Reply(request: request, connectionGeneration: UUID(), state: .pendingConsent)
        }, disconnected: { _ in events.revoked = true })
        let client = try await Task.detached { try MCPGUIControlSocket.Client.connectForTesting(root: root) }.value
        let request = request(client)
        let exchange = Task.detached { try client.exchange(request) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !events.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events.entered)
        client.halfCloseForTesting()
        while !events.revoked, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events.revoked)
        events.release = true
        _ = try? await exchange.value
        await server.stop()
        #expect(!events.committed && !endpoint.isCurrent)
    }
    @Test func queuedBytesDoNotHideHalfCloseFromFinalAuthenticationWithoutMonitor() async throws {
        let (root, endpoint) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let events = Events()
        let server = MCPGUIControlSocket.Server.forTesting(endpoint: endpoint, monitorEOF: false, handler: { request, _, connection in
            events.connection = connection; events.entered = true
            while !events.release { try? await Task.sleep(for: .milliseconds(10)) }
            events.committed = connection.authenticate()
            return Wire.Reply(request: request, connectionGeneration: UUID(), state: .pendingConsent)
        }, disconnected: { _ in })
        let client = try await Task.detached { try MCPGUIControlSocket.Client.connectForTesting(root: root) }.value
        let request = request(client)
        let exchange = Task.detached { try client.exchange(request) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !events.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let connection = try #require(events.connection)
        try client.sendByteForTesting(74)
        #expect(connection.authenticate())
        #expect(connection.peekByteForTesting() == 74) // Observation never consumes queued data.
        client.halfCloseForTesting()
        #expect(connection.kernelPeerIsCurrentForTesting) // PID alone is insufficient.
        #expect(!connection.authenticate()) // No monitor or grace period.
        events.release = true
        _ = try? await exchange.value
        await server.stop()
        #expect(!events.committed)
    }
}
