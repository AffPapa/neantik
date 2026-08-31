import Foundation

struct ProfileEditorProcessStateChanged: LocalizedError, Equatable, Sendable {
    var errorDescription: String? {
        "Состояние профиля изменилось, пока редактор был открыт. Закрой окно, проверь статус и открой редактирование снова."
    }
}

enum ProfileEditorProcessPolicy {
    static func validateSave(
        openedState: BrowserProfileProcessState,
        currentState: BrowserProfileProcessState
    ) throws {
        let openedRunning = openedState.isConfirmedRunning
        let currentRunning = currentState.isConfirmedRunning
        guard openedState == .stopped || openedRunning,
              currentState == .stopped || currentRunning,
              openedRunning == currentRunning
        else {
            throw ProfileEditorProcessStateChanged()
        }
    }
}
