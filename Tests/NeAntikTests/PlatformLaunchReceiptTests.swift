import Foundation
import CryptoKit
import Testing
@testable import NeAntik

struct PlatformLaunchReceiptTests {
    @Test
    func directPlatformFixtureUsesActualManagerPolicy() throws {
        let profile = BrowserProfile(name: "Platform fixture", identity: BrowserIdentity(seed: 21))
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/private/tmp/owned-placeholder"),
            runtimeCapabilities: BrowserRuntimeFlavor.fingerprintChromium.capabilities,
            startURLOverride: URL(string: "http://127.0.0.1:1/")!
        )
        let environment = BrowserLaunchBuilder.environment(
            profile: profile,
            runtimeCapabilities: BrowserRuntimeFlavor.fingerprintChromium.capabilities,
            inherited: [:]
        )
        #expect(arguments.contains("--no-proxy-server"))
        #expect(arguments.contains("--disable-features=WebGPUService"))
        #expect(!arguments.contains(where: { $0.hasPrefix("--fingerprinting-") }))
        #expect(environment == ["NEANTIK_PROFILE_SEED": "21"])
        guard let output = ProcessInfo.processInfo.environment["NEANTIK_PLATFORM_LAUNCH_RECEIPT"] else { return }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try Data(contentsOf: project.appendingPathComponent("Sources/NeAntik/BrowserProcessManager.swift"))
        let receipt: [String: Any] = [
            "schemaVersion": 1, "scope": "synthetic-direct-profile-manager-policy",
            "managerPolicySourceSHA256": SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            "arguments": Array(arguments.dropFirst().dropLast()), "environment": environment
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
    }
}
