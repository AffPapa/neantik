import Foundation
import Testing
@testable import NeAntik

struct LaunchIntentTests {
    @Test
    func regularLaunchDoesNotOpenReleaseAudit() {
        let intent = NeAntikLaunchIntent.parse(
            arguments: ["/Applications/NeAntik.app/Contents/MacOS/NeAntik"]
        )

        #expect(!intent.opensFingerprintAudit)
    }

    @Test
    func mcpStdioRequiresExactFlagAndExplicitCanonicalRoot() {
        let executable = "/Applications/NeAntik.app/Contents/MacOS/NeAntik"
        let root = "/private/tmp/neantik-mcp-fixture"
        #expect(NeAntikLaunchIntent.parse(arguments: [
            executable, "--neantik-mcp-stdio", "--data-root", root
        ]).mode == .mcpStdio(dataRoot: URL(fileURLWithPath: root, isDirectory: true)))
        let devExecutable = FileManager.default.currentDirectoryPath +
            "/.build/neantik-local/NeAntik-Dev.app/Contents/MacOS/NeAntik"
        #expect(NeAntikLaunchIntent.parse(arguments: [
            devExecutable, "--neantik-mcp-stdio", "--data-root", root
        ]).mode == .mcpStdio(dataRoot: URL(fileURLWithPath: root, isDirectory: true)))
        for arguments in [
            [executable, "--neantik-mcp-stdio"],
            [executable, "--neantik-mcp-stdio", "--data-root", "relative"],
            [executable, "--neantik-mcp-stdio", "--data-root", "/private/tmp/../unsafe"],
            [executable, "--neantik-mcp-stdio=true"]
        ] {
            #expect(NeAntikLaunchIntent.parse(arguments: arguments).mode == .invalidControlArguments)
        }
    }

    @Test
    func releaseArgumentOpensFingerprintAudit() {
        let manifest =
            "/private/tmp/neantik-release/direct-candidate-manifest.json"
        let output =
            "/private/tmp/neantik-release/fingerprint-evidence-schema8.json"
        let intent = NeAntikLaunchIntent.parse(
            arguments: [
                "/Applications/NeAntik.app/Contents/MacOS/NeAntik",
                NeAntikLaunchIntent.releaseFingerprintAuditArgument,
                NeAntikLaunchIntent.candidateManifestArgument,
                manifest,
                NeAntikLaunchIntent.outputArgument,
                output
            ]
        )

        #expect(intent.opensFingerprintAudit)
        #expect(
            intent.releaseFingerprintAuditRequest ==
                FingerprintEvidenceReleaseRequest(
                    candidateManifestURL: URL(
                        fileURLWithPath: manifest
                    ),
                    evidenceOutputURL: URL(
                        fileURLWithPath: output
                    )
                )
        )
    }

    @Test
    func releaseExecutableResolvesItsOwningApplicationBundle() {
        let executable =
            "/Applications/NeAntik.app/Contents/MacOS/NeAntik"

        #expect(
            NeAntikLaunchIntent.applicationBundleURL(
                forExecutablePath: executable
            )?.path == "/Applications/NeAntik.app"
        )
        #expect(
            NeAntikLaunchIntent.applicationBundleURL(
                forExecutablePath:
                    "/Applications/NeAntik.app/Contents/MacOS/Other"
            ) == nil
        )
        #expect(
            NeAntikLaunchIntent.applicationBundleURL(
                forExecutablePath:
                    "relative/NeAntik.app/Contents/MacOS/NeAntik"
            ) == nil
        )
    }

    @Test
    func similarReservedArgumentFailsClosed() {
        let intent = NeAntikLaunchIntent.parse(
            arguments: [
                "/Applications/NeAntik",
                "--neantik-release-fingerprint-audit=true"
            ]
        )

        #expect(!intent.opensFingerprintAudit)
        #expect(intent.mode == .invalidControlArguments)
    }

    @Test
    func exactEnrollmentUsesOnlyCanonicalAbsoluteOutput() {
        let output = "/private/tmp/neantik-enrollment/binding.json"
        let intent = NeAntikLaunchIntent.parse(
            arguments: [
                "/Applications/NeAntik.app/Contents/MacOS/NeAntik",
                NeAntikLaunchIntent.fingerprintEnrollmentArgument,
                NeAntikLaunchIntent.outputArgument,
                output
            ]
        )

        #expect(
            intent.mode == .fingerprintEnrollment(
                outputURL: URL(fileURLWithPath: output)
            )
        )
        #expect(!intent.opensFingerprintAudit)
    }

    @Test
    func malformedEnrollmentArgumentsFailClosed() {
        let executable =
            "/Applications/NeAntik.app/Contents/MacOS/NeAntik"
        let enrollment =
            NeAntikLaunchIntent.fingerprintEnrollmentArgument
        let output = NeAntikLaunchIntent.outputArgument
        let invalidArguments = [
            [executable, enrollment],
            [executable, enrollment, output],
            [executable, enrollment, output, "relative.json"],
            [executable, enrollment, output, "/private/tmp/../binding.json"],
            [executable, enrollment, output, "/private/tmp/binding.json", "x"],
            ["unexpected", enrollment, output, "/private/tmp/a"],
            [executable, "unexpected", enrollment, output, "/private/tmp/a"],
            [executable, enrollment, enrollment, output, "/private/tmp/a"],
            [executable, output, "/private/tmp/a"],
            [
                executable,
                "--neantik-enroll-fingerprint-evidence=/private/tmp/a"
            ],
            [
                executable,
                enrollment,
                output,
                "/private/tmp/a",
                NeAntikLaunchIntent.releaseFingerprintAuditArgument
            ],
            [
                executable,
                NeAntikLaunchIntent.releaseFingerprintAuditArgument
            ],
            [
                executable,
                NeAntikLaunchIntent.releaseFingerprintAuditArgument,
                NeAntikLaunchIntent.candidateManifestArgument,
                "relative.json",
                NeAntikLaunchIntent.outputArgument,
                "/private/tmp/evidence.json"
            ],
            [
                executable,
                NeAntikLaunchIntent.releaseFingerprintAuditArgument,
                NeAntikLaunchIntent.candidateManifestArgument,
                "/private/tmp/manifest.json",
                NeAntikLaunchIntent.outputArgument,
                "/private/tmp/manifest.json"
            ]
        ]

        for arguments in invalidArguments {
            let intent = NeAntikLaunchIntent.parse(arguments: arguments)
            #expect(intent.mode == .invalidControlArguments)
            #expect(!intent.opensFingerprintAudit)
        }
    }

    @Test
    func duplicateReleaseControlArgumentFailsClosed() {
        let release =
            NeAntikLaunchIntent.releaseFingerprintAuditArgument
        let intent = NeAntikLaunchIntent.parse(
            arguments: ["/Applications/NeAntik", release, release]
        )

        #expect(intent.mode == .invalidControlArguments)
    }
}
