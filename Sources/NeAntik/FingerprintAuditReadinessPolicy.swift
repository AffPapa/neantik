import Foundation

enum FingerprintAuditReadinessPolicy {
    /// A manual A → B → A audit is available only when every audited profile
    /// is demonstrably stopped. Running IDs alone are insufficient because a
    /// profile may be checking, externally locked, or awaiting recovery.
    static func canOffer(
        runtimeReady: Bool,
        supportsFingerprintIdentity: Bool,
        activeProfileCount: Int,
        profileStates: [BrowserProfileProcessState]
    ) -> Bool {
        guard runtimeReady,
              supportsFingerprintIdentity,
              activeProfileCount >= 2,
              profileStates.count == activeProfileCount
        else {
            return false
        }
        return profileStates.allSatisfy { $0 == .stopped }
    }
}
