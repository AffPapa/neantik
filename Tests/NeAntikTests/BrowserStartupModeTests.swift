import Foundation
import Testing
@testable import NeAntik

struct BrowserStartupModeTests {
    let directory = URL(fileURLWithPath: "/private/tmp/neantik-startup-synthetic")

    @Test func legacyDocumentsPreserveStartPageAndRejectUnknownMode() throws {
        let profile = BrowserProfile(name: "Synthetic")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object.removeValue(forKey: "startupMode")
        let decoded = try JSONDecoder().decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == profile && decoded.startupMode == .startPage)
        object["startupMode"] = "unknown-mode"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func firstLaunchUsesStartPageAndRelaunchRestoresWithoutExtraURL() throws {
        var profile = BrowserProfile(name: "Synthetic", startURL: "https://owned.test/start", startupMode: .restoreSession)
        let first = BrowserLaunchBuilder.arguments(profile: profile, browserDataDirectory: directory)
        #expect(first.contains("--new-window") && first.last == profile.startURL)
        #expect(!first.contains("--restore-last-session"))
        profile.lastLaunchedAt = Date(timeIntervalSince1970: 100)
        let resumed = BrowserLaunchBuilder.arguments(profile: profile, browserDataDirectory: directory)
        #expect(resumed.contains("--restore-last-session"))
        #expect(!resumed.contains("--new-window") && !resumed.contains(profile.startURL))
        #expect(resumed.contains("--no-proxy-server"))
        #expect(try JSONDecoder().decode(BrowserProfile.self, from: JSONEncoder().encode(profile)) == profile)
        #expect(profile.duplicated().startupMode == .restoreSession)
        #expect(profile.duplicated().lastLaunchedAt == nil)
    }

    @Test func explicitTargetAuditAndLegacyModeKeepFreshWindows() {
        var profile = BrowserProfile(name: "Synthetic", startupMode: .restoreSession, lastLaunchedAt: Date())
        for purpose in [BrowserLaunchPurpose.normal, .fingerprintAudit(httpLoopbackPort: 1234)] {
            let explicit = BrowserLaunchBuilder.arguments(profile: profile, browserDataDirectory: directory,
                startURLOverride: URL(string: "about:blank"), purpose: purpose)
            #expect(explicit.contains("--new-window") && explicit.last == "about:blank")
            #expect(!explicit.contains("--restore-last-session"))
        }
        let audit = BrowserLaunchBuilder.arguments(profile: profile, browserDataDirectory: directory, purpose: .fingerprintAudit(httpLoopbackPort: 1234))
        #expect(audit.contains("--new-window") && audit.last == profile.startURL)
        profile.startupMode = .startPage
        let legacy = BrowserLaunchBuilder.arguments(profile: profile, browserDataDirectory: directory)
        #expect(legacy.contains("--new-window") && legacy.last == profile.startURL)
    }

    @Test func configurationTransferPreservesModeWithFreshLaunchHistory() throws {
        let profile = BrowserProfile(name: "Synthetic", startupMode: .restoreSession, lastLaunchedAt: Date())
        let entry = try ProfileConfigurationTransferEntry(profile: profile, folderName: nil)
        #expect(entry.startupMode == .restoreSession)
        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ProfileConfigurationTransferEntry.self, from: encoded)
        #expect(decoded == entry)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "startupMode")
        let legacy = try JSONDecoder().decode(ProfileConfigurationTransferEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.startupMode == nil)
        try legacy.validate()
    }

    @Test func extraArgumentsCannotOverrideRestorationOrNetworkPolicy() {
        let profile = BrowserProfile(name: "Synthetic", proxy: .init(kind: .http, host: "owned.test", port: 1234, username: ""), lastLaunchedAt: Date())
        let clean = BrowserLaunchBuilder.arguments(profile: profile, browserDataDirectory: directory)
        let injected = BrowserLaunchBuilder.arguments(profile: profile, browserDataDirectory: directory,
            additionalArguments: ["--restore-last-session", "--new-window", "--no-proxy-server"])
        #expect(injected == clean)
        #expect(clean.contains("--proxy-server=http://owned.test:1234"))
    }
}
