import AppKit

@MainActor
final class NeAntikApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var processes: BrowserProcessManager?
    static weak var mcpGUI: MCPGUIControlCoordinator?
    private var quitPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitPending else { return .terminateLater }
        let gui = Self.mcpGUI
        let hasGUICleanup = gui?.needsTerminationDrain == true
        gui?.beginTermination()
        guard let processes = Self.processes else { return .terminateNow }
        guard processes.hasPendingWebKitWork || processes.hasPendingEphemeralWork || hasGUICleanup else { return .terminateNow }
        quitPending = true
        Task { [self, processes] in
            await gui?.finishTermination()
            let webKitDrained = await processes.drainWebKitForQuit()
            let ephemeralDrained = await processes.drainEphemeralForQuit()
            let drained = webKitDrained && ephemeralDrained
            quitPending = false
            sender.reply(toApplicationShouldTerminate: drained)
            if !drained {
                gui?.cancelTermination()
                let alert = NSAlert()
                alert.messageText = processes.hasFailedWebKitSessionSave ? "Вкладки не удалось сохранить" : "Браузер ещё завершается"
                alert.informativeText = processes.hasFailedWebKitSessionSave
                    ? "Выход отложен: NeAntik не смог подтвердить сохранение списка вкладок. Проверь свободное место и доступ к папке данных, затем попробуй выйти снова."
                    : "Выход отложен: браузер ещё завершает работу или очистка одноразового сеанса не подтверждена. Дождись закрытия его окон и проверь карточку очистки профиля."
                alert.addButton(withTitle: "Понятно")
                alert.runModal()
            }
        }
        return .terminateLater
    }
}
