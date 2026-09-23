import Testing
@testable import NeAntik

struct FingerprintAuditTriggerPolicyTests {
    @Test(arguments: [
        FingerprintAuditTrigger.ordinaryLaunch,
        .runtimeChanged,
        .recoveryObserved,
        .userRequested,
    ])
    func ordinaryAndUserFacingEventsNeverAutoStart(
        trigger: FingerprintAuditTrigger
    ) {
        #expect(
            !FingerprintAuditTriggerPolicy.shouldAutomaticallyStart(
                trigger: trigger
            )
        )
    }

    @Test
    func onlyExplicitReleaseGateCanAutoStart() {
        #expect(
            FingerprintAuditTriggerPolicy.shouldAutomaticallyStart(
                trigger: .explicitReleaseGate
            )
        )
    }

    @Test
    func runtimeChangeOffersOnlyAfterStableReadyState() {
        #expect(
            FingerprintAuditTriggerPolicy.shouldOfferAfterStabilization(
                trigger: .runtimeChanged,
                runtimeReady: true,
                stoppedProfileCount: 2,
                recoveryRequired: false
            )
        )
        #expect(
            !FingerprintAuditTriggerPolicy.shouldOfferAfterStabilization(
                trigger: .runtimeChanged,
                runtimeReady: false,
                stoppedProfileCount: 2,
                recoveryRequired: false
            )
        )
        #expect(
            !FingerprintAuditTriggerPolicy.shouldOfferAfterStabilization(
                trigger: .recoveryObserved,
                runtimeReady: true,
                stoppedProfileCount: 1,
                recoveryRequired: false
            )
        )
        #expect(
            !FingerprintAuditTriggerPolicy.shouldOfferAfterStabilization(
                trigger: .recoveryObserved,
                runtimeReady: true,
                stoppedProfileCount: 2,
                recoveryRequired: true
            )
        )
    }
}
