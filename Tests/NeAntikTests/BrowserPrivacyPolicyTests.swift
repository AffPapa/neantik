import Foundation
import Testing
@testable import NeAntik

struct BrowserPrivacyPolicyTests {
    @Test func changingPresetPreservesRetentionAndRejectsUnknown() {
        var policy = BrowserPrivacyPolicy.strict; policy.retention = .ephemeral
        #expect(policy.presetName == "strict")
        #expect(policy.applyingPreset("balanced")?.retention == .ephemeral)
        #expect(policy.applyingPreset("balanced")?.presetName == "balanced")
        #expect(policy.applyingPreset("legacy")?.retention == .ephemeral)
        #expect(BrowserPrivacyPolicy.balanced.applyingPreset("strict")?.retention == .persistent)
        #expect(policy.applyingPreset("unrecognised") == nil)
    }

    @Test func disposableSessionNeverRestoresPersistedTabs() {
        var policy = BrowserPrivacyPolicy.strict; policy.retention = .ephemeral
        var profile = BrowserProfile(name: "Disposable", startURL: "about:blank", privacyPolicy: policy)
        profile.startupMode = .restoreSession; profile.lastLaunchedAt = Date()
        let args = BrowserLaunchBuilder.arguments(profile: profile, browserDataDirectory: URL(fileURLWithPath: "/private/tmp/own-disposable"))
        #expect(!args.contains("--restore-last-session"))
        #expect(args.contains("--new-window"))
        #expect(args.last == "about:blank")
    }

    private func encode(_ profiles: [BrowserProfile]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try ProfileStore.encodeProfiles(profiles, encoder: encoder)
    }

    @Test func legacyAndExplicitPolicyRoundTripDoNotSilentlyUpgradeOrDowngrade() throws {
        let legacy = BrowserProfile(name: "Legacy")
        let oldData = try encode([legacy])
        #expect(try JSONSerialization.jsonObject(with: oldData) is [Any])
        #expect(try ProfileStore.decodeProfiles(oldData).first?.privacyPolicy == .legacy)
        var strict = legacy; strict.privacyPolicy = .strict
        let newData = try encode([strict, legacy])
        let root = try #require(JSONSerialization.jsonObject(with: newData) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 7)
        #expect(try ProfileStore.decodeProfiles(newData).map(\.privacyPolicy) == [.strict, .legacy])
        #expect(strict.duplicated().privacyPolicy == .strict)
        #expect(strict.duplicated().identity != strict.identity)
    }

    @Test func schemaDowngradeMissingNullAndFuturePoliciesAreRefused() throws {
        var profile = BrowserProfile(name: "Policy"); profile.privacyPolicy = .balanced
        let data = try encode([profile]); var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profiles = try #require(root["profiles"] as? [[String: Any]])
        root["schemaVersion"] = 6
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(JSONSerialization.data(withJSONObject: root)) }
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(JSONSerialization.data(withJSONObject: profiles)) }
        root["schemaVersion"] = 7
        profiles[0].removeValue(forKey: "privacyPolicy");root["profiles"] = profiles
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(JSONSerialization.data(withJSONObject: root)) }
        profiles[0]["privacyPolicy"] = NSNull();root["profiles"] = profiles
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(JSONSerialization.data(withJSONObject: root)) }
        let encoded = try JSONEncoder().encode(BrowserPrivacyPolicy.strict)
        var policy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        policy["schemaVersion"] = 2
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BrowserPrivacyPolicy.self, from: JSONSerialization.data(withJSONObject: policy)) }
        policy["schemaVersion"] = 1;policy.removeValue(forKey: "rtc")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BrowserPrivacyPolicy.self, from: JSONSerialization.data(withJSONObject: policy)) }
    }

    @Test func exportsPreservePolicyAndOldConfigEnvelopeCannotHideIt() throws {
        var profile = BrowserProfile(name: "Export");profile.privacyPolicy = .strict
        let document = try ProfileConfigurationTransferDocument(profiles: [profile])
        #expect(document.schemaVersion == 6)
        #expect(try document.makeProfiles().first?.privacyPolicy == .strict)
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        var root = try #require(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        root["schemaVersion"] = 5
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        #expect(throws: (any Error).self) { try decoder.decode(ProfileConfigurationTransferDocument.self, from: JSONSerialization.data(withJSONObject: root)) }
        let template = try UserProfileTemplate(name: "Strict", profile: profile, folderID: nil)
        #expect(template.makeProfile().privacyPolicy == .strict)
    }

    @Test func legacyRuntimeCannotSilentlyIgnoreNewIntent() {
        var profile = BrowserProfile(name: "Unsupported runtime");profile.privacyPolicy = .strict
        #expect(throws: UnsupportedBrowserPrivacyPolicyError.self) { try BrowserLaunchPolicy.validatePrivacyPolicy(profile) }
    }
}
