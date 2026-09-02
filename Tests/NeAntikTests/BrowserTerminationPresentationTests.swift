import Foundation
import Testing

@testable import NeAntik

struct BrowserTerminationPresentationTests {
    @Test
    func safeQuitPresentationOffersThreeExplicitPrivacySafeOutcomes() {
        let managed = UUID()
        let stopping = UUID()
        let snapshot = BrowserManagerTerminationSnapshot(
            managedProfileIDs: [managed, stopping],
            ordinaryStopProfileIDs: [managed]
        )
        let presentation = BrowserManagerTerminationPresentation.resolve(
            snapshot: snapshot
        )

        #expect(snapshot.requiresDecision)
        #expect(snapshot.managedCount == 2)
        #expect(snapshot.ordinaryStopCount == 1)
        #expect(snapshot.alreadyStoppingCount == 1)
        #expect(presentation.leaveRunningButtonTitle.contains("Оставить"))
        #expect(presentation.stopOrdinarilyButtonTitle.contains("Остановить"))
        #expect(presentation.cancelButtonTitle == "Отмена")
        #expect(presentation.message.contains("Принудительная"))
        #expect(!presentation.message.contains(managed.uuidString))
        #expect(!presentation.message.contains(stopping.uuidString))
    }

    @Test
    func safeQuitFlowMapsEveryChoiceAndTimeoutWithoutForceStop() {
        let empty = BrowserManagerTerminationSnapshot(
            managedProfileIDs: [],
            ordinaryStopProfileIDs: []
        )
        let active = BrowserManagerTerminationSnapshot(
            managedProfileIDs: [UUID()],
            ordinaryStopProfileIDs: [UUID()]
        )

        #expect(
            BrowserManagerTerminationFlow.initialAction(
                snapshot: empty,
                choice: nil
            ) == .terminateNow
        )
        #expect(
            BrowserManagerTerminationFlow.initialAction(
                snapshot: active,
                choice: .leaveBrowsersRunning
            ) == .terminateNow
        )
        #expect(
            BrowserManagerTerminationFlow.initialAction(
                snapshot: active,
                choice: .stopOrdinarily
            ) == .requestOrdinaryStops
        )
        #expect(
            BrowserManagerTerminationFlow.initialAction(
                snapshot: active,
                choice: .cancel
            ) == .cancel
        )

        let completed = BrowserManagerTerminationFlow.completionAction(
            ordinaryStopsCompleted: true
        )
        #expect(completed.shouldTerminate)
        #expect(completed.markShutdownClean)
        #expect(!completed.presentTimeout)

        let timedOut = BrowserManagerTerminationFlow.completionAction(
            ordinaryStopsCompleted: false
        )
        #expect(!timedOut.shouldTerminate)
        #expect(!timedOut.markShutdownClean)
        #expect(timedOut.presentTimeout)
    }

    @Test
    func exitClassifierDistinguishesAllFourBoundedOutcomes() {
        #expect(
            BrowserExitClassifier.classify(
                startupFailed: false,
                ordinaryStopRequested: true,
                wasForceStopped: false,
                terminationReason: .uncaughtSignal,
                terminationStatus: SIGTERM
            ) == .expectedOrdinaryStop
        )
        #expect(
            BrowserExitClassifier.classify(
                startupFailed: false,
                ordinaryStopRequested: false,
                wasForceStopped: false,
                terminationReason: .exit,
                terminationStatus: EXIT_SUCCESS
            ) == .normalExternalExit
        )
        #expect(
            BrowserExitClassifier.classify(
                startupFailed: false,
                ordinaryStopRequested: false,
                wasForceStopped: false,
                terminationReason: .uncaughtSignal,
                terminationStatus: SIGTERM
            ) == .crashOrSignal
        )
        #expect(
            BrowserExitClassifier.classify(
                startupFailed: true,
                ordinaryStopRequested: false,
                wasForceStopped: false,
                terminationReason: .exit,
                terminationStatus: EXIT_SUCCESS
            ) == .startupFailure
        )
    }

    @Test
    func exitEventEncodingAndPresentationContainNoOperationalDetails()
        throws
    {
        let event = BrowserExitEvent(
            classification: .crashOrSignal,
            occurredAt: Date(timeIntervalSince1970: 123)
        )
        let encoded = try JSONEncoder().encode(event)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        let rendered = [
            event.presentation.title,
            event.presentation.detail,
            event.presentation.systemImage,
        ].joined(separator: " ")

        #expect(Set(object.keys) == ["classification", "occurredAt"])
        for forbidden in [
            "pid", "--", "/Users/", "http", "proxy", "profile",
        ] {
            #expect(!rendered.lowercased().contains(forbidden.lowercased()))
        }
    }
}
