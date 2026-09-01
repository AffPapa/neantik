import Foundation
import Testing

@testable import NeAntik

struct BrowserRuntimeLaunchTrustTests {
    @Test func acceptsMatchingFreshFingerprintRuntime() throws {
        let identity = fixtureIdentity(inode: 10)
        let runtime = fixtureRuntime(identity: identity)
        let refreshed = try BrowserRuntimeLaunchTrustPolicy.validatedRuntime(
            resolved: runtime,
            freshInspection: fixtureInspection(identity: identity)
        )

        #expect(refreshed.inspection.executableIdentity == identity)
        #expect(refreshed.inspection.codeSignatureValid == true)
    }

    @Test func rejectsReplacedFingerprintRuntime() {
        let runtime = fixtureRuntime(identity: fixtureIdentity(inode: 10))

        #expect(throws: NeAntikError.self) {
            try BrowserRuntimeLaunchTrustPolicy.validatedRuntime(
                resolved: runtime,
                freshInspection: fixtureInspection(
                    identity: fixtureIdentity(inode: 11)
                )
            )
        }
    }

    @Test func rejectsFreshUnknownSignatureBeforeIdentityComparison() {
        let identity = fixtureIdentity(inode: 10)
        let runtime = fixtureRuntime(identity: identity)
        let inspection = BrowserRuntimeInspection(
            version: "152.0",
            architectures: ["arm64"],
            codeSignatureValid: nil,
            executableIdentity: identity
        )

        #expect(throws: NeAntikError.self) {
            try BrowserRuntimeLaunchTrustPolicy.validatedRuntime(
                resolved: runtime,
                freshInspection: inspection
            )
        }
    }

    @Test func rejectsMissingStrictIdentityForFingerprintRuntime() {
        let runtime = fixtureRuntime(identity: nil)

        #expect(throws: NeAntikError.self) {
            try BrowserRuntimeLaunchTrustPolicy.validatedRuntime(
                resolved: runtime,
                freshInspection: fixtureInspection(identity: nil)
            )
        }
    }

    @Test func rejectsRuntimeChangedDuringDelayedProxyPreparation() {
        let runtime = fixtureRuntime(identity: fixtureIdentity(inode: 10))
        let afterPreparation = fixtureInspection(
            identity: fixtureIdentity(inode: 10, modificationSeconds: 9)
        )

        #expect(throws: NeAntikError.self) {
            try BrowserRuntimeLaunchTrustPolicy.validatedRuntime(
                resolved: runtime,
                freshInspection: afterPreparation
            )
        }
    }

    private func fixtureRuntime(
        identity: BrowserRuntimeFileIdentity?
    ) -> BrowserRuntime {
        BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            source: "Test",
            flavor: .fingerprintChromium,
            inspection: fixtureInspection(identity: identity)
        )
    }

    private func fixtureInspection(
        identity: BrowserRuntimeFileIdentity?
    ) -> BrowserRuntimeInspection {
        BrowserRuntimeInspection(
            version: "152.0",
            architectures: ["arm64"],
            codeSignatureValid: true,
            executableIdentity: identity
        )
    }

    private func fixtureIdentity(
        inode: UInt64,
        modificationSeconds: Int64 = 2
    ) -> BrowserRuntimeFileIdentity {
        BrowserRuntimeFileIdentity(
            device: 1,
            inode: inode,
            size: 100,
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: 3
        )
    }
}
