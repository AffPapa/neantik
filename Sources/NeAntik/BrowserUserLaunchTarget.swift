import Foundation

/// A management launch preserves the saved start page and all network policy.
/// Headed M156 rejects chrome://extensions as a command-line startup URL
/// (startup::ValidateLaunchUrlWebUnsafe). Use a blank page and native navigation;
/// never pretend that passing an internal URL actually opened that page.
enum BrowserUserLaunchTarget: Equatable, Sendable {
    case profileStart
    case extensions
    case routeProbe(BrowserRouteProbe.Plan)

    var startURLOverride: URL? {
        switch self {
        case .profileStart: nil
        case .extensions: URL(string: "about:blank")
        case .routeProbe: nil
        }
    }
    var routeProbePlan: BrowserRouteProbe.Plan? {
        if case let .routeProbe(plan) = self { return plan }; return nil
    }
    /// A diagnostic has no Direct/native-proxy fallback. Resolve its virtual
    /// entry only after the authenticated owner supplies the actual bound port.
    func startURLOverride(relayPort: UInt16) throws -> URL? {
        guard let plan = routeProbePlan else { return startURLOverride }
        try plan.validate()
        guard relayPort > 0 else { throw BrowserRouteProbe.Failure.invalidPlan }
        return URL(string: "http://127.0.0.1:\(relayPort)" + BrowserRouteProbe.Session.entryPath)!
    }

}

struct LaunchPreparationFailure: Identifiable, Equatable {
    let profileID: UUID
    let message: String
    var title: String = "Прокси не готов"
    var offersProxyEdit = true
    var target: BrowserUserLaunchTarget = .profileStart
    var id: UUID { profileID }
}
