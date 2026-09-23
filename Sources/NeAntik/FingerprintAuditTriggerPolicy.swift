import Foundation

enum FingerprintAuditTrigger: Equatable, Sendable {
    case ordinaryLaunch
    case explicitReleaseGate
    case runtimeChanged
    case recoveryObserved
    case userRequested
}

enum FingerprintAuditTriggerPolicy {
    /// Only an explicit, machine-facing release gate may start A → B → A
    /// without a visible user action. Ordinary launches and runtime/recovery
    /// events must never create browser processes implicitly.
    static func shouldAutomaticallyStart(
        trigger: FingerprintAuditTrigger
    ) -> Bool {
        trigger == .explicitReleaseGate
    }

    /// Runtime/recovery changes can offer a later diagnostic action once the
    /// app is stable, but the offer is deliberately separate from execution.
    static func shouldOfferAfterStabilization(
        trigger: FingerprintAuditTrigger,
        runtimeReady: Bool,
        stoppedProfileCount: Int,
        recoveryRequired: Bool
    ) -> Bool {
        guard runtimeReady,
              stoppedProfileCount >= 2,
              !recoveryRequired
        else {
            return false
        }
        return trigger == .runtimeChanged || trigger == .recoveryObserved
    }
}
