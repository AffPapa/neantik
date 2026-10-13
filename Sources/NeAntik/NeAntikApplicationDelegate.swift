import AppKit

@MainActor
final class NeAntikApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var processes: BrowserProcessManager?
    private var quitPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let processes = Self.processes, processes.hasActiveWebKitDownloads else { return .terminateNow }
        guard !quitPending else { return .terminateLater }
        quitPending = true
        Task { [self, processes] in
            let drained = await processes.drainWebKitForQuit()
            quitPending = false
            sender.reply(toApplicationShouldTerminate: drained)
            if !drained {
                let alert = NSAlert()
                alert.messageText = "Загрузки ещё завершаются"
                alert.informativeText = "Выход отложен: WebKit не подтвердил отмену загрузки. Подожди немного и попробуй закрыть NeAntik снова."
                alert.addButton(withTitle: "Понятно")
                alert.runModal()
            }
        }
        return .terminateLater
    }
}
