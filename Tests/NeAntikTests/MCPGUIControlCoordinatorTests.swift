import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct MCPGUIControlCoordinatorTests {
    typealias Wire = MCPGUIControlProtocol
    @MainActor final class Fixture {
        var profile = BrowserProfile(name: "Own MCP window", startURL: "about:blank", engine: .webkit)
        var current: UUID?
        var launches = 0
        var stops = 0
        var saveFailed = false
        var onRefresh: (() -> Void)?
        var onStop: (() -> Void)?
        lazy var control = MCPGUIControlCoordinator(root: URL(fileURLWithPath: "/private/tmp/unused-own-mcp-fixture"), backend: .init(
            refresh: { [self] in await Task.yield(); onRefresh?() },
            profile: { [self] id in id == profile.id ? profile : nil },
            launch: { [self] _ in launches += 1; let id = UUID(); current = id; return (id, profile.revision + 1) },
            generation: { [self] _ in current }, saveFailed: { [self] _ in saveFailed },
            stop: { [self] _, generation in if current == generation { stops += 1; onStop?() } }),
            authority: .init(endpointGeneration: endpoint, libraryIdentitySHA256: hash))
        let endpoint = UUID(), transport = UUID()
        let hash = String(repeating: "a", count: 64)
        var generation: UUID?
        func request(_ operation: Wire.Command, sequence: UInt64, revision: UInt64? = nil, profileID: UUID? = nil) -> Wire.Request {
            Wire.Request(endpointGeneration: endpoint, libraryIdentitySHA256: hash, connectionGeneration: operation == .connect ? nil : generation,
                sequence: sequence, operation: operation, profileID: operation == .connect ? nil : (profileID ?? profile.id), expectedRevision: revision)
        }
        func connect(approve: Bool = true) async throws {
            let reply = await control.handle(request(.connect, sequence: 1), transportID: transport, isCurrent: { true }, authenticate: { true })
            #expect(reply.state == .pendingConsent)
            generation = try #require(reply.connectionGeneration)
            if approve { control.approve(transport, profiles: [profile.id]) }
        }
        func handle(_ operation: Wire.Command, sequence: UInt64, revision: UInt64? = nil) async -> Wire.Reply {
            await control.handle(request(operation, sequence: sequence, revision: revision), transportID: transport,
                isCurrent: { true }, authenticate: { true })
        }
    }
    @Test func consentRevisionAndSelectedProfileFenceRealDispatch() async throws {
        let f = Fixture(); try await f.connect(approve: false)
        #expect(await f.handle(.start, sequence: 2, revision: 0).failure == .consentRequired)
        #expect(f.launches == 0)
        f.control.approve(f.transport, profiles: [f.profile.id])
        #expect(await f.handle(.start, sequence: 3, revision: 91).failure == .revisionConflict)
        let outside = await f.control.handle(f.request(.start, sequence: 4, revision: 0, profileID: UUID()), transportID: f.transport,
            isCurrent: { true }, authenticate: { true })
        #expect(outside.failure == .denied && f.launches == 0)
        let launched = await f.handle(.start, sequence: 5, revision: f.profile.revision)
        #expect(launched.state == .managed && f.launches == 1)
        #expect(await f.handle(.start, sequence: 6, revision: f.profile.revision).failure == .busy)
        #expect(f.launches == 1)
    }
    @Test func revocationAndMetadataChangeDuringAwaitPreventLaunch() async throws {
        let revoked = Fixture(); try await revoked.connect()
        revoked.onRefresh = { revoked.control.revoke(revoked.transport) }
        #expect(await revoked.handle(.start, sequence: 2, revision: revoked.profile.revision).failure == .staleSession)
        #expect(revoked.launches == 0 && revoked.stops == 0)
        let changed = Fixture(); try await changed.connect()
        let old = changed.profile.revision
        changed.onRefresh = { changed.profile.revision += 1 }
        #expect(await changed.handle(.start, sequence: 2, revision: old).failure == .revisionConflict)
        #expect(changed.launches == 0)
    }
    @Test func signatureOrEOFRevocationAfterAwaitPreventsSideEffects() async throws {
        for live in [false, true] {
            let f = Fixture(); try await f.connect()
            let reply = await f.control.handle(f.request(.start, sequence: 2, revision: f.profile.revision), transportID: f.transport,
                isCurrent: { live }, authenticate: { false })
            #expect(reply.failure == .unavailable && f.launches == 0 && f.stops == 0)
        }
    }
    @Test func stopDoesNotPretendSaveFailureIsClosedOrTouchReplacement() async throws {
        let f = Fixture(); try await f.connect()
        #expect(await f.handle(.start, sequence: 2, revision: f.profile.revision).state == .managed)
        #expect(await f.handle(.stop, sequence: 3).state == .stopPending)
        #expect(f.stops == 1 && f.current != nil)
        f.saveFailed = true
        #expect(await f.handle(.status, sequence: 4).state == .saveFailed)
        f.current = UUID(); f.saveFailed = false
        #expect(await f.handle(.stop, sequence: 5).failure == .ownershipLost)
        #expect(f.stops == 1)
        f.control.revoke(f.transport)
        #expect(f.current != nil && f.stops == 1)
    }
    @Test func matchingSettledCloseAllowsNewGenerationAndStaleCallbackCannotRetireIt() async throws {
        let f = Fixture(); try await f.connect()
        #expect(await f.handle(.start, sequence: 2, revision: f.profile.revision).state == .managed)
        let first = try #require(f.current)
        f.control.observeClosed(profileID: f.profile.id, generation: first)
        f.current = nil
        #expect(await f.handle(.status, sequence: 3).state == .stopped)
        #expect(await f.handle(.start, sequence: 4, revision: f.profile.revision).state == .managed)
        f.control.observeClosed(profileID: f.profile.id, generation: first)
        #expect(await f.handle(.status, sequence: 5).state == .managed)
        #expect(f.launches == 2)
    }
    @Test func immediateCloseReportsRequestAndTerminationRevokesBeforeSuspension() async throws {
        let f = Fixture(); try await f.connect()
        #expect(await f.handle(.start, sequence: 2, revision: f.profile.revision).state == .managed)
        let generation = try #require(f.current)
        f.onStop = { f.current = nil; f.control.observeClosed(profileID: f.profile.id, generation: generation) }
        let closed = await f.handle(.stop, sequence: 3)
        #expect(closed.state == .stopped && closed.stopRequested == true && f.stops == 1)
        let already = await f.handle(.stop, sequence: 4)
        #expect(already.state == .stopped && already.stopRequested == false && f.stops == 1)
        f.onRefresh = { f.control.beginTermination() }
        #expect(await f.handle(.start, sequence: 5, revision: f.profile.revision).failure == .unavailable)
        await f.control.enable() // Cannot reopen the endpoint in the quit gap.
        #expect(!f.control.isEnabled && f.control.clients.isEmpty && f.launches == 1)
        await f.control.finishTermination()
        f.control.cancelTermination()
        #expect(!f.control.isEnabled && f.control.clients.isEmpty)
    }
}
