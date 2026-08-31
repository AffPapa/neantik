import Testing

@testable import NeAntik

struct ProfileEditorProcessPolicyTests {
    @Test func stableStoppedAndStableConfirmedRunningStatesCanSave() throws {
        try ProfileEditorProcessPolicy.validateSave(
            openedState: .stopped,
            currentState: .stopped
        )
        for current in [
            BrowserProfileProcessState.managed,
            .closing,
            .forceStopAvailable,
            .externalVerified,
            .externalManualOnly,
        ] {
            try ProfileEditorProcessPolicy.validateSave(
                openedState: .managed,
                currentState: current
            )
        }
    }

    @Test func stateChangesAndUncertainStatesFailClosed() {
        let transitions: [(
            BrowserProfileProcessState,
            BrowserProfileProcessState
        )] = [
            (BrowserProfileProcessState.stopped, .managed),
            (.managed, .stopped),
            (.stopped, .checking),
            (.managed, .externalUnverified),
            (.managed, .recoveryRequired),
        ]
        for (opened, current) in transitions {
            #expect(throws: ProfileEditorProcessStateChanged.self) {
                try ProfileEditorProcessPolicy.validateSave(
                    openedState: opened,
                    currentState: current
                )
            }
        }
    }
}
