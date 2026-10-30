import Foundation

/// Prevents an old child-process exit callback from cleaning up a replacement
/// profile session. Intentional close uses the save/close handshake instead.
enum WebKitHostTerminationPolicy {
    enum Action: Equatable {
        case ignore
        case deferUntilLaunchSettles
        case reconcileUnexpectedExit
    }

    static func action(exitedGeneration: UUID,
                       currentGeneration: UUID?,
                       launchInProgress: Bool,
                       closeInProgress: Bool) -> Action {
        guard currentGeneration == exitedGeneration, !closeInProgress else { return .ignore }
        return launchInProgress ? .deferUntilLaunchSettles : .reconcileUnexpectedExit
    }
}
