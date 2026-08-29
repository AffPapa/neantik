import Foundation

struct NeAntikLaunchIntent: Equatable, Sendable {
    static let releaseFingerprintAuditArgument =
        "--neantik-release-fingerprint-audit"
    static let fingerprintEnrollmentArgument =
        "--neantik-enroll-fingerprint-evidence"
    static let candidateManifestArgument = "--candidate-manifest"
    static let outputArgument = "--output"

    enum Mode: Equatable, Sendable {
        case interactive(
            releaseFingerprintAudit: FingerprintEvidenceReleaseRequest?
        )
        case fingerprintEnrollment(outputURL: URL)
        case invalidControlArguments
    }

    let mode: Mode

    var opensFingerprintAudit: Bool {
        if case let .interactive(releaseFingerprintAudit) = mode {
            return releaseFingerprintAudit != nil
        }
        return false
    }

    var releaseFingerprintAuditRequest:
        FingerprintEvidenceReleaseRequest?
    {
        if case let .interactive(request) = mode {
            return request
        }
        return nil
    }

    static func applicationBundleURL(
        forExecutablePath path: String
    ) -> URL? {
        guard isCanonicalAbsoluteExecutablePath(path) else {
            return nil
        }
        let executableURL = URL(fileURLWithPath: path)
        let bundleURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard bundleURL.pathExtension == "app",
              bundleURL.appendingPathComponent(
                  "Contents/MacOS/NeAntik"
              ).path == path
        else {
            return nil
        }
        return bundleURL
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
        if arguments.count == 6,
           isCanonicalAbsoluteExecutablePath(arguments[0]),
           arguments[1] == releaseFingerprintAuditArgument,
           arguments[2] == candidateManifestArgument,
           isCanonicalAbsoluteFilePath(arguments[3]),
           arguments[4] == outputArgument,
           isCanonicalAbsoluteFilePath(arguments[5]),
           arguments[3] != arguments[5]
        {
            return Self(
                mode: .interactive(
                    releaseFingerprintAudit:
                        FingerprintEvidenceReleaseRequest(
                            candidateManifestURL: URL(
                                fileURLWithPath: arguments[3]
                            ),
                            evidenceOutputURL: URL(
                                fileURLWithPath: arguments[5]
                            )
                        )
                )
            )
        }
        if arguments.contains(where: {
            $0 == outputArgument ||
                $0 == candidateManifestArgument ||
                $0.hasPrefix(fingerprintEnrollmentArgument) ||
                $0.hasPrefix(releaseFingerprintAuditArgument)
        }) {
            return Self(mode: .invalidControlArguments)
        }
        return Self(
            mode: .interactive(releaseFingerprintAudit: nil)
        )
    }

    private static func isCanonicalAbsoluteOutputPath(
        _ path: String
    ) -> Bool {
        isCanonicalAbsoluteFilePath(path)
    }

    private static func isCanonicalAbsoluteFilePath(
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
