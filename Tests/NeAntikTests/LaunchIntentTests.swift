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
    func releaseArgumentOpensFingerprintAudit() {
        let intent = NeAntikLaunchIntent.parse(
            arguments: [
                "/Applications/NeAntik.app/Contents/MacOS/NeAntik",
                NeAntikLaunchIntent.releaseFingerprintAuditArgument
            ]
        )

        #expect(intent.opensFingerprintAudit)
    }

    @Test
    func similarUntrustedArgumentDoesNotOpenReleaseAudit() {
        let intent = NeAntikLaunchIntent.parse(
            arguments: ["--neantik-release-fingerprint-audit=true"]
        )

        #expect(!intent.opensFingerprintAudit)
    }
}
