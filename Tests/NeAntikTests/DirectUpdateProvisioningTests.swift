import Darwin
import Foundation
import Security
import Testing
@testable import NeAntik
@testable import DirectUpdateCore

struct DirectUpdateProvisioningTests {
    private let bundle = "app.neantik.desktop"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let leaf = Data([1, 2, 3]) // Scalar policy fixture, not a trusted certificate.
    private func profile() -> [String: Any] {
        ["Platform": ["OSX"], "ProvisionsAllDevices": true,
         "TeamIdentifier": [DirectUpdateCodeSignature.team],
         "ApplicationIdentifierPrefix": [DirectUpdateCodeSignature.team],
         "CreationDate": now.addingTimeInterval(-60), "ExpirationDate": now.addingTimeInterval(60),
         "Entitlements": DirectUpdateProvisioningPolicy.claims(bundle: bundle),
         "DeveloperCertificates": [leaf]]
    }
    @Test func exactOrAppleWildcardGrantsStillAuthorizeOnlyClaimedGroup() throws {
        try DirectUpdateProvisioningPolicy.validate(profile(), bundle: bundle, leaf: leaf, now: now)
        var p = profile(), grants = DirectUpdateProvisioningPolicy.claims(bundle: bundle)
        grants["com.apple.application-identifier"] = "H6VGU2M6JD.app.neantik.*" as NSString
        grants["keychain-access-groups"] = ["H6VGU2M6JD.*"] as NSArray
        p["Entitlements"] = grants
        try DirectUpdateProvisioningPolicy.validate(p, bundle: bundle, leaf: leaf, now: now)
        for grant in ["*", "H6VGU2M6JD*", "H6VGU2M6JD.**", "Other.*", "H6VGU2M6JD.app.other.*", ""] {
            #expect(!DirectUpdateProvisioningPolicy.grantAllows(grant, claim: "H6VGU2M6JD." + bundle))
        }
    }
    @Test(arguments: ["platform", "number-all", "devices", "local", "team", "prefix", "expired", "future",
                      "date-type", "nan", "grant-team", "appid", "group", "group-type", "debug", "debug-number",
                      "cert-mismatch", "cert-type", "cert-empty", "cert-many", "cert-large"])
    func contradictionsRefuseScalarAdmission(control: String) throws {
        var p = profile(), grants = p["Entitlements"] as! [String: NSObject]
        switch control {
        case "platform": p["Platform"] = ["iOS"]
        case "number-all": p["ProvisionsAllDevices"] = NSNumber(value: 1)
        case "devices": p["ProvisionedDevices"] = [] as [String]
        case "local": p["LocalProvision"] = true
        case "team": p["TeamIdentifier"] = ["AAAAAAAAAA"]
        case "prefix": p["ApplicationIdentifierPrefix"] = ["AAAAAAAAAA"]
        case "expired": p["ExpirationDate"] = now
        case "future": p["CreationDate"] = now.addingTimeInterval(1)
        case "date-type": p["CreationDate"] = "date"
        case "nan": p["ExpirationDate"] = Date(timeIntervalSince1970: .nan)
        case "grant-team": grants["com.apple.developer.team-identifier"] = "AAAAAAAAAA" as NSString
        case "appid": grants["com.apple.application-identifier"] = "H6VGU2M6JD.app.neantik.other" as NSString
        case "group": grants["keychain-access-groups"] = ["H6VGU2M6JD.app.neantik.other"] as NSArray
        case "group-type": grants["keychain-access-groups"] = "H6VGU2M6JD.*" as NSString
        case "debug": grants["get-task-allow"] = NSNumber(value: true)
        case "debug-number": grants["com.apple.security.get-task-allow"] = NSNumber(value: 0)
        case "cert-mismatch": p["DeveloperCertificates"] = [Data([4])]
        case "cert-type": p["DeveloperCertificates"] = ["certificate"]
        case "cert-empty": p["DeveloperCertificates"] = [Data()]
        case "cert-many": p["DeveloperCertificates"] = Array(repeating: leaf, count: 17)
        case "cert-large": p["DeveloperCertificates"] = [leaf, Data(repeating: 0, count: 32_769)]
        default: Issue.record("Unknown control")
        }
        p["Entitlements"] = grants
        #expect(throws: DirectUpdateCodeSignatureError.policy) {
            try DirectUpdateProvisioningPolicy.validate(p, bundle: bundle, leaf: leaf, now: now)
        }
    }
    @Test(arguments: ["absent-then-created", "changed", "replaced", "removed", "hardlink", "symlink", "mobile", "empty", "large"])
    func capturedProfileFilesRefuseUnsafeEntriesAndChanges(control: String) throws {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-profile-custody-" + UUID().uuidString)
        let app = root.appendingPathComponent("NeAntik.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profileURL = contents.appendingPathComponent("embedded.provisionprofile")
        let original = Data("bounded unsigned fixture".utf8)
        if control == "absent-then-created" {
            let snapshot = try DirectUpdateProvisioningSnapshot(app: app)
            #expect(!snapshot.present); try original.write(to: profileURL)
            #expect(throws: DirectUpdateCodeSignatureError.changed) { try snapshot.revalidate() }
            return
        }
        try original.write(to: profileURL)
        if control == "hardlink" {
            #expect(link(profileURL.path, contents.appendingPathComponent("alias").path) == 0)
        } else if control == "symlink" {
            try FileManager.default.moveItem(at: profileURL, to: contents.appendingPathComponent("alias"))
            try FileManager.default.createSymbolicLink(atPath: profileURL.path, withDestinationPath: "alias")
        } else if control == "mobile" {
            try original.write(to: contents.appendingPathComponent("embedded.mobileprovision"))
        } else if control == "empty" { try Data().write(to: profileURL)
        } else if control == "large" { try Data(repeating: 0, count: 2 * 1024 * 1024 + 1).write(to: profileURL) }
        if ["hardlink", "symlink", "mobile", "empty", "large"].contains(control) {
            #expect(throws: (any Error).self) { try DirectUpdateProvisioningSnapshot(app: app) }
            return
        }
        let snapshot = try DirectUpdateProvisioningSnapshot(app: app)
        #expect(snapshot.present); try snapshot.revalidate()
        if control == "changed" { try Data("modified unsigned content".utf8).write(to: profileURL)
        } else if control == "replaced" { try original.write(to: profileURL, options: .atomic)
        } else { try FileManager.default.removeItem(at: profileURL) }
        #expect(throws: DirectUpdateCodeSignatureError.changed) { try snapshot.revalidate() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_CODE_APP"] != nil))
    func actualAuthenticatedProfileBindsActualDeveloperIDLeaf() throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_CODE_APP"]))
        var code: SecStaticCode?, signing: CFDictionary?
        try #require(SecStaticCodeCreateWithPath(source as CFURL, SecCSFlags(), &code) == errSecSuccess)
        try #require(SecCodeCopySigningInformation(try #require(code), SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess)
        let info = try #require(signing as? [String: Any])
        let certificates = try #require(info[kSecCodeInfoCertificates as String] as? [SecCertificate])
        let actualLeaf = SecCertificateCopyData(try #require(certificates.first)) as Data
        let root = URL(fileURLWithPath: "/private/tmp/neantik-profile-actual-leaf-" + UUID().uuidString)
        let app = root.appendingPathComponent("NeAntik.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: source.appendingPathComponent("Contents/embedded.provisionprofile"),
                                       to: contents.appendingPathComponent("embedded.provisionprofile"))
        let snapshot = try DirectUpdateProvisioningSnapshot(app: app)
        try snapshot.authenticate(leaf: actualLeaf, bundle: bundle)
        var otherLeaf = actualLeaf; otherLeaf[otherLeaf.startIndex] ^= 1
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try snapshot.authenticate(leaf: otherLeaf, bundle: bundle) }
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try snapshot.authenticate(leaf: actualLeaf, bundle: bundle + ".other") }
        try snapshot.revalidate()
    }
}
