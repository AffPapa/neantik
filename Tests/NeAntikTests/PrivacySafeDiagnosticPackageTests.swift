import Foundation
import Testing
@testable import NeAntik

struct PrivacySafeDiagnosticPackageTests {
    @Test func diagnosticExportRejectsSyntheticSensitiveMetadata() throws {
        let sentinels = [
            "SYNTHETIC_PASSWORD_DO_NOT_EXPORT",
            "Authorization: Bearer SYNTHETIC_TOKEN",
            "Cookie: session=SYNTHETIC_COOKIE",
            "https://example.invalid/private?token=SYNTHETIC_QUERY#SYNTHETIC_FRAGMENT",
            "socks5://SYNTHETIC_USER:SYNTHETIC_PROXY_PASSWORD@example.invalid:1080",
            "/Users/alice/SYNTHETIC_PRIVATE_PROFILE",
        ]
        let metadata = sentinels.joined(separator: " ")
        let system = WorkspaceReadinessSystemInspection(
            application: WorkspaceApplicationIdentity(
                displayName: metadata, version: metadata, build: metadata,
                bundleIdentifier: metadata, bundlePath: metadata,
                location: .applications
            ),
            storage: .ready(availableCapacity: 123),
            storageIntegrity: .passed
        )
        let input = WorkspaceReadinessInput(
            system: system, runtimeAvailability: .ready,
            runtimeVersion: metadata, runtimeArchitectures: [metadata],
            profileCount: 1, runningCount: 0, processAttentionCount: 0,
            directRouteCount: 1, proxiedRouteCount: 0, proxyAttentionCount: 0
        )
        let package = PrivacySafeDiagnosticPackage(
            snapshot: WorkspaceReadinessSnapshot.resolve(input),
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try package.encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        for sentinel in sentinels { #expect(!text.contains(sentinel)) }
        #expect(!text.contains("SYNTHETIC_"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["schemaVersion", "exportedAt", "readiness", "checks"]))
    }

    @Test func packageContainsOnlyCoarseReadinessFacts() throws {
        let system = WorkspaceReadinessSystemInspection(
            application: WorkspaceApplicationIdentity(
                displayName: "NeAntik", version: "0.6.1", build: "40",
                bundleIdentifier: "app.neantik.desktop",
                bundlePath: "/Users/alice/NeAntik.app",
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
        #expect(!text.contains("/Users/alice"))
        #expect(!text.contains("127.0.0.1"))
    }
}
