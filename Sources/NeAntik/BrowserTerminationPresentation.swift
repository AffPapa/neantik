import Foundation

enum BrowserManagerTerminationChoice: Equatable, Sendable {
    case leaveBrowsersRunning
    case stopOrdinarily
    case cancel
}

enum BrowserManagerTerminationInitialAction: Equatable, Sendable {
    case terminateNow
    case requestOrdinaryStops
    case cancel
}

enum BrowserManagerTerminationFlow {
    static func initialAction(
        snapshot: BrowserManagerTerminationSnapshot,
        choice: BrowserManagerTerminationChoice?
    ) -> BrowserManagerTerminationInitialAction {
        guard snapshot.requiresDecision else { return .terminateNow }
        switch choice {
        case .leaveBrowsersRunning:
            return .terminateNow
        case .stopOrdinarily:
            return .requestOrdinaryStops
        case .cancel, .none:
            return .cancel
        }
    }

    static func completionAction(
        ordinaryStopsCompleted: Bool
    ) -> BrowserManagerTerminationCompletionAction {
        BrowserManagerTerminationCompletionAction(
            shouldTerminate: ordinaryStopsCompleted,
            markShutdownClean: ordinaryStopsCompleted,
            presentTimeout: !ordinaryStopsCompleted
        )
    }
}

struct BrowserManagerTerminationCompletionAction: Equatable, Sendable {
    let shouldTerminate: Bool
    let markShutdownClean: Bool
    let presentTimeout: Bool
}

struct BrowserManagerTerminationSnapshot: Equatable, Sendable {
    let managedProfileIDs: [UUID]
    let ordinaryStopProfileIDs: [UUID]

    var managedCount: Int { managedProfileIDs.count }
    var ordinaryStopCount: Int { ordinaryStopProfileIDs.count }
    var alreadyStoppingCount: Int {
        managedCount - ordinaryStopCount
    }
    var requiresDecision: Bool { managedCount > 0 }
}

struct BrowserManagerTerminationPresentation: Equatable, Sendable {
    let title: String
    let message: String
    let leaveRunningButtonTitle: String
    let stopOrdinarilyButtonTitle: String
    let cancelButtonTitle: String

    static func resolve(
        snapshot: BrowserManagerTerminationSnapshot
    ) -> Self {
        precondition(snapshot.requiresDecision)
        var message =
            "Сейчас работает браузеров: \(snapshot.managedCount). " +
            "Можно оставить их открытыми и завершить только менеджер " +
            "либо отправить обычную команду завершения и дождаться ответа. " +
            "Принудительная остановка не выполняется."
        if snapshot.alreadyStoppingCount > 0 {
            message +=
                " Уже завершаются или ожидают завершения: " +
                "\(snapshot.alreadyStoppingCount)."
        }
        return Self(
            title: "Выйти из NeAntik?",
            message: message,
            leaveRunningButtonTitle: "Оставить браузеры и выйти",
            stopOrdinarilyButtonTitle: "Остановить и выйти",
            cancelButtonTitle: "Отмена"
        )
    }
}

enum BrowserExitClassification: String, Codable, Equatable, Sendable {
    case expectedOrdinaryStop
    case normalExternalExit
    case crashOrSignal
    case startupFailure
}

/// A single privacy-safe browser lifecycle fact. Deliberately contains no
/// profile identifier, PID, arguments, paths, URLs, proxy data or raw error.
struct BrowserExitEvent: Codable, Equatable, Sendable {
    let classification: BrowserExitClassification
    let occurredAt: Date

    var presentation: BrowserExitPresentation {
        BrowserExitPresentation.resolve(classification: classification)
    }
}

struct BrowserExitPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let systemImage: String

    static func resolve(
        classification: BrowserExitClassification
    ) -> Self {
        switch classification {
        case .expectedOrdinaryStop:
            Self(
                title: "Браузер остановлен",
                detail: "Обычное завершение выполнено без принудительной остановки.",
                systemImage: "checkmark.circle.fill"
            )
        case .normalExternalExit:
            Self(
                title: "Браузер закрыт отдельно",
                detail: "Процесс завершился штатно вне команды остановки NeAntik.",
                systemImage: "rectangle.portrait.and.arrow.right"
            )
        case .crashOrSignal:
            Self(
                title: "Браузер завершился аварийно",
                detail: "Процесс вернул ошибку или был завершён сигналом.",
                systemImage: "exclamationmark.triangle.fill"
            )
        case .startupFailure:
            Self(
                title: "Браузер не запустился",
                detail: "Запуск завершился до готовности браузера.",
                systemImage: "xmark.circle.fill"
            )
        }
    }
}

enum BrowserExitClassifier {
    static func classify(
        startupFailed: Bool,
        ordinaryStopRequested: Bool,
        wasForceStopped: Bool,
        terminationReason: Process.TerminationReason,
        terminationStatus: Int32
    ) -> BrowserExitClassification {
        if startupFailed {
            return .startupFailure
        }
        if wasForceStopped {
            return .crashOrSignal
        }
        // Process.terminate() is the manager's ordinary SIGTERM path, so an
        // uncaught-signal termination is expected when that request is active.
        if ordinaryStopRequested {
            return .expectedOrdinaryStop
        }
        if terminationReason == .uncaughtSignal {
            return .crashOrSignal
        }
        guard terminationStatus == EXIT_SUCCESS else {
            return .crashOrSignal
        }
        return .normalExternalExit
    }
}
