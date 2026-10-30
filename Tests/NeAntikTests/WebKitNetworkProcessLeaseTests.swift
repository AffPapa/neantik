import Foundation
import Testing
@testable import NeAntik

struct WebKitNetworkProcessLeaseTests {
    private func session() -> WebKitHostIPC.Session {
        .init(profileID: UUID(uuidString: "2fd91f78-8cd1-451e-8d6c-1b9b36f1b301")!,
              revision: 11,
              generation: UUID(uuidString: "1315f44b-7921-4d9d-894c-4ec61fb60b5f")!,
              dataRoot: "/tmp/neantik-webkit-lease-qa",
              runtimeSHA256: String(repeating: "b", count: 64))
    }

    private func scope(_ value: WebKitHostIPC.Session) -> WebKitRelayAuthority.Scope {
        .init(profileID: value.profileID, storeID: value.profileID,
              sessionID: value.generation, revision: value.revision)
    }

    @Test func leaseBindsExactProfileStoreSessionAndRevision() {
        let value = session()
        let lease = WebKitNetworkProcessCodeIdentity.Lease.fixture(
            session: value, isCurrent: { true })
        #expect(lease.authorizes(scope(value)))
        #expect(!lease.authorizes(.init(profileID: UUID(), storeID: value.profileID,
                                        sessionID: value.generation, revision: value.revision)))
        #expect(!lease.authorizes(.init(profileID: value.profileID, storeID: UUID(),
                                        sessionID: value.generation, revision: value.revision)))
        #expect(!lease.authorizes(.init(profileID: value.profileID, storeID: value.profileID,
                                        sessionID: UUID(), revision: value.revision)))
        #expect(!lease.authorizes(.init(profileID: value.profileID, storeID: value.profileID,
                                        sessionID: value.generation, revision: value.revision + 1)))
    }

    @Test func expiredProcessAttestationRefusesBrokerAuthority() {
        let value = session()
        let lease = WebKitNetworkProcessCodeIdentity.Lease.fixture(
            session: value, isCurrent: { false })
        #expect(!lease.authorizes(scope(value)))
    }

    @Test func brokerLeaseSweepSelectsOnlyExpiredProcessSessions() {
        let active = session()
        let expired = WebKitHostIPC.Session(
            profileID: UUID(uuidString: "501c98c5-0a39-494b-9e7b-765262df4b8f")!,
            revision: 4,
            generation: UUID(uuidString: "fa565c36-9f5e-4961-9b52-f49c9fd1479f")!,
            dataRoot: "/tmp/neantik-webkit-expired-lease",
            runtimeSHA256: String(repeating: "c", count: 64))
        let activeLease = WebKitNetworkProcessCodeIdentity.Lease.fixture(
            session: active, isCurrent: { true })
        let expiredLease = WebKitNetworkProcessCodeIdentity.Lease.fixture(
            session: expired, isCurrent: { false })

        #expect(WebKitLoopbackBroker.expiredLeaseScopes([activeLease, expiredLease]) == [scope(expired)])
    }
}
