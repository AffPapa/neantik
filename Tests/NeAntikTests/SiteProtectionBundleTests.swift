import Foundation
import Testing
@testable import NeAntik

struct SiteProtectionBundleTests {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/SiteProtection", isDirectory: true)
    }
    private func fixture() throws -> (AppPaths, BrowserProfile, OwnedProfileDirectory) {
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-site-bundle-test-" + UUID().uuidString))
        try paths.prepareBaseDirectories()
        let profile = BrowserProfile(name: "Own site protection", privacyPolicy: .strict)
        let owner = try OwnedProfileDirectory(paths: paths, profileID: profile.id)
        try owner.prepareBrowserData(for: profile)
        return (paths, profile, owner)
    }
    @Test func verifiedPayloadIsCopiedPrivatelyAndReusedWithoutMutatingResources() throws {
        let (paths, profile, owner) = try fixture(); _ = owner
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let before = try Data(contentsOf: resources.appendingPathComponent("profile-policy.json"))
        let copy = try SiteProtectionBundle.prepare(resources: resources, browserData: paths.browserDataDirectory(for: profile.id), profile: profile)
        #expect(copy.extensionID == "amkgfbjfocbfnpeamfekgijcnfnegndh")
        #expect(copy.baselineRuleCount == 253)
        let again = try SiteProtectionBundle.prepare(resources: resources, browserData: paths.browserDataDirectory(for: profile.id), profile: profile)
        #expect(copy.directory == again.directory)
        #expect(try Data(contentsOf: resources.appendingPathComponent("profile-policy.json")) == before)
        #expect(!FileManager.default.fileExists(atPath: resources.appendingPathComponent("_metadata").path))
    }
    @Test func perProfilePolicyDoesNotModifyPublisherPayload() throws {
        let (paths, saved, owner) = try fixture(); _ = owner
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        var profile = saved; profile.privacyPolicy.trackingParameterCleanup = false
        let copy = try SiteProtectionBundle.prepare(resources: resources, browserData: paths.browserDataDirectory(for: profile.id), profile: profile)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: copy.directory.appendingPathComponent("profile-policy.json"))) as? [String: Any]
        #expect(value?["trackingParameterCleanup"] as? Bool == false)
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("profile-policy.json"))) as? [String: Any]
        #expect(original?["trackingParameterCleanup"] as? Bool == true)
    }
    @Test func modifiedCachedCodeIsPreservedAndRefused() throws {
        let (paths, profile, owner) = try fixture(); _ = owner
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let copy = try SiteProtectionBundle.prepare(resources: resources, browserData: paths.browserDataDirectory(for: profile.id), profile: profile)
        let worker = copy.directory.appendingPathComponent("worker.mjs")
        let marker = Data("foreign code is preserved".utf8); try marker.write(to: worker)
        #expect(throws: (any Error).self) {
            try SiteProtectionBundle.prepare(resources: resources, browserData: paths.browserDataDirectory(for: profile.id), profile: profile)
        }
        #expect(try Data(contentsOf: worker) == marker)
    }
    @Test func metadataSymlinkCannotEscapeTheProfile() throws {
        let (paths, profile, owner) = try fixture(); _ = owner
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let copy = try SiteProtectionBundle.prepare(resources: resources, browserData: paths.browserDataDirectory(for: profile.id), profile: profile)
        let outside = paths.rootDirectory.appendingPathComponent("preserve-outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: copy.directory.appendingPathComponent("_metadata"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try SiteProtectionBundle.prepare(resources: resources, browserData: paths.browserDataDirectory(for: profile.id), profile: profile)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
    @Test func disposableIssuancePrecedesAssetCreationAndCleanupRemovesItsCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-site-ephemeral-test-" + UUID().uuidString)
        let paths = AppPaths(rootDirectory: root); try paths.prepareBaseDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = BrowserPrivacyPolicy.strict; policy.retention = .ephemeral
        let profile = BrowserProfile(name: "Own ephemeral assets", privacyPolicy: policy)
        let owner = try OwnedProfileDirectory(paths: paths, profileID: profile.id); try owner.prepareBrowserData(for: profile)
        try EphemeralProfileStorage.prepareLaunch(paths: paths, profile: profile)
        let copy = try SiteProtectionBundle.prepare(resources: resources, browserData: paths.browserDataDirectory(for: profile.id), profile: profile)
        #expect(FileManager.default.fileExists(atPath: copy.directory.path))
        try EphemeralProfileStorage.clear(paths: paths, profile: profile, validateAuthority: {}, requireAbsent: { _ in })
        #expect(!FileManager.default.fileExists(atPath: copy.directory.path))
    }
}
