import Foundation

/// Trusted internal destinations; profile URL input still accepts only the
/// existing public-page schemes. Opening extensions never edits Preferences.
enum BrowserUserLaunchTarget: Equatable, Sendable {
    case profileStart
    case extensions

    var startURLOverride: URL? {
        switch self {
        case .profileStart: nil
        case .extensions: URL(string: "chrome://extensions/")
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
