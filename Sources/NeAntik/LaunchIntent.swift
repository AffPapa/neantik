import Foundation

struct NeAntikLaunchIntent: Equatable, Sendable {
    static let releaseFingerprintAuditArgument =
        "--neantik-release-fingerprint-audit"

    let opensFingerprintAudit: Bool

    static func parse(arguments: [String]) -> Self {
        Self(
            opensFingerprintAudit: arguments.contains(
                releaseFingerprintAuditArgument
            )
        )
    }
}
