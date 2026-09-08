import Testing
@testable import NeAntik

struct ProfileRowPresentationTests {
    @Test
    func runningRowOpensItsWindowWithoutReplacingTheSeparateStopAction() {
        let states: [BrowserProfileProcessState] = [.managed, .externalVerified]
        for state in states {
            let lifecycle = BrowserLaunchActionPresentation.resolve(
                processState: state,
                isArchived: true,
                runtimeAvailability: .missing
            )
            let primary = ProfileRowPrimaryActionPresentation.resolve(
                processState: state,
                launchAction: lifecycle
            )

            #expect(primary.action == .focusWindow)
            #expect(primary.presentation.title == "Открыть окно")
            #expect(primary.presentation.isEnabled)
            #expect(lifecycle.title == "Остановить")
            #expect(lifecycle.isEnabled)
        }
    }

    @Test
    func unconfirmedAndTransitionalRowsRetainLifecycleRestrictions() {
        let states: [BrowserProfileProcessState] = [
            .checking, .closing, .forceStopAvailable,
            .externalManualOnly, .externalUnverified, .recoveryRequired,
        ]
        for state in states {
            let lifecycle = BrowserLaunchActionPresentation.resolve(
                processState: state,
                isArchived: false,
                runtimeAvailability: .ready
            )
            let primary = ProfileRowPrimaryActionPresentation.resolve(
                processState: state,
                launchAction: lifecycle
            )

            #expect(primary.action == .launchControl)
            #expect(primary.presentation == lifecycle)
            #expect(!primary.presentation.isEnabled)
        }
    }

    @Test
    func stoppedRowsKeepRuntimeAndArchiveGuardsAndPreparationCanBeCancelled() {
        let availabilities: [BrowserRuntimeAvailability] = [.ready, .resolving, .missing]
        for availability in availabilities {
            for isArchived in [false, true] {
                let lifecycle = BrowserLaunchActionPresentation.resolve(
                    processState: .stopped,
                    isArchived: isArchived,
                    runtimeAvailability: availability
                )
                let primary = ProfileRowPrimaryActionPresentation.resolve(
                    processState: .stopped,
                    launchAction: lifecycle
                )

                #expect(primary.action == .launchControl)
                #expect(primary.presentation == lifecycle)
            }
        }

        let cancellation = BrowserLaunchActionPresentation.resolve(
            processState: .checking,
            isArchived: false,
            runtimeAvailability: .ready,
            isLaunchPreparation: true
        )
        let primary = ProfileRowPrimaryActionPresentation.resolve(
            processState: .checking,
            launchAction: cancellation
        )
        #expect(primary.action == .launchControl)
        #expect(primary.presentation == cancellation)
        #expect(primary.presentation.isEnabled)
    }
}
