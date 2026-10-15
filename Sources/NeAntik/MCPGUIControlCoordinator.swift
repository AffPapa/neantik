import Combine
import Foundation

/// The GUI owns consent. An authenticated executable is eligible to ask, not
/// automatically allowed to start or close any profile.
@MainActor
final class MCPGUIControlCoordinator: ObservableObject {
    typealias Wire = MCPGUIControlProtocol
    struct Backend {
        let refresh: () async throws -> Void
        let profile: (UUID) -> BrowserProfile?
        let launch: (BrowserProfile) throws -> (generation: UUID, revision: UInt64)
        let generation: (UUID) -> UUID?
        let saveFailed: (UUID) -> Bool
        let stop: (UUID, UUID) -> Void
    }
    @Published private(set) var isEnabled = false
    @Published private(set) var isChanging = false
    @Published private(set) var clients: [MCPGUIControlAuthority.Client] = []
    @Published private(set) var message: String?
    private let root: URL
    private let backend: Backend
    private var authority: MCPGUIControlAuthority?
    private var server: MCPGUIControlSocket.Server?
    private var terminating = false
    var needsTerminationDrain: Bool { isEnabled || isChanging || server != nil }

    init(store: ProfileStore, processes: BrowserProcessManager) {
        root = store.paths.rootDirectory
        backend = Backend(refresh: { try await store.refreshExternalMetadata(force: true) },
            profile: { store.hasTrustedMetadata ? store.profile(withID: $0) : nil },
            launch: { profile in
                try store.validateLaunchSnapshot(profile)
                let token = try ManagerLaunchAdmission.shared.begin(profileID: profile.id)
                var launched = false
                defer { ManagerLaunchAdmission.shared.finish(token: token, launched: launched) }
                let generation = try processes.launchWebKitProfile(profile)
                guard let receipt = store.markLaunchedWithReceipt(profile.id), receipt.original.revision == profile.revision,
                      (try? ProfileLaunchMetadataTransition.matches(from: profile, to: receipt.recorded)) == true else {
                    if processes.webKitGeneration(profileID: profile.id) == generation { processes.stop(profileID: profile.id) }
                    throw Wire.Failure.unavailable
                }
                launched = true; store.managerLibrary.record(.launch, .succeeded)
                return (generation, receipt.recorded.revision)
            }, generation: { processes.webKitGeneration(profileID: $0) },
            saveFailed: { processes.webKitSaveFailed(profileID: $0) },
            stop: { id, generation in
                if processes.webKitGeneration(profileID: id) == generation { processes.stop(profileID: id) }
            })
        processes.webKitDidClose = { [weak self] id, generation in
            self?.observeClosed(profileID: id, generation: generation)
        }
    }
#if DEBUG
    init(root: URL, backend: Backend, authority: MCPGUIControlAuthority) {
        self.root = root; self.backend = backend; self.authority = authority; isEnabled = true
    }
#endif
    func enable() async {
        guard !isEnabled, !isChanging, !terminating else { return }
        isChanging = true; message = nil
        defer { isChanging = false }
        do {
            try ApplicationInstallLifecycle.requireNewWork()
            let root = root
            let prepared = try await Task.detached(priority: .utility) {
                let code = try MCPGUIControlSocket.currentExecutableCode()
                let library = try MCPGUIControlEndpoint.Library(root: root, exclusive: true)
                return (try MCPGUIControlEndpoint.Listener(library: library, generation: UUID()), code)
            }.value
            guard !terminating, !Task.isCancelled else { prepared.0.cleanup(); throw Wire.Failure.unavailable }
            authority = MCPGUIControlAuthority(endpointGeneration: prepared.0.value.generation,
                libraryIdentitySHA256: prepared.0.value.libraryIdentitySHA256)
            isEnabled = true
            server = MCPGUIControlSocket.Server(endpoint: prepared.0, expectedClientCode: prepared.1,
                handler: { [weak self] request, id, connection in
                    guard let self else { return Wire.Reply(request: request, connectionGeneration: request.connectionGeneration, failure: .unavailable) }
                    return await self.handle(request, transportID: id, isCurrent: { connection.isCurrent },
                        authenticate: { await Task.detached(priority: .utility) { connection.authenticate() }.value })
                }, disconnected: { [weak self] id in self?.disconnect(id) })
            publishClients()
        } catch { message = "Подключение WebKit недоступно. Используй установленную подписанную версию NeAntik и повтори включение." }
    }
    func disable() async {
        guard !isChanging else { return }
        isChanging = true; isEnabled = false; authority?.revokeAll(); publishClients()
        let previous = server; server = nil
        await previous?.stop()
        authority = nil; isChanging = false
        message = "Доступ отключён. Открытые окна остаются под твоим управлением."
    }
    /// Synchronous fence before AppKit's first termination suspension. A
    /// cancelled quit never silently restores old connection grants.
    func beginTermination() {
        terminating = true; isEnabled = false; authority?.revokeAll(); publishClients()
        server?.requestStop()
    }
    func finishTermination() async {
        while isChanging { await Task.yield() }
        await disable()
    }
    func cancelTermination() { terminating = false }
    func approve(_ id: UUID, profiles: Set<UUID>) {
        do {
            guard isEnabled, authority != nil,
                  profiles.allSatisfy({ backend.profile($0)?.engine == .webkit }) else { throw Wire.Failure.denied }
            try authority!.approve(transportID: id, profiles: profiles)
            publishClients(); message = nil
        } catch { message = "Выбери от 1 до 64 профилей WebKit. Подключение должно оставаться открытым." }
    }
    func revoke(_ id: UUID) { disconnect(id); server?.disconnect(id) }
    private func disconnect(_ id: UUID) { authority?.disconnect(id); publishClients() }
    private func publishClients() { clients = authority?.clients.values.sorted { $0.id.uuidString < $1.id.uuidString } ?? [] }
    func observeClosed(profileID: UUID, generation: UUID) {
        _ = authority?.observeClosed(profileID: profileID, browserGeneration: generation)
    }

    /// Revalidate consent and liveness after disk/code checks. No suspension is
    /// allowed between the final fence and canonical launch/stop side effects.
    func handle(_ request: Wire.Request, transportID: UUID,
                isCurrent: () -> Bool, authenticate: () async -> Bool) async -> Wire.Reply {
        defer { publishClients() }
        do {
            guard isEnabled, !terminating, authority != nil, isCurrent(), !Task.isCancelled else { throw Wire.Failure.unavailable }
            if request.operation == .connect {
                let client = try authority!.connect(request, transportID: transportID)
                return Wire.Reply(request: request, connectionGeneration: client.generation, state: .pendingConsent)
            }
            try authority!.authorize(request, transportID: transportID)
            // Stop/status depend on the owned window, not on optional folder
            // metadata or a subsequently deleted profile description.
            if request.operation == .start { try await backend.refresh() }
            guard await authenticate(), isEnabled, !terminating, isCurrent(), !Task.isCancelled, authority != nil else { throw Wire.Failure.unavailable }
            try authority!.requireScope(request, transportID: transportID)
            let id = request.profileID!
            switch request.operation {
            case .connect: throw Wire.Failure.malformed
            case .start:
                guard let profile = backend.profile(id), profile.engine == .webkit,
                      String(profile.revision) == request.expectedRevision else { throw Wire.Failure.revisionConflict }
                guard backend.generation(id) == nil else { throw Wire.Failure.busy }
                // The same request must be able to claim a fresh lifetime
                // before creating one. A still-unsettled prior close refuses.
                try authority!.requireLaunchAvailable(request, transportID: transportID)
                let result = try backend.launch(profile)
                try authority!.recordLaunch(request, transportID: transportID, browserGeneration: result.generation)
                return Wire.Reply(request: request, connectionGeneration: request.connectionGeneration, state: .managed, revision: result.revision)
            case .status, .stop:
                let generation = backend.generation(id)
                if request.operation == .stop, let generation {
                    try authority!.markStopRequested(request, transportID: transportID, currentBrowserGeneration: generation)
                    backend.stop(id, generation)
                }
                let state = try authority!.state(request, transportID: transportID,
                    currentBrowserGeneration: backend.generation(id), saveFailed: backend.saveFailed(id))
                return Wire.Reply(request: request, connectionGeneration: request.connectionGeneration, state: state,
                    stopRequested: request.operation == .stop ? generation != nil : nil)
            }
        } catch {
            return Wire.Reply(request: request, connectionGeneration: authority?.clients[transportID]?.generation ?? request.connectionGeneration,
                failure: (error as? Wire.Failure) ?? .unavailable)
        }
    }
}
