import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayObservationProtocolTests {
    private func binding() -> ProxyRelayObservationProtocol.Binding {
        let identity = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 100, startMicroseconds: 20), userID: geteuid(), parentProcessID: 1)
        return .init(profileID: UUID(), sessionGeneration: UUID(), profileRevision: 4,
                     runtimeExecutableSHA256: String(repeating: "a", count: 64), runtimeFrameworkSHA256: String(repeating: "b", count: 64),
                     configurationSHA256: String(repeating: "c", count: 64), owner: .init(pid: 700, identity: identity), browser: .init(pid: 701, identity: identity))
    }
    private func routeSnapshot() -> BrowserRouteProbe.Snapshot {
        .init(status: .complete, httpResponseAcknowledged: true, httpsResponseAcknowledged: true,
              hostnameDelegationObserved: true, dnsResolution: "notObserved", policySHA256: String(repeating: "e", count: 64),
              expiresAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 60_000_000_000)
    }
    @Test func routeObservationIsExplicitPolicyBoundAndLegacySafe() throws {
        let context = binding(), probe = routeSnapshot(), activity = BrowserRelayActivity().snapshot()
        let request = ProxyRelayObservationProtocol.Request(schema: 2, challenge: UUID(), binding: context)
        let data = try JSONEncoder().encode(ProxyRelayObservationProtocol.Reply(schema: 2, challenge: request.challenge,
            binding: context, activity: activity, routeProbe: probe))
        let result = try ProxyRelayObservationProtocol.readObservation(data, request: request, expectedPolicySHA256: probe.policySHA256)
        #expect(result.activity == activity && result.routeProbe == probe)
        #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readObservation(data, request: request, expectedPolicySHA256: nil) }
        #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readObservation(data, request: request, expectedPolicySHA256: String(repeating: "f", count: 64)) }
        let missing = try JSONEncoder().encode(ProxyRelayObservationProtocol.Reply(schema: 2, challenge: request.challenge, binding: context, activity: activity))
        #expect(try ProxyRelayObservationProtocol.readObservation(missing, request: request, expectedPolicySHA256: nil).routeProbe == nil)
        #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readObservation(missing, request: request, expectedPolicySHA256: probe.policySHA256) }
        let legacy = ProxyRelayObservationProtocol.Request(schema: 1, challenge: request.challenge, binding: context)
        #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readReply(data, request: legacy) }
        let replay = ProxyRelayObservationProtocol.Request(schema: 2, challenge: UUID(), binding: context)
        #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readObservation(data, request: replay, expectedPolicySHA256: probe.policySHA256) }
    }
    @Test func routeReceiptRefusesImpossiblePhasesForeignDNSAndHiddenPayload() throws {
        let context = binding(), probe = routeSnapshot()
        let request = ProxyRelayObservationProtocol.Request(schema: 2, challenge: UUID(), binding: context)
        let bytes = try JSONEncoder().encode(ProxyRelayObservationProtocol.Reply(schema: 2, challenge: request.challenge,
            binding: context, activity: BrowserRelayActivity().snapshot(), routeProbe: probe))
        let original = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let controls: [(String, Any)] = [("status", "waitingHTTPS"), ("status", "waitingHTTP"), ("status", "notStarted"),
            ("httpResponseAcknowledged", false), ("httpsResponseAcknowledged", false), ("dnsResolution", "verified"),
            ("policySHA256", String(repeating: "E", count: 64)), ("expiresAtUptimeNanoseconds", 0),
            ("expiresAtUptimeNanoseconds", UInt64.max), ("endpoint", "https://private.example.test/"),
            ("httpsResponseAcknowledged", 1)]
        for (field, value) in controls {
            var changed = original, fields = try #require(original["routeProbe"] as? [String: Any])
            fields[field] = value; changed["routeProbe"] = fields
            let data = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readObservation(data, request: request, expectedPolicySHA256: probe.policySHA256) }
        }
        var omitted = original; omitted.removeValue(forKey: "routeProbe")
        let data = try JSONSerialization.data(withJSONObject: omitted)
        #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readObservation(data, request: request, expectedPolicySHA256: nil) }
        #expect(try ProxyRelayObservationProtocol.readObservation(bytes, request: request, expectedPolicySHA256: probe.policySHA256).routeProbe?.status == .complete)
    }
    @Test func probeExpiresAcrossIPCAndRemainsPrivateInMCP() throws {
        let probe = routeSnapshot()
        #expect(probe.current(at: probe.expiresAtUptimeNanoseconds - 1).status == .complete)
        let expired = probe.current(at: probe.expiresAtUptimeNanoseconds)
        #expect(expired.status == .expired && expired.httpResponseAcknowledged && expired.httpsResponseAcknowledged)
        try expired.validate(expectedPolicySHA256: probe.policySHA256)
        let dto = BrowserSessionObservation(state: .observed, ownership: .thisSession, readyForGracefulQuit: true,
            runtimeVersion: "156.0.8078.12", configuredRoute: .httpProxy, sampledRouteProbe: probe)
        #expect(dto.mcpValue["chromiumRoute"] as? String == "notObserved")
        #expect(dto.mcpValue["routeProbe"] == nil)
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: dto.mcpValue), as: UTF8.self).contains(probe.policySHA256))
    }
    @Test func exactReplyRequiresChallengeAndAllContextFields() throws {
        let context = binding(), ledger = BrowserRelayActivity()
        let request = ProxyRelayObservationProtocol.Request(schema: 1, challenge: UUID(), binding: context)
        let bytes = try JSONEncoder().encode(ProxyRelayObservationProtocol.Reply(schema: 1, challenge: request.challenge, binding: context, activity: ledger.snapshot()))
        #expect(try ProxyRelayObservationProtocol.readReply(bytes, request: request) == ledger.snapshot())
        let wrongChallenge = ProxyRelayObservationProtocol.Request(schema: 1, challenge: UUID(), binding: context)
        #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readReply(bytes, request: wrongChallenge) }
        let original = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for field in ["profileID", "sessionGeneration", "profileRevision", "runtimeExecutableSHA256", "runtimeFrameworkSHA256", "configurationSHA256", "owner", "browser"] {
            var changed = original, inner = try #require(original["binding"] as? [String: Any])
            if field == "profileRevision" { inner[field] = 5 }
            else if field == "owner" || field == "browser" {
                var process = try #require(inner[field] as? [String: Any]); process["seconds"] = 101; inner[field] = process
            } else if field.hasSuffix("SHA256") { inner[field] = String(repeating: "d", count: 64) }
            else { inner[field] = UUID().uuidString }
            changed["binding"] = inner
            let data = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readReply(data, request: request) }
        }
    }
    @Test func malformedAmbiguousExtraAndOversizedRequestsAreRefused() throws {
        let context = binding(), request = ProxyRelayObservationProtocol.Request(schema: 1, challenge: UUID(), binding: context)
        let bytes = try JSONEncoder().encode(request)
        #expect(try ProxyRelayObservationProtocol.readRequest(bytes, expected: context).challenge == request.challenge)
        var extra = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any]); extra["command"] = "stop"
        let prefix = String(decoding: bytes.dropLast(), as: UTF8.self)
        let bad = [Data((prefix + ",\"schema\":1}").utf8), Data((prefix + ",\"\\u0073chema\":1}").utf8),
                   try JSONSerialization.data(withJSONObject: extra), bytes.dropLast(), Data(repeating: 32, count: 16_385)]
        for data in bad { #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readRequest(data, expected: context) } }
    }
    @Test func invalidScalarCountersCannotBecomeObservedTransport() throws {
        let context = binding(), request = ProxyRelayObservationProtocol.Request(schema: 1, challenge: UUID(), binding: context)
        let bytes = try JSONEncoder().encode(ProxyRelayObservationProtocol.Reply(schema: 1, challenge: request.challenge, binding: context, activity: BrowserRelayActivity().snapshot()))
        let original = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (field, value) in [("schema", 2), ("activeConnections", 65), ("sequence", -1), ("completedConnections", 1), ("successRepliesSent", 1)] {
            var changed = original, scalar = try #require(original["activity"] as? [String: Any]); scalar[field] = value; changed["activity"] = scalar
            let data = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: (any Error).self) { try ProxyRelayObservationProtocol.readReply(data, request: request) }
        }
    }
    @Test func browserReparentingDoesNotChangeGenerationButReuseDoes() {
        let identity = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 100, startMicroseconds: 20), userID: geteuid(), parentProcessID: 500)
        let process = ProxyRelayObservationProtocol.ProcessBinding(pid: 700, identity: identity)
        #expect(process.matches(.init(generation: identity.generation, userID: identity.userID, parentProcessID: 1)))
        let reused = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 101, startMicroseconds: 20), userID: identity.userID, parentProcessID: 1)
        let reusedMatches = process.matches(reused)
        #expect(reusedMatches == false)
        #expect(!process.matches(nil))
    }
    @Test func relayContextRequiresLaunchRevisionAndExactReceiptIdentity() throws {
        let context = binding(), relay = ProxyRelayLeaseReceipt(profileID: context.profileID, sessionGeneration: context.sessionGeneration,
            ownerPID: context.owner.pid, ownerStartSeconds: context.owner.seconds, ownerStartMicroseconds: context.owner.microseconds, ownerUID: context.owner.uid,
            loopbackPort: 1234, runtimeExecutableSHA256: context.runtimeExecutableSHA256, runtimeFrameworkSHA256: context.runtimeFrameworkSHA256, configurationSHA256: context.configurationSHA256)
        let lease = BrowserProcessLock(pid: context.browser.pid, executablePath: "/synthetic/browser", browserDataPath: "/synthetic/data", createdAt: Date(),
            schemaVersion: 3, ownerToken: context.sessionGeneration, managerPID: getpid(), phase: .running, relay: relay)
        let identity = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: context.browser.seconds, startMicroseconds: context.browser.microseconds), userID: context.browser.uid, parentProcessID: 1)
        var receipt = ManagedBrowserSessionReceipt(generation: context.sessionGeneration, lock: lease, runtimeVersion: "156.0.8078.12", configuredRoute: .httpProxy,
            profileRevision: 4, browserIdentity: identity, routePolicySHA256: String(repeating: "e", count: 64))
        #expect(try receipt.relayBinding(profileID: context.profileID, expectedRevision: 4) == context)
        #expect(try receipt.relayBinding(profileID: context.profileID, expectedRevision: 5) == nil)
        #expect(try receipt.relayBinding(profileID: UUID(), expectedRevision: 4) == nil)
        let original = BrowserProfile(id: context.profileID, name: "Bookkeeping", revision: 4)
        var recorded = original; recorded.revision = 5; recorded.lastLaunchedAt = Date(); recorded.updatedAt = Date()
        #expect(try receipt.recordLaunchMetadata(from: original, to: recorded))
        #expect(receipt.routePolicySHA256 == String(repeating: "e", count: 64))
        #expect(try receipt.relayBinding(profileID: context.profileID, expectedRevision: 5) == context)
        #expect(try receipt.relayBinding(profileID: context.profileID, expectedRevision: 4) == nil)
        var changed = recorded; changed.proxy = .init(kind: .http, host: "changed.example.test", port: 8080, username: "")
        #expect(try receipt.recordLaunchMetadata(from: original, to: changed) == false)
        #expect(try receipt.relayBinding(profileID: context.profileID, expectedRevision: 6) == nil)
        receipt.browserIdentity = nil
        #expect(try receipt.relayBinding(profileID: context.profileID, expectedRevision: 4) == nil)
    }
    @Test func discoverySchemaCoversOnlyTheExplicitTransportDTO() throws {
        let schema = MCPOutputSchemas.schema(for: "profile_status")
        let properties = try #require(schema["properties"] as? [String: Any])
        let observation = try #require(properties["observation"] as? [String: Any])
        let fields = try #require(observation["properties"] as? [String: Any])
        let dto = BrowserSessionObservation.unavailable(.notOwned).mcpValue
        #expect(Set(fields.keys) == Set(dto.keys))
        let transport = try #require(fields["relayTransport"] as? [String: Any])
        let cases = try #require(transport["oneOf"] as? [[String: Any]])
        let observed = try #require(cases.first?["properties"] as? [String: Any])
        #expect(Set(observed.keys) == Set(BrowserRelayActivity().snapshot().mcpValue.keys))
        #expect(cases.allSatisfy { $0["additionalProperties"] as? Bool == false })
        #expect(observation["additionalProperties"] as? Bool == false)
    }
    @Test func mcpTransportIsScalarAndKeepsRouteUnmeasured() throws {
        let context = binding(), ledger = BrowserRelayActivity(), ticket = try #require(ledger.begin())
        ledger.established(ticket); ledger.replySent(ticket); ledger.finish(ticket, as: .streamFailed)
        let observation = BrowserSessionObservation(state: .observed, ownership: .thisSession, readyForGracefulQuit: true, runtimeVersion: "156.0.8078.12",
            configuredRoute: .socks5Proxy, sessionGeneration: context.sessionGeneration, relayTransport: ledger.snapshot())
        let value = observation.mcpValue, data = try JSONSerialization.data(withJSONObject: value), text = String(decoding: data, as: UTF8.self)
        #expect(value["chromiumRoute"] as? String == "notObserved")
        let transport = try #require(value["relayTransport"] as? [String: Any])
        #expect(transport["lastFailure"] as? String == "streamFailed")
        for forbidden in [context.sessionGeneration.uuidString, "ownerPID", "browserDataPath", "configurationSHA256", "password", "destination"] { #expect(!text.contains(forbidden)) }
    }
}
