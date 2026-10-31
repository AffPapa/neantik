import Foundation
import Darwin
import CryptoKit
import Testing
@testable import NeAntik

struct PlatformCohortLaunchReceiptTests {
    @Test func exportFiniteCohortPolicies() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try Data(contentsOf: project.appendingPathComponent("Sources/NeAntik/BrowserProcessManager.swift"))
        let sourceHash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let output = ProcessInfo.processInfo.environment["NEANTIK_COHORT_LAUNCH_RECEIPTS"].map { URL(fileURLWithPath: $0) }
        if let output {
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            try #require(attributes[.type] as? FileAttributeType == .typeDirectory)
            try #require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            try #require((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        }
        for seed in UInt32(11)...UInt32(21) {
            let profile = BrowserProfile(name: "Own cohort fixture", identity: BrowserIdentity(seed: seed))
            let arguments = BrowserLaunchBuilder.arguments(profile: profile,
                browserDataDirectory: URL(fileURLWithPath: "/private/tmp/owned-placeholder"),
                runtimeCapabilities: BrowserRuntimeFlavor.fingerprintChromium.capabilities,
                startURLOverride: URL(string: "http://127.0.0.1:1/")!)
            let environment = BrowserLaunchBuilder.environment(profile: profile,
                runtimeCapabilities: BrowserRuntimeFlavor.fingerprintChromium.capabilities, inherited: [:])
            #expect(environment == ["NEANTIK_PROFILE_SEED": String(seed)])
            #expect(arguments.contains("--no-proxy-server"))
            #expect(arguments.contains("--disable-features=WebGPUService"))
            guard let output else { continue }
            let receipt: [String: Any] = ["schemaVersion": 1, "scope": "synthetic-direct-profile-manager-policy",
                "managerPolicySourceSHA256": sourceHash, "arguments": Array(arguments.dropFirst().dropLast()), "environment": environment]
            let url = output.appendingPathComponent("seed-\(seed).json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
