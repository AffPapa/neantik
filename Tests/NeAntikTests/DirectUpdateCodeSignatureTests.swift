import Darwin
import Foundation
import Security
import Testing
@testable import NeAntik
@testable import DirectUpdateCore

struct DirectUpdateCodeSignatureTests {
    private func information(_ role: DirectUpdateCodeRole) -> [String: Any] {
        var plist: [String: Any] = ["CFBundleIdentifier": role.identifier, "CFBundleExecutable": role.executable,
            "CFBundleShortVersionString": role == .manager ? "0.7.29" : "156.0.8078.12", "CFBundleVersion": role == .manager ? "92" : "8078.12"]
        if role == .runtime { plist["NeAntikRuntimeFlavor"] = "fingerprint-chromium"; plist["NeAntikRuntimeBuildMode"] = "source-build" }
        return [kSecCodeInfoIdentifier as String: role.identifier, kSecCodeInfoTeamIdentifier as String: DirectUpdateCodeSignature.team,
            kSecCodeInfoUnique as String: Data(repeating: 1, count: 20), kSecCodeInfoFlags as String: NSNumber(value: 0x10000),
            kSecCodeInfoTimestamp as String: Date(timeIntervalSince1970: 1_800_000_000),
            kSecCodeInfoPList as String: plist, kSecCodeInfoEntitlementsDict as String: role.entitlements]
    }
    @Test(arguments: [false, true])
    func managerMediaContractPreservesOldAppsAndRefusesIncompleteClaims(provisioned: Bool) throws {
        var info = information(.manager)
        let base = provisioned ? DirectUpdateProvisioningPolicy.claims(bundle: DirectUpdateCodeRole.manager.identifier) : DirectUpdateCodeRole.manager.entitlements
        info[kSecCodeInfoEntitlementsDict as String] = base
        _ = try DirectUpdateCodeSignature.validatedFields(info, role: .manager, provisionedManager: provisioned)
        var plist = try #require(info[kSecCodeInfoPList as String] as? [String: Any])
        plist["NSCameraUsageDescription"] = "Camera for user-approved website"
        plist["NSMicrophoneUsageDescription"] = "Microphone for user-approved website"
        #expect(try DirectUpdateCodeSignature.managerMediaClaims(["NeAntikWebKitMediaPolicyEnabled": false]).isEmpty)
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.managerMediaClaims(["NeAntikWebKitMediaPolicyEnabled": true]) }
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.managerMediaClaims(["NeAntikWebKitMediaPolicyEnabled": 1]) }
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.managerMediaClaims(plist.merging(["NeAntikWebKitMediaPolicyEnabled": false]) { _, rhs in rhs }) }
        plist["NeAntikWebKitMediaPolicyEnabled"] = true
        let media = try DirectUpdateCodeSignature.managerMediaClaims(plist)
        let all = base.merging(media) { _, rhs in rhs }
        info[kSecCodeInfoPList as String] = plist; info[kSecCodeInfoEntitlementsDict as String] = all
        _ = try DirectUpdateCodeSignature.validatedFields(info, role: .manager, provisionedManager: provisioned)
        for key in media.keys {
            var broken = info, claims = all; claims.removeValue(forKey: key)
            broken[kSecCodeInfoEntitlementsDict as String] = claims
            #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.validatedFields(broken, role: .manager, provisionedManager: provisioned) }
            claims = all; claims[key] = NSNumber(value: 1); broken[kSecCodeInfoEntitlementsDict as String] = claims
            #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.validatedFields(broken, role: .manager, provisionedManager: provisioned) }
            claims = all; claims[key] = NSNumber(value: false); broken[kSecCodeInfoEntitlementsDict as String] = claims
            #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.validatedFields(broken, role: .manager, provisionedManager: provisioned) }
        }
        for malformed in ["", " ", "\n"] {
            var broken = plist; broken["NSCameraUsageDescription"] = malformed
            #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.managerMediaClaims(broken) }
        }
        var broken = plist; broken.removeValue(forKey: "NSCameraUsageDescription")
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.managerMediaClaims(broken) }
        var extra = all; extra["get-task-allow"] = NSNumber(value: false)
        info[kSecCodeInfoEntitlementsDict as String] = extra
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.validatedFields(info, role: .manager, provisionedManager: provisioned) }
    }

    @Test(arguments: DirectUpdateCodeRole.allCases)
    func fixedContractAcceptsOnlyCurrentRoleInformation(role: DirectUpdateCodeRole) throws {
        let result = try DirectUpdateCodeSignature.validatedFields(information(role), role: role)
        #expect(result.identifier == role.identifier && result.cdHash.count == 20)
    }
    @Test(arguments: DirectUpdateCodeRole.shippingRoles)
    func onlyFrameworkAllowsNoExecutableRuntimeFlag(role: DirectUpdateCodeRole) throws {
        var info = information(role)
        info[kSecCodeInfoFlags as String] = NSNumber(value: 0)
        if role == .framework {
            let result = try DirectUpdateCodeSignature.validatedFields(info, role: role)
            #expect(!result.hardenedRuntimeVerified)
            for invalid in [UInt32(2), UInt32(0x10002)] {
                info[kSecCodeInfoFlags as String] = NSNumber(value: invalid)
                #expect(throws: DirectUpdateCodeSignatureError.policy) {
                    try DirectUpdateCodeSignature.validatedFields(info, role: role)
                }
            }
        } else {
            #expect(throws: DirectUpdateCodeSignatureError.policy) {
                try DirectUpdateCodeSignature.validatedFields(info, role: role)
            }
        }
    }

    @Test(arguments: ["identifier", "team", "hash", "runtime-flag", "missing-timestamp", "signer-time", "plist-id", "plist-executable", "plist-version", "extra-entitlement", "wrong-appid", "missing-entitlement"])
    func legacyManagerContractRefusesContradictions(control: String) throws {
        var info = information(.manager)
        switch control {
        case "identifier": info[kSecCodeInfoIdentifier as String] = "app.other.product"
        case "team": info[kSecCodeInfoTeamIdentifier as String] = "AAAAAAAAAA"
        case "hash": info[kSecCodeInfoUnique as String] = Data([1])
        case "runtime-flag": info[kSecCodeInfoFlags as String] = NSNumber(value: 0)
        case "missing-timestamp": info[kSecCodeInfoTimestamp as String] = nil
        case "signer-time": info[kSecCodeInfoTime as String] = info.removeValue(forKey: kSecCodeInfoTimestamp as String)
        case "plist-id", "plist-executable", "plist-version":
            var p = info[kSecCodeInfoPList as String] as! [String: Any]
            p[control == "plist-id" ? "CFBundleIdentifier" : control == "plist-executable" ? "CFBundleExecutable" : "CFBundleShortVersionString"] = control == "plist-version" ? "" : "Other"
            info[kSecCodeInfoPList as String] = p
        case "extra-entitlement", "wrong-appid":
            var e = DirectUpdateCodeRole.manager.entitlements
            e[control == "extra-entitlement" ? "com.apple.security.get-task-allow" : "com.apple.application-identifier"] = control == "extra-entitlement" ? NSNumber(value: true) : "H6VGU2M6JD.app.other" as NSString
            info[kSecCodeInfoEntitlementsDict as String] = e
        case "missing-entitlement": info[kSecCodeInfoEntitlementsDict as String] = nil
        default: Issue.record("Unknown control")
        }
        #expect(throws: (any Error).self) { try DirectUpdateCodeSignature.validatedFields(info, role: .manager) }
    }
    @Test(arguments: ["number", "false", "missing", "flavor", "mode"])
    func runtimeContractRefusesIntegerBooleanAndFlavorDrift(control: String) throws {
        var info = information(.runtime)
        if ["number", "false", "missing"].contains(control) {
            var e = DirectUpdateCodeRole.runtime.entitlements
            e["com.apple.security.device.camera"] = control == "missing" ? nil : NSNumber(value: control == "false" ? 0 : 1)
            info[kSecCodeInfoEntitlementsDict as String] = e
        } else {
            var p = info[kSecCodeInfoPList as String] as! [String: Any]
            p[control == "flavor" ? "NeAntikRuntimeFlavor" : "NeAntikRuntimeBuildMode"] = "foreign"
            info[kSecCodeInfoPList as String] = p
        }
        #expect(throws: (any Error).self) { try DirectUpdateCodeSignature.validatedFields(info, role: .runtime) }
    }
    @Test func frameworkAllowsAbsentEntitlementsButRefusesExtraGrant() throws {
        var info = information(.framework); info[kSecCodeInfoEntitlementsDict as String] = nil
        _ = try DirectUpdateCodeSignature.validatedFields(info, role: .framework)
        info[kSecCodeInfoEntitlementsDict as String] = ["com.apple.security.cs.allow-jit": true]
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.validatedFields(info, role: .framework) }
    }

    @Test(arguments: ["valid", "missing-profile", "legacy-with-profile", "wrong-group", "extra-group", "wrong-team", "extra-debug", "foreign-role"])
    func provisionedManagerRequiresExactThreeClaims(control: String) throws {
        var info = information(control == "foreign-role" ? .runtime : .manager)
        var claims = DirectUpdateProvisioningPolicy.claims(bundle: DirectUpdateCodeRole.manager.identifier)
        switch control {
        case "wrong-group": claims["keychain-access-groups"] = ["H6VGU2M6JD.app.other"] as NSArray
        case "extra-group": claims["keychain-access-groups"] = ["H6VGU2M6JD.app.neantik.desktop", "H6VGU2M6JD.app.other"] as NSArray
        case "wrong-team": claims["com.apple.developer.team-identifier"] = "AAAAAAAAAA" as NSString
        case "extra-debug": claims["get-task-allow"] = NSNumber(value: false)
        default: break
        }
        if control != "legacy-with-profile" { info[kSecCodeInfoEntitlementsDict as String] = claims }
        let provisioned = control != "missing-profile", role: DirectUpdateCodeRole = control == "foreign-role" ? .runtime : .manager
        if control == "valid" { _ = try DirectUpdateCodeSignature.validatedFields(info, role: role, provisionedManager: provisioned) }
        else { #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.validatedFields(info, role: role, provisionedManager: provisioned) } }
    }

    @Test(arguments: ["wrong-type", "raw-without-dictionary"])
    func malformedFrameworkEntitlementsCannotMasqueradeAsAbsence(control: String) throws {
        var info = information(.framework)
        if control == "wrong-type" { info[kSecCodeInfoEntitlementsDict as String] = "invalid" }
        else {
            info[kSecCodeInfoEntitlementsDict as String] = nil
            info[kSecCodeInfoEntitlements as String] = Data([1,2,3])
        }
        #expect(throws: DirectUpdateCodeSignatureError.policy) { try DirectUpdateCodeSignature.validatedFields(info, role: .framework) }
    }

    @Test func thinARM64ContractRefusesTruncatedForeignAndFatHeaders() {
        let valid = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1] + Array(repeating: 0, count: 24))
        #expect(DirectUpdateCodeSignature.admitsARM64Header(valid))
        #expect(!DirectUpdateCodeSignature.admitsARM64Header(Data(valid.prefix(8))))
        var foreign = valid; foreign[4] = 7
        #expect(!DirectUpdateCodeSignature.admitsARM64Header(foreign))
        var fat = valid; fat.replaceSubrange(0..<4, with: [0xca, 0xfe, 0xba, 0xbe])
        #expect(!DirectUpdateCodeSignature.admitsARM64Header(fat))
    }

    @Test(arguments: ["valid", "valid-profile", "missing", "large-plist", "link-plist", "non-executable", "other-user-executable", "large-helper-plist", "large-resources", "metadata-budget", "profile", "empty-profile", "large-profile", "nested-profile", "mobile-profile", "duplicate"])
    func stageBoundsAndProfilePolicyAreAdmittedBeforeSecurityParsing(control: String) throws {
        let version = "156.0.8078.12", prefix = "NeAntik.app/Contents/", runtime = prefix + "Resources/NeAntik Browser.app/Contents/"
        let framework = runtime + "Frameworks/NeAntik Browser Framework.framework/Versions/" + version + "/"
        func entry(_ path: String, kind: DirectUpdateZIPInventory.Kind = .file, mode: mode_t = 0o644, size: Int64 = 32) -> DirectUpdateZIPInventory.Entry {
            .init(path: path, kind: kind, mode: mode, dataOffset: 0, compressed: size, expanded: size, method: 0, crc: 0, target: kind == .symlink ? "other" : nil)
        }
        var entries = [entry(prefix + "Info.plist"), entry(runtime + "Info.plist"), entry(framework + "Resources/Info.plist"),
            entry(prefix + "MacOS/NeAntik", mode: 0o755), entry(runtime + "MacOS/NeAntik Browser", mode: 0o755), entry(framework + "NeAntik Browser Framework", mode: 0o755)]
        switch control {
        case "missing": entries.removeFirst()
        case "large-plist": entries[0] = entry(prefix + "Info.plist", size: 1_048_577)
        case "link-plist": entries[0] = entry(prefix + "Info.plist", kind: .symlink)
        case "non-executable": entries[3] = entry(prefix + "MacOS/NeAntik")
        case "other-user-executable": entries[3] = entry(prefix + "MacOS/NeAntik", mode: 0o645)
        case "large-helper-plist": entries.append(entry(runtime + "Frameworks/Helper.app/Contents/Info.plist", size: 1_048_577))
        case "large-resources": entries.append(entry(runtime + "Frameworks/Helper.app/Contents/_CodeSignature/CodeResources", size: 8_388_609))
        case "metadata-budget":
            entries += (0..<5).map { entry(runtime + "Frameworks/Helper\($0).app/Contents/_CodeSignature/CodeResources", size: 8_388_608) }
        case "profile": entries.append(entry(prefix + "embedded.provisionprofile", kind: .symlink))
        case "valid-profile": entries.append(entry(prefix + "embedded.provisionprofile"))
        case "empty-profile": entries.append(entry(prefix + "embedded.provisionprofile", size: 0))
        case "large-profile": entries.append(entry(prefix + "embedded.provisionprofile", size: 2_097_153))
        case "nested-profile": entries.append(entry(runtime + "embedded.provisionprofile"))
        case "mobile-profile": entries.append(entry(prefix + "embedded.mobileprovision"))
        case "duplicate": entries.append(entries[0])
        default: break
        }
        let inventory = DirectUpdateZIPInventory(entries: entries, expandedBytes: 192)
        if ["valid", "valid-profile"].contains(control) { try DirectUpdateCodeSignature.admitStageLayout(inventory, chromiumVersion: version) }
        else { #expect(throws: (any Error).self) { try DirectUpdateCodeSignature.admitStageLayout(inventory, chromiumVersion: version) } }
    }

    // Explicit fixture opt-in; no installed application/profiles/Keychain.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_CODE_APP"] != nil), arguments: DirectUpdateCodeRole.shippingRoles)
    func actualPublishedDeveloperIDAndCertifiedTimestamp(role: DirectUpdateCodeRole) throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEANTIK_UPDATE_CODE_APP"])
        let app = URL(fileURLWithPath: path), runtime = app.appendingPathComponent("Contents/Resources/NeAntik Browser.app")
        let target = role == .manager ? app : role == .runtime ? runtime : runtime.appendingPathComponent("Contents/Frameworks/NeAntik Browser Framework.framework")
        let result = try DirectUpdateCodeSignature.inspect(target, role: role)
        #expect(result.developerIDVerified && result.nestedAndAllArchitecturesVerified)
        #expect(role == .framework || result.hardenedRuntimeVerified)
        #expect(result.version == (role == .manager ? (ProcessInfo.processInfo.environment["NEANTIK_UPDATE_CODE_VERSION"] ?? "0.7.29") : (ProcessInfo.processInfo.environment["NEANTIK_UPDATE_CODE_RUNTIME_VERSION"] ?? "156.0.8078.12")))
        #expect(result.certifiedTimestamp.timeIntervalSince1970 > 1_700_000_000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_UPDATE_CODE_ADHOC_CONTROL"] == "1"))
    func actuallyValidAdHocSignatureCannotSatisfyDeveloperID() throws {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-update-adhoc-control-" + UUID().uuidString), app = root.appendingPathComponent("NeAntik.app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/NeAntik"))
        let plist: [String: Any] = ["CFBundleIdentifier": DirectUpdateCodeRole.manager.identifier, "CFBundleExecutable": "NeAntik", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.7.29", "CFBundleVersion": "92"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", "--options", "runtime", app.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess)
        let realCode = try #require(code)
        #expect(SecStaticCodeCheckValidity(realCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess)
        #expect(throws: DirectUpdateCodeSignatureError.signature) { try DirectUpdateCodeSignature.inspect(app, role: .manager) }
    }
}
