import AppKit

@MainActor
final class NeAntikApplicationDelegate: NSObject, NSApplicationDelegate {
    private static let ordinaryStopTimeoutNanoseconds: UInt64 =
        10_000_000_000

    private weak var processes: BrowserProcessManager?
    private var terminationTask: Task<Void, Never>?
    private var isWaitingForTerminationReply = false

    func configure(processes: BrowserProcessManager) {
        self.processes = processes
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isWaitingForTerminationReply else {
            return .terminateLater
        }
        guard let processes else {
            return .terminateNow
        }
        let snapshot = processes.managerTerminationSnapshot()
        let choice = snapshot.requiresDecision
            ? requestChoice(snapshot: snapshot)
            : nil
        switch BrowserManagerTerminationFlow.initialAction(
            snapshot: snapshot,
            choice: choice
        ) {
        case .terminateNow:
            processes.markManagerShutdownClean()
            return .terminateNow
        case .cancel:
            return .terminateCancel
        case .requestOrdinaryStops:
            processes.requestOrdinaryStopsForManagerTermination()
            isWaitingForTerminationReply = true
            terminationTask = Task { @MainActor [weak self, weak processes] in
                guard let self, let processes else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                let completed = await processes.waitForManagedBrowsersToExit(
                    timeoutNanoseconds:
                        Self.ordinaryStopTimeoutNanoseconds
                )
                isWaitingForTerminationReply = false
                terminationTask = nil
                let completion = BrowserManagerTerminationFlow
                    .completionAction(ordinaryStopsCompleted: completed)
                if completion.markShutdownClean {
                    processes.markManagerShutdownClean()
                }
                sender.reply(
                    toApplicationShouldTerminate: completion.shouldTerminate
                )
                if completion.presentTimeout {
                    presentOrdinaryStopTimeout()
                }
            }
            return .terminateLater
        }
    }

    private func requestChoice(
        snapshot: BrowserManagerTerminationSnapshot
    ) -> BrowserManagerTerminationChoice {
        let presentation = BrowserManagerTerminationPresentation.resolve(
            snapshot: snapshot
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(
            withTitle: presentation.stopOrdinarilyButtonTitle
        )
        alert.addButton(
            withTitle: presentation.leaveRunningButtonTitle
        )
        let cancelButton = alert.addButton(
            withTitle: presentation.cancelButtonTitle
        )
        cancelButton.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .stopOrdinarily
        case .alertSecondButtonReturn:
            return .leaveBrowsersRunning
        default:
            return .cancel
        }
    }

    private func presentOrdinaryStopTimeout() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Не все браузеры завершились"
        alert.informativeText =
            "NeAntik отменил выход и не выполнял принудительную остановку. " +
            "Закрой оставшиеся окна вручную или используй отдельное действие " +
            "принудительной остановки после проверки сессии."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
