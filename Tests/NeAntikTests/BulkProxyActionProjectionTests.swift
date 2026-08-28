import Foundation
import Testing
@testable import NeAntik

struct BulkProxyActionProjectionTests {
    @Test
    func mixedStatesYieldOnlyStoppedIdleProxyProfilesInVisibleOrder() {
        let eligibleFirst = proxyProfile("First")
        let direct = BrowserProfile(name: "Direct")
        let running = proxyProfile("Running")
        let preparing = proxyProfile("Preparing")
        let testing = proxyProfile("Testing")
        let checking = proxyProfile("Checking")
        let eligibleLast = proxyProfile("Last")
        let states: [UUID: BrowserProfileProcessState] = [
            eligibleFirst.id: .stopped,
            direct.id: .stopped,
            running.id: .managed,
            preparing.id: .stopped,
            testing.id: .stopped,
            checking.id: .checking,
            eligibleLast.id: .stopped,
        ]

        let projection = BulkProxyActionProjection.resolve(
            visibleProfiles: [
                eligibleFirst,
                direct,
                running,
                preparing,
                testing,
                checking,
                eligibleLast,
            ],
            processState: { states[$0] ?? .recoveryRequired },
            isPreparing: { $0 == preparing.id },
            isTesting: { $0 == testing.id }
        )

        #expect(projection.profileIDs == [eligibleFirst.id, eligibleLast.id])
        #expect(projection.count == 2)
        #expect(projection.isVisible)
        #expect(projection.profiles.map(\.id) == projection.profileIDs)
    }

    @Test(arguments: [
        BrowserProfileProcessState.managed,
        .externalVerified,
        .externalManualOnly,
        .externalUnverified,
        .recoveryRequired,
        .checking,
    ])
    func everyNonStoppedStateIsIneligible(
        state: BrowserProfileProcessState
    ) {
        let profile = proxyProfile("Busy")

        let projection = BulkProxyActionProjection.resolve(
            visibleProfiles: [profile],
            processState: { _ in state },
            isPreparing: { _ in false },
            isTesting: { _ in false }
        )

        #expect(!projection.isVisible)
        #expect(projection.count == 0)
        #expect(projection.profileIDs.isEmpty)
    }

    @Test
    func allBusyOrDirectProfilesProduceOneHonestEmptyProjection() {
        let direct = BrowserProfile(name: "Direct")
        let preparing = proxyProfile("Preparing")
        let testing = proxyProfile("Testing")

        let projection = BulkProxyActionProjection.resolve(
            visibleProfiles: [direct, preparing, testing],
            processState: { _ in .stopped },
            isPreparing: { $0 == preparing.id },
            isTesting: { $0 == testing.id }
        )

        #expect(projection.profiles.isEmpty)
        #expect(projection.profileIDs.isEmpty)
        #expect(projection.count == 0)
        #expect(!projection.isVisible)
    }

    private func proxyProfile(_ name: String) -> BrowserProfile {
        BrowserProfile(
            name: name,
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8080,
                username: ""
            )
        )
    }
}
