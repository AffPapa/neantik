import Testing
@testable import NeAntik

struct FingerprintAuditReadinessPolicyTests {
    @Test
    func offersOnlyForTwoOrMoreStoppedProfilesAndReadyRuntime() {
        #expect(
            FingerprintAuditReadinessPolicy.canOffer(
                runtimeReady: true,
                supportsFingerprintIdentity: true,
                activeProfileCount: 2,
                profileStates: [.stopped, .stopped]
            )
        )
    }

    @Test(arguments: [
        BrowserProfileProcessState.checking,
        .managed,
        .externalVerified,
        .externalManualOnly,
        .externalUnverified,
        .recoveryRequired,
    ])
    func rejectsAnyNonStoppedProfile(
        state: BrowserProfileProcessState
    ) {
        #expect(
            !FingerprintAuditReadinessPolicy.canOffer(
                runtimeReady: true,
                supportsFingerprintIdentity: true,
                activeProfileCount: 2,
                profileStates: [.stopped, state]
            )
        )
    }

    @Test
    func rejectsUnavailableRuntimeOrInsufficientProfiles() {
        #expect(
            !FingerprintAuditReadinessPolicy.canOffer(
                runtimeReady: false,
                supportsFingerprintIdentity: true,
                activeProfileCount: 2,
                profileStates: [.stopped, .stopped]
            )
        )
        #expect(
            !FingerprintAuditReadinessPolicy.canOffer(
                runtimeReady: true,
                supportsFingerprintIdentity: false,
                activeProfileCount: 2,
                profileStates: [.stopped, .stopped]
            )
        )
        #expect(
            !FingerprintAuditReadinessPolicy.canOffer(
                runtimeReady: true,
                supportsFingerprintIdentity: true,
                activeProfileCount: 1,
                profileStates: [.stopped]
            )
        )
    }

    @Test
    func rejectsStateCountMismatchInsteadOfGuessing() {
        #expect(
            !FingerprintAuditReadinessPolicy.canOffer(
                runtimeReady: true,
                supportsFingerprintIdentity: true,
                activeProfileCount: 2,
                profileStates: [.stopped]
            )
        )
    }
}
