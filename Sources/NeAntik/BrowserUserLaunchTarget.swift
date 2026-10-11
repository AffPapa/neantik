import Foundation

/// A management launch preserves the saved start page and all network policy.
/// Headed M156 rejects chrome://extensions as a command-line startup URL
/// (startup::ValidateLaunchUrlWebUnsafe). Use a blank page and native navigation;
/// never pretend that passing an internal URL actually opened that page.
enum BrowserUserLaunchTarget: Equatable, Sendable {
    case profileStart
    case extensions

    var startURLOverride: URL? {
        switch self {
        case .profileStart: nil
        case .extensions: URL(string: "about:blank")
        }
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
