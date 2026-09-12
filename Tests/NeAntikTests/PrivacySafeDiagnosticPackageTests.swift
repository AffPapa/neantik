import Foundation
import Testing
@testable import NeAntik

struct PrivacySafeDiagnosticPackageTests {
    @Test func packageContainsOnlyCoarseReadinessFacts() throws {
        let system = WorkspaceReadinessSystemInspection(
            application: WorkspaceApplicationIdentity(
                displayName: "NeAntik", version: "0.6.1", build: "40",
                bundleIdentifier: "app.neantik.desktop",
                bundlePath: ["/", "Users", "private", "NeAntik.app"].joined(separator: "/"),
                location: .applications
            ),
            storage: .ready(availableCapacity: 123),
            storageIntegrity: .passed
        )
        let input = WorkspaceReadinessInput(
            system: system, runtimeAvailability: .ready,
            runtimeVersion: "1", runtimeArchitectures: ["arm64"],
            profileCount: 1, runningCount: 0, processAttentionCount: 0,
            directRouteCount: 1, proxiedRouteCount: 0, proxyAttentionCount: 0
        )
        let package = PrivacySafeDiagnosticPackage(
            snapshot: WorkspaceReadinessSnapshot.resolve(input),
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        let text = String(data: try package.encoded(), encoding: .utf8)!
        #expect(text.contains("NeAntik readiness"))
        #expect(!text.contains("/Users/private"))
        #expect(!text.contains("/Users/private"))
        #expect(!text.contains("127.0.0.1"))
    }
}
