import Foundation

struct NeAntikLaunchIntent: Equatable, Sendable {
    static let releaseFingerprintAuditArgument =
        "--neantik-release-fingerprint-audit"
    static let fingerprintEnrollmentArgument =
        "--neantik-enroll-fingerprint-evidence"
    static let outputArgument = "--output"

    enum Mode: Equatable, Sendable {
        case interactive(opensFingerprintAudit: Bool)
        case fingerprintEnrollment(outputURL: URL)
        case invalidControlArguments
    }

    let mode: Mode

    var opensFingerprintAudit: Bool {
        if case let .interactive(opensFingerprintAudit) = mode {
            return opensFingerprintAudit
        }
        return false
    }

    static func parse(arguments: [String]) -> Self {
        if arguments.count == 4,
           isCanonicalAbsoluteExecutablePath(arguments[0]),
           arguments[1] == fingerprintEnrollmentArgument,
           arguments[2] == outputArgument
        {
            guard
                  isCanonicalAbsoluteOutputPath(
                      arguments[3]
                  )
            else {
                return Self(mode: .invalidControlArguments)
            }
            return Self(
                mode: .fingerprintEnrollment(
                    outputURL: URL(
                        fileURLWithPath: arguments[3]
                    )
                )
            )
        }
        if arguments.count == 2,
           arguments[1] == releaseFingerprintAuditArgument
        {
            return Self(
                mode: .interactive(opensFingerprintAudit: true)
            )
        }
        if arguments.contains(where: {
            $0 == outputArgument ||
                $0.hasPrefix(fingerprintEnrollmentArgument) ||
                $0.hasPrefix(releaseFingerprintAuditArgument)
        }) {
            return Self(mode: .invalidControlArguments)
        }
        return Self(
            mode: .interactive(opensFingerprintAudit: false)
        )
    }

    private static func isCanonicalAbsoluteOutputPath(
        _ path: String
    ) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              !path.contains("\u{0}")
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first == "",
              components.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              })
        else {
            return false
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func isCanonicalAbsoluteExecutablePath(
        _ path: String
    ) -> Bool {
        path.hasPrefix("/") &&
            path.hasSuffix("/Contents/MacOS/NeAntik") &&
            URL(fileURLWithPath: path).standardizedFileURL.path == path
    }
}
