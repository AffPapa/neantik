import Testing
@testable import NeAntik

struct BrowserLaunchActionPresentationTests {
    @Test
    func processStatusToneDoesNotMarkManualOrRecoveryStatesHealthy() {
        #expect(BrowserProfileProcessState.stopped.statusTone == .neutral)
        #expect(BrowserProfileProcessState.checking.statusTone == .activity)
        #expect(BrowserProfileProcessState.managed.statusTone == .healthy)
        #expect(
            BrowserProfileProcessState.externalVerified.statusTone == .healthy
        )
        #expect(
            BrowserProfileProcessState.externalManualOnly.statusTone ==
                .attention
        )
        #expect(
            BrowserProfileProcessState.externalUnverified.statusTone ==
                .attention
        )
        #expect(
            BrowserProfileProcessState.recoveryRequired.statusTone ==
                .attention
        )
    }

    @Test
    func onlyPositivelyIdentifiedProcessesCountAsRunningInTheUI() {
        #expect(!BrowserProfileProcessState.stopped.isConfirmedRunning)
        #expect(!BrowserProfileProcessState.checking.isConfirmedRunning)
        #expect(BrowserProfileProcessState.managed.isConfirmedRunning)
        #expect(BrowserProfileProcessState.externalVerified.isConfirmedRunning)
        #expect(
            BrowserProfileProcessState.externalManualOnly.isConfirmedRunning
        )
        #expect(!BrowserProfileProcessState.externalUnverified.isConfirmedRunning)
        #expect(!BrowserProfileProcessState.recoveryRequired.isConfirmedRunning)
    }

    @Test
    func stoppedProfileCanLaunchAfterRuntimeResolution() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: false,
            runtimeAvailability: .ready
        )

        #expect(presentation.title == "Запустить")
        #expect(presentation.systemImage == "play.fill")
        #expect(presentation.isEnabled)
        #expect(presentation.help == "Запустить профиль")
    }

    @Test
    func runtimeResolutionExplainsWhyStoppedProfileCannotLaunchYet() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: false,
            runtimeAvailability: .resolving
        )

        #expect(presentation.title == "Проверка…")
        #expect(presentation.systemImage == "hourglass")
        #expect(!presentation.isEnabled)
        #expect(presentation.help.contains("проверяет браузерный движок"))
        #expect(presentation.help.contains("после проверки"))
    }

    @Test
    func missingRuntimeKeepsLaunchVisibleButDisabledWithRecoveryHelp() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: false,
            runtimeAvailability: .missing
        )

        #expect(presentation.title == "Запустить")
        #expect(presentation.systemImage == "play.fill")
        #expect(!presentation.isEnabled)
        #expect(
            presentation.help ==
                "Встроенный браузерный движок не найден. " +
                "Переустанови NeAntik из официального DMG или ZIP."
        )
    }

    @Test
    func invalidRuntimeKeepsLaunchVisibleButExplainsSpecificFailure() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: false,
            runtimeAvailability: .invalid(
                message: "Подпись браузерного движка не подтверждена."
            )
        )

        #expect(presentation.title == "Запустить")
        #expect(presentation.systemImage == "play.fill")
        #expect(!presentation.isEnabled)
        #expect(
            presentation.help ==
                "Браузерный движок не готов: " +
                "Подпись браузерного движка не подтверждена."
        )
    }

    @Test
    func emptyInvalidRuntimeMessageStillHasActionableGuidance() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: false,
            runtimeAvailability: .invalid(message: "  \n ")
        )

        #expect(!presentation.isEnabled)
        #expect(
            presentation.help ==
                "Браузерный движок не готов. Переустанови NeAntik " +
                "из официального DMG или ZIP."
        )
    }

    @Test
    func checkingStateIsPendingAndDisabled() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .checking,
            isArchived: false,
            runtimeAvailability: .ready
        )

        #expect(presentation.title == "Подготовка…")
        #expect(presentation.systemImage == "hourglass")
        #expect(!presentation.isEnabled)
        #expect(presentation.help == BrowserProfileProcessState.checking.guidance)
    }

    @Test
    func automaticPreparationHasAnImmediateCancelAction() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .checking,
            isArchived: false,
            runtimeAvailability: .ready,
            isLaunchPreparation: true
        )

        #expect(presentation.title == "Отменить подготовку")
        #expect(presentation.systemImage == "xmark.circle.fill")
        #expect(presentation.isEnabled)
    }

    @Test
    func manualProxyTestIsNotPresentedAsABrowserLaunch() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: false,
            runtimeAvailability: .ready,
            isProxyTesting: true
        )

        #expect(presentation.title == "Проверка прокси…")
        #expect(presentation.systemImage == "hourglass")
        #expect(!presentation.isEnabled)
    }

    @Test
    func managedProfileKeepsSafeStopForEveryRuntimeAvailability() {
        let availabilities: [BrowserRuntimeAvailability] = [
            .resolving,
            .ready,
            .missing,
            .invalid(message: "Движок повреждён."),
        ]

        for availability in availabilities {
            let presentation = BrowserLaunchActionPresentation.resolve(
                processState: .managed,
                isArchived: false,
                runtimeAvailability: availability
            )

            #expect(presentation.title == "Остановить")
            #expect(presentation.systemImage == "stop.fill")
            #expect(presentation.isEnabled)
            #expect(presentation.help == "Остановить профиль")
        }
    }

    @Test
    func safeStopWinsOverStaleArchivedFlagForRunningProfile() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .managed,
            isArchived: true,
            runtimeAvailability: .missing
        )

        #expect(presentation.title == "Остановить")
        #expect(presentation.systemImage == "stop.fill")
        #expect(presentation.isEnabled)
    }

    @Test
    func verifiedExternalProfileCanBeStoppedForEveryRuntimeAvailability() {
        let availabilities: [BrowserRuntimeAvailability] = [
            .resolving,
            .ready,
            .missing,
            .invalid(message: "Движок повреждён."),
        ]

        for availability in availabilities {
            let presentation = BrowserLaunchActionPresentation.resolve(
                processState: .externalVerified,
                isArchived: false,
                runtimeAvailability: availability
            )

            #expect(presentation.title == "Остановить")
            #expect(presentation.systemImage == "stop.fill")
            #expect(presentation.isEnabled)
            #expect(
                presentation.help ==
                    BrowserProfileProcessState.externalVerified.guidance
            )
        }
    }

    @Test
    func manualCloseStatesUseDisabledHandActionAndSpecificGuidance() {
        let states: [BrowserProfileProcessState] = [
            .externalManualOnly,
            .externalUnverified,
            .recoveryRequired,
        ]

        for state in states {
            let presentation = BrowserLaunchActionPresentation.resolve(
                processState: state,
                isArchived: false,
                runtimeAvailability: .missing
            )

            #expect(presentation.title == "Закрыть вручную")
            #expect(presentation.systemImage == "hand.raised.fill")
            #expect(!presentation.isEnabled)
            #expect(presentation.help == state.guidance)
        }
    }

    @Test
    func archivedStoppedProfileCannotLaunch() {
        let presentation = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: true,
            runtimeAvailability: .missing
        )

        #expect(presentation.title == "В архиве")
        #expect(presentation.systemImage == "archivebox")
        #expect(!presentation.isEnabled)
        #expect(presentation.help.contains("Верни профиль из архива"))
    }

    @Test
    func archivedStateTakesPriorityOverEveryRuntimeAvailability() {
        let availabilities: [BrowserRuntimeAvailability] = [
            .resolving,
            .ready,
            .missing,
            .invalid(message: "Движок повреждён."),
        ]

        for availability in availabilities {
            let presentation = BrowserLaunchActionPresentation.resolve(
                processState: .stopped,
                isArchived: true,
                runtimeAvailability: availability
            )

            #expect(presentation.title == "В архиве")
            #expect(presentation.systemImage == "archivebox")
            #expect(!presentation.isEnabled)
        }
    }
}
