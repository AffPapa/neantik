import CryptoKit
import Foundation
import Testing
@testable import NeAntik

struct BrowserFontPolicyRuntimeTests {
    @Test func securitySuccessorPolicyMatchesItsOwnConfiguredSmokeAndSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("docs/evidence/security-backport-font-smoke-development.json"))) as? [String: Any])
        let runtime = try #require(report["runtime"] as? [String: Any])
        let tree = try #require(runtime["runtimeTree"] as? [String: Any])
        let record = try #require(BrowserFontPolicyRuntime.supportedRecords.first {
            $0.executableSHA256 == runtime["executableSHA256"] as? String
        })
        #expect(BrowserFontPolicyRuntime.supportedRecords.count == 2)
        #expect(record.runtimeDigest == tree["digest"] as? String)
        #expect(record.entries == tree["entries"] as? Int)
        #expect(record.regularBytes == tree["bytes"] as? Int64)
        #expect(record.sourceContractSHA256 == report["sourceContractSHA256"] as? String)
        #expect(record.sourceContractSHA256 != BrowserFontPolicyRuntime.sourceContractSHA256)
        #expect(record.runtimeDigest != BrowserFontPolicyRuntime.runtimeDigest)
        #expect(report["actualBrowser"] as? Bool == true)
        #expect(report["headed"] as? Bool == true)
        #expect(report["inputsRechecked"] as? Bool == true)
        #expect(report["releaseQualified"] as? Bool == false)
        for selected in BrowserFontPolicyRuntime.supportedRecords {
            #expect(BrowserFontPolicyRuntime.acceptsMeasurement(digest: selected.runtimeDigest,
                entries: selected.entries, bytes: selected.regularBytes, machoCount: selected.machoCount, record: selected))
            for other in BrowserFontPolicyRuntime.supportedRecords where other != selected {
                #expect(!BrowserFontPolicyRuntime.acceptsMeasurement(digest: other.runtimeDigest,
                    entries: selected.entries, bytes: selected.regularBytes, machoCount: selected.machoCount, record: selected))
            }
        }
    }

    @Test func sourceAndHeadedEvidenceAgreeWithIndependentRuntimePolicy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try Data(contentsOf: root.appendingPathComponent("runtime/font-policy-v1/chromium-font-variations.json"))
        let hash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        #expect(hash == BrowserFontPolicyRuntime.sourceContractSHA256)
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("docs/evidence/font-variation-headed-development.json"))) as? [String: Any])
        let contracts = try #require(report["sourceContracts"] as? [String: String])
        let tree = try #require(report["runtimeTree"] as? [String: Any])
        let runtime = try #require(report["runtime"] as? [String: String])
        #expect(contracts["chromium-font-variations.json"] == hash)
        #expect(tree["digest"] as? String == BrowserFontPolicyRuntime.runtimeDigest)
        #expect(tree["entries"] as? Int == BrowserFontPolicyRuntime.entries)
        #expect(tree["bytes"] as? Int64 == BrowserFontPolicyRuntime.regularBytes)
        #expect(runtime["executableSHA256"] == BrowserFontPolicyRuntime.executableSHA256)
        #expect(report["actualBrowser"] as? Bool == true)
        #expect(report["headed"] as? Bool == true)
    }

    @Test func anyChangedMeasurementRefusesAndFlavorCannotGrantCapability() {
        let digest = BrowserFontPolicyRuntime.runtimeDigest
        let entries = BrowserFontPolicyRuntime.entries
        let bytes = BrowserFontPolicyRuntime.regularBytes
        let count = BrowserFontPolicyRuntime.machoCount
        #expect(BrowserFontPolicyRuntime.acceptsMeasurement(digest: digest, entries: entries, bytes: bytes, machoCount: count))
        #expect(!BrowserFontPolicyRuntime.acceptsMeasurement(digest: String(repeating: "0", count: 64), entries: entries, bytes: bytes, machoCount: count))
        #expect(!BrowserFontPolicyRuntime.acceptsMeasurement(digest: digest, entries: entries + 1, bytes: bytes, machoCount: count))
        #expect(!BrowserFontPolicyRuntime.acceptsMeasurement(digest: digest, entries: entries, bytes: bytes + 1, machoCount: count))
        #expect(!BrowserFontPolicyRuntime.acceptsMeasurement(digest: digest, entries: entries, bytes: bytes, machoCount: count + 1))
        for flavor in BrowserRuntimeFlavor.allCases {
            #expect(!flavor.capabilities.contains(.systemFontPolicy))
            let runtime = BrowserRuntime(name: "Own forged capability", executableURL:
                URL(fileURLWithPath: "/nonexistent/NeAntik Browser.app/Contents/MacOS/NeAntik Browser"),
                source: "Own fixture", flavor: flavor,
                capabilities: [.fingerprintIdentity, .systemFontPolicy],
                inspection: .init(version: BrowserFontPolicyRuntime.version,
                    architectures: ["arm64"], codeSignatureValid: true))
            #expect(!runtime.supportsSystemFontPolicy)
            #expect(!runtime.capabilities.contains(.systemFontPolicy))
            #expect(runtime.fontPolicyQualification == nil)
        }
    }

    @Test func launchEnvironmentRequiresExplicitRequestAndFullCapabilities() {
        var profile = BrowserProfile(name: "Own font environment", startURL: "about:blank")
        let inherited = ["NEANTIK_FONT_POLICY": "system-v1", "NEANTIK_FONT_QA": "owned-v1", "HOME": "/owned"]
        let qualified: BrowserRuntimeCapabilities = [.fingerprintIdentity, .systemFontPolicy]
        #expect(BrowserLaunchBuilder.environment(profile: profile, runtimeCapabilities: qualified, inherited: inherited)["NEANTIK_FONT_POLICY"] == nil)
        let originalIdentity = profile.identity
        profile.fontPolicy = .systemV1
        let cases: [BrowserRuntimeCapabilities] = [[], .fingerprintIdentity, [.fingerprintSeed, .systemFontPolicy]]
        for caps in cases {
            #expect(BrowserLaunchBuilder.environment(profile: profile, runtimeCapabilities: caps, inherited: inherited)["NEANTIK_FONT_POLICY"] == nil)
        }
        let environment = BrowserLaunchBuilder.environment(profile: profile, runtimeCapabilities: qualified, inherited: inherited)
        #expect(environment["NEANTIK_FONT_POLICY"] == "system-v1")
        #expect(environment["NEANTIK_PROFILE_SEED"] == String(profile.identity.runtimeSeed))
        #expect(environment["NEANTIK_FONT_QA"] == nil)
        #expect(profile.identity == originalIdentity)
        profile.fontPolicy = .native
        #expect(BrowserLaunchBuilder.environment(profile: profile, runtimeCapabilities: qualified, inherited: inherited)["NEANTIK_FONT_POLICY"] == nil)
    }
}
