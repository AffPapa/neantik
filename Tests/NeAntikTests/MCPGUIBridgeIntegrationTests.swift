import Foundation
import Testing
@testable import NeAntik

/// Real local streams + protocol + management/store, with synthetic window
/// lifetime only. These do not replace the signed GUI/window release gate.
@Suite(.serialized) @MainActor
struct MCPGUIBridgeIntegrationTests {
    @MainActor final class Rig {
        let root: URL
        let endpoint: MCPGUIControlEndpoint.Listener
        let engine: MCPProfileManagement
        let bridge: MCPGUIControlClient
        var control: MCPGUIControlCoordinator!
        var server: MCPGUIControlSocket.Server!
        var browser: UUID?
        var launches = 0, stops = 0
        var afterStatus: (() throws -> Void)?
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-own-mcp-bridge-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            endpoint = try MCPGUIControlEndpoint.Listener(library: .init(root: root, exclusive: true), generation: UUID())
            bridge = MCPGUIControlClient(root: root, connector: { try MCPGUIControlSocket.Client.connectForTesting(root: $0) })
            let paths = AppPaths(rootDirectory: root)
            engine = MCPProfileManagement(root: root, allowsManagement: true,
                keychain: KeychainStore(backend: MCPProfileManagementTests.Backend(), service: "own-gui-bridge", legacyService: nil),
                processes: BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent }, allowsExternalProcessSignaling: false), guiClient: bridge)
            control = MCPGUIControlCoordinator(root: root, backend: .init(
                refresh: { [unowned self] in try await engine.store.refreshExternalMetadata(force: true) },
                profile: { [unowned self] in engine.store.profile(withID: $0) },
                launch: { [unowned self] profile in
                    launches += 1; let generation = UUID(); browser = generation
                    let receipt = try #require(engine.store.markLaunchedWithReceipt(profile.id))
                    return (generation, receipt.recorded.revision)
                }, generation: { [unowned self] _ in browser }, saveFailed: { _ in false },
                stop: { [unowned self] id, generation in
                    guard browser == generation else { return }; stops += 1; browser = nil
                    control.observeClosed(profileID: id, generation: generation)
                }), authority: .init(endpointGeneration: endpoint.value.generation, libraryIdentitySHA256: endpoint.value.libraryIdentitySHA256))
            server = MCPGUIControlSocket.Server.forTesting(endpoint: endpoint, handler: { [weak self] request, id, connection in
                guard let self else { return MCPGUIControlProtocol.Reply(request: request, connectionGeneration: request.connectionGeneration, failure: .unavailable) }
                let reply = await control.handle(request, transportID: id, isCurrent: { connection.isCurrent }, authenticate: { connection.authenticate() })
                if request.operation == .status { try? afterStatus?() }
                return reply
            }, disconnected: { [weak self] id in self?.control.revoke(id) })
        }
        func create() throws -> BrowserProfile { try engine.store.upsert(BrowserProfile(name: "Own GUI-MCP integration", startURL: "about:blank", engine: .webkit)) }
        func start(_ profile: BrowserProfile) async throws -> [String: Any] {
            try await engine.call("profile_start", ["profileID": profile.id.uuidString, "expectedRevision": String(profile.revision)])
        }
        func approve(_ profile: BrowserProfile) throws {
            control.approve(try #require(control.clients.first?.id), profiles: [profile.id])
        }
        func cleanup() async {
            bridge.close(); await server.stop(); afterStatus = nil; try? FileManager.default.removeItem(at: root)
        }
    }
    @Test func pendingConsentIntentionalRetryStopAndEOFUseOneConnection() async throws {
        let r = try Rig(); let profile = try r.create()
        await #expect(throws: MCPGUIControlProtocol.Failure.consentRequired) { try await r.start(profile) }
        #expect(r.launches == 0 && r.control.clients.count == 1)
        try r.approve(profile)
        let result = try await r.start(profile)
        #expect(result["processState"] as? String == "managed" && result["revision"] as? String == String(profile.revision + 1))
        let stopped = try await r.engine.call("profile_stop", ["profileID": profile.id.uuidString])
        #expect(stopped["processState"] as? String == "stopped" && stopped["stopRequested"] as? Bool == true)
        #expect(r.launches == 1 && r.stops == 1)
        let current = try #require(r.engine.store.profile(withID: profile.id))
        _ = try await r.start(current)
        r.engine.disconnectGUI()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !r.control.clients.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(r.control.clients.isEmpty && r.browser != nil && r.stops == 1)
        await r.cleanup()
    }
    @Test func observationRefusesRevisionChangedWhileGUIReplyWasPending() async throws {
        let r = try Rig(); let profile = try r.create()
        await #expect(throws: MCPGUIControlProtocol.Failure.consentRequired) { try await r.start(profile) }
        try r.approve(profile); _ = try await r.start(profile)
        _ = try await r.engine.call("profile_stop", ["profileID": profile.id.uuidString])
        let old = try #require(r.engine.store.profile(withID: profile.id))
        r.afterStatus = {
            var changed = try #require(r.engine.store.profile(withID: profile.id)); changed.name = "Own concurrent edit"
            _ = try r.engine.store.upsert(changed)
        }
        await #expect(throws: MCPProfileManagement.Failure.conflict) {
            try await r.engine.call("profile_status", ["profileID": profile.id.uuidString, "includeObservation": true, "expectedRevision": String(old.revision)])
        }
        #expect(r.engine.store.profile(withID: profile.id)?.revision == old.revision + 1)
        await r.cleanup()
    }
    @Test func readOnlyCannotSendGUIStartAndReplacementDescriptorRevokesClient() async throws {
        let r = try Rig(); let profile = try r.create()
        let read = MCPProfileManagement(root: r.root, allowsManagement: false,
            keychain: KeychainStore(backend: MCPProfileManagementTests.Backend(), service: "own-read-gui", legacyService: nil), guiClient: r.bridge)
        await #expect(throws: MCPProfileManagement.Failure.denied) {
            try await read.call("profile_start", ["profileID": profile.id.uuidString, "expectedRevision": String(profile.revision)])
        }
        #expect(r.control.clients.isEmpty && r.launches == 0)
        await #expect(throws: MCPGUIControlProtocol.Failure.consentRequired) { try await r.start(profile) }
        try r.approve(profile)
        let file = r.root.appendingPathComponent(MCPGUIControlEndpoint.descriptorName)
        try FileManager.default.moveItem(at: file, to: r.root.appendingPathComponent("own-held-descriptor"))
        try Data("preserve own replacement".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        await #expect(throws: MCPGUIControlProtocol.Failure.unavailable) { try await r.start(profile) }
        #expect(r.launches == 0)
        r.bridge.close(); await r.server.stop()
        #expect(try String(contentsOf: file, encoding: .utf8) == "preserve own replacement")
        try FileManager.default.removeItem(at: r.root)
    }
}
