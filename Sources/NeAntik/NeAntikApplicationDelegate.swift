import AppKit

@MainActor
final class NeAntikApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var processes: BrowserProcessManager?
    private var quitPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let processes = Self.processes, processes.hasOpenWebKitProfiles else { return .terminateNow }
        guard !quitPending else { return .terminateLater }
        quitPending = true
        Task { [self, processes] in
            let drained = await processes.drainWebKitForQuit()
            quitPending = false
            sender.reply(toApplicationShouldTerminate: drained)
            if !drained {
                let alert = NSAlert()
                alert.messageText = processes.hasFailedWebKitSessionSave ? "Вкладки не удалось сохранить" : "Браузер ещё завершается"
                alert.informativeText = processes.hasFailedWebKitSessionSave
                    ? "Выход отложен: NeAntik не смог подтвердить сохранение списка вкладок. Проверь свободное место и доступ к папке данных, затем попробуй выйти снова."
                    : "Выход отложен: WebKit ещё сохраняет вкладки или отменяет загрузку. Подожди немного и попробуй закрыть NeAntik снова."
                alert.addButton(withTitle: "Понятно")
                alert.runModal()
            }
        }
        return .terminateLater
    }
}
