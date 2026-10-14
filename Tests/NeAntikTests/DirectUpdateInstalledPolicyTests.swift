import CryptoKit
import Foundation
import Testing
@testable import DirectUpdateCore

struct DirectUpdateInstalledPolicyTests {
    private func plist() -> [String: Any] {
        let pin: [String: Any] = ["sha256": String(repeating: "a", count: 64), "cdHash": String(repeating: "b", count: 40)]
        return ["CFBundleShortVersionString": "0.7.33", "CFBundleVersion": "96",
                UpdateChannelConfiguration.enabledKey: true,
                UpdateChannelConfiguration.manifestURLKey: "https://browser.free/updates/direct.json",
                UpdateChannelConfiguration.publicKeyIDKey: "direct-2026",
                UpdateChannelConfiguration.publicKeyKey: Data(repeating: 3, count: 32).base64EncodedString(),
                DirectUpdateInstalledMetadata.helpersKey: ["schemaVersion": 1, "owner": pin, "assessment": pin]]
    }
    @Test func validScalarsRemainSeparateFromAnAuthenticatedPolicy() throws {
        #expect(DirectUpdateCodeRole.shippingRoles.map(\.identifier) == ["app.neantik.desktop", "app.neantik.runtime", "app.neantik.runtime.framework"])
        let parsed = try DirectUpdateInstalledMetadata.parseSigned(plist(), version: "0.7.33", build: "96")
        #expect(parsed.configuration.isEnabled && parsed.build == 96)
        #expect(parsed.owner.cdHash == Data(repeating: 0xbb, count: 20))
        #expect(parsed.assessment.sha256 == String(repeating: "a", count: 64))
        // No public/Codable constructor exists for DirectUpdateInstalledPolicy.
    }
    @Test(arguments: ["disabled", "integer-enabled", "bad-host", "bad-key", "bad-version", "bad-build", "leading-zero", "missing-helpers", "unknown-helper", "boolean-schema", "fractional-schema", "new-schema", "missing-owner", "extra-pin", "short-hash", "uppercase-hash", "foreign-cdhash"])
    func contradictoryPolicyIsRefused(control: String) throws {
        var info = plist(), build = "96"
        switch control {
        case "disabled": info[UpdateChannelConfiguration.enabledKey] = false
        case "integer-enabled": info[UpdateChannelConfiguration.enabledKey] = 1
        case "bad-host": info[UpdateChannelConfiguration.manifestURLKey] = "https://attacker.invalid/direct.json"
        case "bad-key": info[UpdateChannelConfiguration.publicKeyKey] = Data([1]).base64EncodedString()
        case "bad-version": info["CFBundleShortVersionString"] = "0.7.34"
        case "bad-build": info["CFBundleVersion"] = "97"
        case "leading-zero": info["CFBundleVersion"] = "096"; build = "096"
        case "missing-helpers": info[DirectUpdateInstalledMetadata.helpersKey] = nil
        default:
            var helpers = info[DirectUpdateInstalledMetadata.helpersKey] as! [String: Any]
            switch control {
            case "unknown-helper": helpers["shell"] = helpers["owner"]
            case "boolean-schema": helpers["schemaVersion"] = true
            case "fractional-schema": helpers["schemaVersion"] = 1.5
            case "new-schema": helpers["schemaVersion"] = 2
            case "missing-owner": helpers["owner"] = nil
            default:
                var pin = helpers["owner"] as! [String: Any]
                if control == "extra-pin" { pin["path"] = "/synthetic/other" }
                if control == "short-hash" { pin["sha256"] = "aa" }
                if control == "uppercase-hash" { pin["sha256"] = String(repeating: "A", count: 64) }
                if control == "foreign-cdhash" { pin["cdHash"] = String(repeating: "x", count: 40) }
                helpers["owner"] = pin
            }
            info[DirectUpdateInstalledMetadata.helpersKey] = helpers
        }
        #expect(throws: (any Error).self) { try DirectUpdateInstalledMetadata.parseSigned(info, version: "0.7.33", build: build) }
    }
    @Test func aCertificateDeclarationDoesNotProveDeveloperIdentity() {
        #expect(!DirectUpdateDeveloperIdentity.matches(Data(DirectUpdateDeveloperIdentity.certificateSHA1.utf8)))
        #expect(!DirectUpdateDeveloperIdentity.matches(Data()))
    }
    @Test func modernPolicySelectsNewOwnerAndRetainsOnlySignedPriorPin() throws {
        var info = plist()
        let pin: [String: Any] = ["sha256": String(repeating: "c", count: 64), "cdHash": String(repeating: "d", count: 40)]
        info[DirectUpdateInstalledMetadata.modernHelpersKey] = ["schemaVersion": 2, "owner": pin, "assessment": pin]
        let parsed = try DirectUpdateInstalledMetadata.parseSigned(info, version: "0.7.33", build: "96")
        #expect(parsed.modernHelpers)
        #expect(parsed.owner.cdHash == Data(repeating: 0xdd, count: 20))
        #expect(parsed.legacyOwner?.cdHash == Data(repeating: 0xbb, count: 20))
        #expect(parsed.legacyAssessment?.sha256 == String(repeating: "a", count: 64))
        let old = try DirectUpdateInstalledMetadata.parseSigned(plist(), version: "0.7.33", build: "96")
        #expect(!old.modernHelpers && old.legacyOwner == nil)
    }
    @Test(arguments: ["not-object", "wrong-schema", "boolean-schema", "fractional-schema", "path", "missing-owner", "bad-pin", "invalid-legacy", "required-but-missing", "nonboolean-requirement"])
    func invalidModernPolicyCannotFallback(control: String) {
        var info = plist()
        var modern = info[DirectUpdateInstalledMetadata.helpersKey] as! [String: Any]
        modern["schemaVersion"] = 2
        switch control {
        case "not-object": info[DirectUpdateInstalledMetadata.modernHelpersKey] = false
        case "wrong-schema": modern["schemaVersion"] = 1
        case "boolean-schema": modern["schemaVersion"] = true
        case "fractional-schema": modern["schemaVersion"] = 2.5
        case "path": modern["path"] = "/tmp/other"
        case "missing-owner": modern["owner"] = nil
        case "bad-pin": modern["owner"] = ["sha256": "bad", "cdHash": "bad"]
        case "invalid-legacy": info[DirectUpdateInstalledMetadata.helpersKey] = nil
        case "required-but-missing": info["NeAntikUpdateOwnerContinuityRequired"] = true
        case "nonboolean-requirement": info["NeAntikUpdateOwnerContinuityRequired"] = 1
        default: break
        }
        if control != "not-object" && control != "required-but-missing" { info[DirectUpdateInstalledMetadata.modernHelpersKey] = modern }
        #expect(throws: (any Error).self) { try DirectUpdateInstalledMetadata.parseSigned(info, version: "0.7.33", build: "96") }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_HELPER_PACKAGE_QA"] != nil))
    func actualManagerSignaturePolicyAndUnsignedMutationRefusal() throws {
        let helperApp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_HELPER_PACKAGE_QA"]!)
        let app = helperApp.deletingLastPathComponent().appendingPathComponent("PolicyQA.app")
        let code = try DirectUpdateCodeSignature.inspect(app, role: .updatePolicyQualification)
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try code.installedUpdateMetadata() }
        #expect(throws: (any Error).self) { try DirectUpdateInstalledPolicy.inspect(installedApp: app) }
        let policy = try DirectUpdateInstalledPolicy.qualification(app: app)
        try policy.validate()
        #expect(policy.metadata.configuration.isEnabled && policy.metadata.build == 96)
        #expect(policy.managerCDHash == code.cdHash)
        let infoURL = app.appendingPathComponent("Contents/Info.plist"), original = try Data(contentsOf: infoURL)
        defer { try? original.write(to: infoURL) }
        var info = try PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
        info[UpdateChannelConfiguration.publicKeyKey] = Data(repeating: 4, count: 32).base64EncodedString()
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        #expect(throws: (any Error).self) { try policy.validate() }
        #expect(throws: (any Error).self) { try DirectUpdateInstalledPolicy.qualification(app: app) }
        try original.write(to: infoURL)
        let fresh = try DirectUpdateInstalledPolicy.qualification(app: app)
        let helper = fresh.owner.url, bytes = try Data(contentsOf: helper)
        let replacement = helper.deletingLastPathComponent().appendingPathComponent("policy-replacement")
        try bytes.write(to: replacement); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
        guard rename(replacement.path, helper.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        #expect(throws: (any Error).self) { try fresh.validate() }
        // A new genuine capture can admit the unchanged signed bytes; the old
        // capture cannot silently adopt the replaced file's inode.
        try DirectUpdateInstalledPolicy.qualification(app: app).validate()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_HELPER_PACKAGE_QA"] != nil))
    func actualSignedHelperPinsAndRetainedReplacementRefusal() throws {
        let app = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_HELPER_PACKAGE_QA"]!)
        guard app.path.hasPrefix("/private/tmp/neantik-update-helper-package-"),
              try String(contentsOf: app.deletingLastPathComponent().appendingPathComponent("fixture.marker"), encoding: .utf8) == "isolated-update-helper-package-qa\n" else {
            Issue.record("Expected isolated helper package fixture"); return
        }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        let pins = info[DirectUpdateInstalledMetadata.helpersKey] as! [String: Any]
        let ownerPin = try DirectUpdateHelperPin.parse(pins["owner"]), assessmentPin = try DirectUpdateHelperPin.parse(pins["assessment"])
        let owner = try DirectAssessmentHelper.packagedOwner(in: app, releasePayloadSHA256: ownerPin.sha256, releaseCDHash: ownerPin.cdHash)
        let assessment = try DirectAssessmentHelper.packaged(in: app, releasePayloadSHA256: assessmentPin.sha256, releaseCDHash: assessmentPin.cdHash)
        try owner.validate(); try assessment.validate()
        #expect(throws: (any Error).self) {
            try DirectAssessmentHelper.packagedOwner(in: app, releasePayloadSHA256: assessmentPin.sha256, releaseCDHash: assessmentPin.cdHash)
        }
        let bytes = try Data(contentsOf: owner.url)
        let replacement = owner.url.deletingLastPathComponent().appendingPathComponent("replacement")
        try bytes.write(to: replacement); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
        guard rename(replacement.path, owner.url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        #expect(throws: DirectAssessmentParentError.helper) { try owner.validate() }
        try assessment.validate() // replacing one helper must not taint the other
    }
}
