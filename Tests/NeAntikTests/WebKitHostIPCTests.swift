import Foundation
import Darwin
import Testing
@testable import NeAntik

struct WebKitHostIPCTests {
    private enum ActivationFailure: Error, Equatable { case refused }

    private func session(revision: UInt64 = 7) -> WebKitHostIPC.Session {
        .init(profileID: UUID(uuidString: "7b3c6190-8d1b-4fc4-8e69-67467dafc6bd")!,
              revision: revision,
              generation: UUID(uuidString: "2f2e253b-299a-4d12-a942-1347329f3a5a")!,
              dataRoot: "/tmp/neantik-webkit-host-qa",
              runtimeSHA256: String(repeating: "a", count: 64))
    }

    private func runningGate(for value: WebKitHostIPC.Session) throws -> WebKitHostCloseGate {
        var gate = WebKitHostCloseGate(expected: value)
        try gate.accept(.bootstrapAccepted(value))
        let owner = WebKitHostIPC.NetworkProcessOwner(pid: 42_137,
            startedAtSeconds: 1_700_000_000, startedAtMicroseconds: 123_456,
            userID: 501, parentPID: 1)
        let scope = WebKitRelayAuthority.Scope(profileID: value.profileID,
            storeID: value.profileID, sessionID: value.generation,
            revision: value.revision)
        let authority = WebKitRelayAuthority()
        try authority.register(scope: scope, route: .direct)
        let capability = try authority.issue(for: scope)
        _ = try gate.issueRelayCapability(capability)
        _ = try gate.acceptNetworkProcessOwner(.networkProcessOwner(value, owner))
        let routeActive = try gate.activateRoute(scope: scope) { activatedScope in
            #expect(activatedScope == scope)
        }
        #expect(routeActive == .routeActive(value))
        try gate.accept(.ready(value))
        return gate
    }

    @Test func framesRoundTripAndAreBoundedNewlineRecords() throws {
        let value = session()
        let owner = WebKitHostIPC.NetworkProcessOwner(
            pid: 42_137, startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 123_456, userID: 501, parentPID: 1)
        let frames: [WebKitHostIPC.Frame] = [
            .bootstrap(value), .bootstrapAccepted(value), .routeActive(value), .ready(value), .networkProcessOwner(value, owner), .close(value), .saved(value),
            .saveFailed(value, reason: .writeFailed), .closed(value)
        ]
        for frame in frames {
            let bytes = try WebKitHostIPC.encode(frame)
            #expect(bytes.count <= WebKitHostIPC.maximumFrameBytes)
            #expect(bytes.last == 0x0A)
            #expect(try WebKitHostIPC.decode(bytes) == frame)
        }
        #expect(throws: WebKitHostIPC.ProtocolError.malformedFrame) {
            try WebKitHostIPC.decode(Data(#"{"v":"1"}"#.utf8))
        }
        #expect(throws: WebKitHostIPC.ProtocolError.oversizedFrame) {
            try WebKitHostIPC.decode(Data(repeating: 0x20, count: WebKitHostIPC.maximumFrameBytes + 1))
        }
    }

    @Test func ownerFrameAcceptsLaunchdParentAndRejectsInvalidSnapshot() throws {
        let value = session()
        let owner = WebKitHostIPC.NetworkProcessOwner(
            pid: 42_137, startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 123_456, userID: 501, parentPID: 1)
        let bytes = try WebKitHostIPC.encode(.networkProcessOwner(value, owner))
        #expect(try WebKitHostIPC.decode(bytes) == .networkProcessOwner(value, owner))

        #expect(throws: WebKitHostIPC.ProtocolError.invalidProcessOwner) {
            try WebKitHostIPC.encode(.networkProcessOwner(value, .init(
                pid: 1, startedAtSeconds: 1_700_000_000,
                startedAtMicroseconds: 0, userID: 501, parentPID: 1)))
        }

        var object = try #require(JSONSerialization.jsonObject(
            with: Data(bytes.dropLast())) as? [String: String])
        object["networkProcessObservedPPID"] = "0"
        var invalid = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        invalid.append(0x0A)
        #expect(throws: WebKitHostIPC.ProtocolError.invalidProcessOwner) {
            try WebKitHostIPC.decode(invalid)
        }
    }

    @Test func ownerReportPreservesResolverSnapshotFields() {
        let snapshot = WebKitOwnedNetworkProcessPID.Owner(
            pid: 42_137, startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 123_456, userID: 501, parentPID: 1)
        #expect(WebKitHostIPC.NetworkProcessOwner(snapshot) == .init(
            pid: 42_137, startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 123_456, userID: 501, parentPID: 1))
    }

    @Test func capabilityAndOwnerDoNotPermitReadyBeforeBrokerActivation() throws {
        let expected = session()
        let owner = WebKitHostIPC.NetworkProcessOwner(
            pid: 42_137, startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 123_456, userID: 501, parentPID: 1)
        let frame = WebKitHostIPC.Frame.networkProcessOwner(expected, owner)
        var gate = WebKitHostCloseGate(expected: expected)
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.accept(.ready(expected))
        }
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.acceptNetworkProcessOwner(.networkProcessOwner(
                session(revision: expected.revision + 1), owner))
        }

        let scope = WebKitRelayAuthority.Scope(profileID: expected.profileID,
            storeID: expected.profileID, sessionID: expected.generation,
            revision: expected.revision)
        let authority = WebKitRelayAuthority()
        try authority.register(scope: scope, route: .direct)
        let capability = try authority.issue(for: scope)
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.issueRelayCapability(capability)
        }
        #expect(gate.state == .awaitingBootstrapAcceptance)
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.accept(.bootstrapAccepted(session(revision: expected.revision + 1)))
        }
        #expect(gate.state == .awaitingBootstrapAcceptance)
        try gate.accept(.bootstrapAccepted(expected))
        let capabilityFrame = try gate.issueRelayCapability(capability)
        #expect(capabilityFrame == .relayCapability(expected,
            try WebKitHostIPC.RelayCredential(session: expected, capability: capability)))
        #expect(gate.state == .awaitingNetworkProcessOwner)
        #expect(try gate.acceptNetworkProcessOwner(frame) == owner)
        #expect(gate.state == .awaitingRouteActivation)
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.accept(.ready(expected))
        }
        #expect(gate.state == .awaitingRouteActivation)
    }

    @Test func relayFrameCannotRebindCredentialToAnotherSession() throws {
        let expected = session()
        let scope = WebKitRelayAuthority.Scope(profileID: expected.profileID,
            storeID: expected.profileID, sessionID: expected.generation,
            revision: expected.revision)
        let authority = WebKitRelayAuthority()
        try authority.register(scope: scope, route: .direct)
        let capability = try authority.issue(for: scope)
        let credential = try WebKitHostIPC.RelayCredential(session: expected,
                                                          capability: capability)

        #expect(throws: WebKitHostIPC.ProtocolError.invalidCapability) {
            try WebKitHostIPC.encode(.relayCapability(session(revision: expected.revision + 1),
                                                       credential))
        }

        var gate = WebKitHostCloseGate(expected: expected)
        let otherProfile = UUID()
        let wrongScope = WebKitRelayAuthority.Scope(profileID: otherProfile, storeID: otherProfile,
            sessionID: UUID(), revision: 9)
        let wrongAuthority = WebKitRelayAuthority()
        try wrongAuthority.register(scope: wrongScope, route: .direct)
        let wrongCapability = try wrongAuthority.issue(for: wrongScope)
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.issueRelayCapability(wrongCapability)
        }
        #expect(gate.state == .awaitingBootstrapAcceptance)

        try gate.accept(.bootstrapAccepted(expected))
        #expect(gate.state == .awaitingRelayCapability)

        _ = try gate.issueRelayCapability(capability)
        let owner = WebKitHostIPC.NetworkProcessOwner(pid: 42_137,
            startedAtSeconds: 1_700_000_000, startedAtMicroseconds: 123_456,
            userID: 501, parentPID: 1)
        _ = try gate.acceptNetworkProcessOwner(.networkProcessOwner(expected, owner))
        #expect(gate.state == .awaitingRouteActivation)
    }

    @Test func closeGateAllowsRetryAfterExplicitSaveFailure() throws {
        let expected = session()
        var gate = try runningGate(for: expected)
        try gate.requestClose()
        try gate.accept(.saveFailed(expected, reason: .writeFailed))
        #expect(gate.state == .failed)

        try gate.requestClose()
        try gate.accept(.saved(expected))
        try gate.accept(.closed(expected))
        #expect(gate.state == .closed)
        try gate.acceptEOF()
    }

    @Test func childCannotBecomeReadyUntilParentActivatesTheExactBrokerLease() throws {
        let expected = session()
        let scope = WebKitRelayAuthority.Scope(profileID: expected.profileID,
            storeID: expected.profileID, sessionID: expected.generation,
            revision: expected.revision)
        let authority = WebKitRelayAuthority()
        try authority.register(scope: scope, route: .direct)
        let capability = try authority.issue(for: scope)
        var parent = WebKitHostCloseGate(expected: expected)
        try parent.accept(.bootstrapAccepted(expected))
        _ = try parent.issueRelayCapability(capability)

        let owner = WebKitHostIPC.NetworkProcessOwner(pid: 42_137,
            startedAtSeconds: 1_700_000_000, startedAtMicroseconds: 123_456,
            userID: 501, parentPID: 1)
        let ownerFrame = WebKitHostIPC.Frame.networkProcessOwner(expected, owner)
        let acceptedOwner = try parent.acceptNetworkProcessOwner(ownerFrame)
        #expect(acceptedOwner == owner)

        var child = WebKitHostChildRouteGate(expected: expected)
        #expect(try child.reportNetworkProcess(owner) == ownerFrame)
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try child.readyFrame()
        }
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try child.acceptRouteActivation(.routeActive(session(revision: expected.revision + 1)))
        }

        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try parent.activateRoute(scope: WebKitRelayAuthority.Scope(
                profileID: expected.profileID, storeID: expected.profileID,
                sessionID: expected.generation, revision: expected.revision + 1)) { _ in }
        }
        var brokerActivated = false
        #expect(throws: ActivationFailure.refused) {
            try parent.activateRoute(scope: scope) { _ in throw ActivationFailure.refused }
        }
        #expect(parent.state == .awaitingRouteActivation)
        let routeActive = try parent.activateRoute(scope: scope) { activatedScope in
            #expect(activatedScope == scope)
            brokerActivated = true
        }
        #expect(brokerActivated)
        #expect(routeActive == .routeActive(expected))
        let navigationPermit = try child.acceptRouteActivation(routeActive)
        #expect(navigationPermit.authorizes(expected))
        #expect(!navigationPermit.authorizes(session(revision: expected.revision + 1)))
        let ready = try child.readyFrame()
        #expect(ready == .ready(expected))
        try parent.accept(ready)
        #expect(parent.state == .running)
    }

    @Test func privatePipeTransportRoundTripsOneValidatedControlRecord() throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(Darwin.pipe(&descriptors) == 0)
        defer {
            if descriptors[0] >= 0 { _ = Darwin.close(descriptors[0]) }
            if descriptors[1] >= 0 { _ = Darwin.close(descriptors[1]) }
        }
        try ProxyRelayPrivatePipe.prepare(descriptors[0], writable: false)
        try ProxyRelayPrivatePipe.prepare(descriptors[1], writable: true)

        let expected = WebKitHostIPC.Frame.bootstrap(session())
        try WebKitHostIPC.write(expected, to: descriptors[1])
        #expect(try WebKitHostIPC.read(from: descriptors[0]) == expected)
    }

    @Test func relayCapabilityIsSessionBoundAndRedacted() throws {
        let value = session()
        let scope = WebKitRelayAuthority.Scope(
            profileID: value.profileID, storeID: value.profileID,
            sessionID: value.generation, revision: value.revision)
        let authority = WebKitRelayAuthority()
        try authority.register(scope: scope, route: .direct)
        let issued = try authority.issue(for: scope)
        let credential = try WebKitHostIPC.RelayCredential(
            session: value, capability: issued)
        let frame = WebKitHostIPC.Frame.relayCapability(value, credential)
        let bytes = try WebKitHostIPC.encode(frame)
        #expect(try WebKitHostIPC.decode(bytes) == frame)

        let (username, password) = issued.withCredentials { ($0, $1) }
        let rendered = String(reflecting: frame)
        #expect(!rendered.contains(username))
        #expect(!rendered.contains(password))

        let wrongScope = WebKitRelayAuthority.Scope(
            profileID: value.profileID, storeID: value.profileID,
            sessionID: UUID(), revision: value.revision)
        let otherAuthority = WebKitRelayAuthority()
        try otherAuthority.register(scope: wrongScope, route: .direct)
        let other = try otherAuthority.issue(for: wrongScope)
        #expect(throws: WebKitHostIPC.ProtocolError.invalidCapability) {
            try WebKitHostIPC.RelayCredential(session: value, capability: other)
        }
        #expect(throws: WebKitHostIPC.ProtocolError.invalidCapability) {
            try WebKitHostIPC.encode(.relayCapability(session(revision: value.revision + 1),
                                                       credential))
        }
    }

    @Test func decoderRejectsUnknownFieldsBadIdentityAndMultipleFrames() throws {
        let bytes = try WebKitHostIPC.encode(.bootstrap(session()))
        var object = try #require(JSONSerialization.jsonObject(with: Data(bytes.dropLast())) as? [String: String])
        object["command"] = "run arbitrary input"
        var extended = try JSONSerialization.data(withJSONObject: object)
        extended.append(0x0A)
        #expect(throws: WebKitHostIPC.ProtocolError.malformedFrame) {
            try WebKitHostIPC.decode(extended)
        }

        let twoFrames = bytes + bytes
        #expect(throws: WebKitHostIPC.ProtocolError.malformedFrame) {
            try WebKitHostIPC.decode(twoFrames)
        }
        object.removeValue(forKey: "command")
        object["runtimeSHA256"] = "not-a-digest"
        var invalid = try JSONSerialization.data(withJSONObject: object)
        invalid.append(0x0A)
        #expect(throws: WebKitHostIPC.ProtocolError.malformedFrame) {
            try WebKitHostIPC.decode(invalid)
        }

        var nonCanonical = try WebKitHostIPC.encode(.bootstrap(session()))
        nonCanonical.insert(0x20, at: nonCanonical.startIndex)
        #expect(throws: WebKitHostIPC.ProtocolError.malformedFrame) {
            try WebKitHostIPC.decode(nonCanonical)
        }
    }

    @Test func closeRequiresExactReadySaveAndClosedSequence() throws {
        let expected = session()
        var gate = try runningGate(for: expected)
        #expect(throws: WebKitHostIPC.ProtocolError.prematureEOF) { try gate.acceptEOF() }
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.accept(.ready(session(revision: expected.revision + 1)))
        }
        try gate.requestClose()
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.accept(.closed(expected))
        }
        try gate.accept(.saved(expected))
        try gate.accept(.closed(expected))
        try gate.acceptEOF()
    }

    @Test func failedSaveAndUnexpectedEOFNeverMeanStopped() throws {
        let expected = session()
        var gate = try runningGate(for: expected)
        try gate.requestClose()
        try gate.accept(.saveFailed(expected, reason: .storageUnavailable))
        #expect(throws: WebKitHostIPC.ProtocolError.prematureEOF) { try gate.acceptEOF() }
        #expect(throws: WebKitHostIPC.ProtocolError.invalidTransition) {
            try gate.accept(.closed(expected))
        }
    }

    @Test func zeroIdentityCannotEnterBootstrap() throws {
        let invalid = WebKitHostIPC.Session(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                                            revision: 1, generation: UUID(),
                                            dataRoot: "/tmp/../private",
                                            runtimeSHA256: String(repeating: "b", count: 64))
        #expect(throws: WebKitHostIPC.ProtocolError.invalidSession) {
            try WebKitHostIPC.encode(.bootstrap(invalid))
        }
    }

    @Test func nonCanonicalDataRootCannotEnterBootstrap() throws {
        let invalid = WebKitHostIPC.Session(
            profileID: UUID(uuidString: "7b3c6190-8d1b-4fc4-8e69-67467dafc6bd")!,
            revision: 1,
            generation: UUID(uuidString: "2f2e253b-299a-4d12-a942-1347329f3a5a")!,
            dataRoot: "/tmp/../private",
            runtimeSHA256: String(repeating: "b", count: 64)
        )
        #expect(throws: WebKitHostIPC.ProtocolError.invalidSession) {
            try WebKitHostIPC.encode(.bootstrap(invalid))
        }
    }
}
