import Foundation
import Security

/// Metadata and live pin from the same cryptographic CodeDirectory. No Keychain
/// claims, profile adoption or installation permission are supplied by this type.
package struct DirectUpdateEmptyEntitlementCode {
    package let pin: ProxyRelayExpectedCode, cdHash: Data, build: String?
    private init(pin: ProxyRelayExpectedCode, cdHash: Data, build: String?) { self.pin = pin; self.cdHash = cdHash; self.build = build }
    package static func inspect(_ url: URL, identifier: String) throws -> Self {
        try inspect(url, identifier: identifier, beforePin: {})
    }
    // Test-only source hook; production entry has no callback. A path changing
    // between metadata and validity must refuse, not combine code A and code B.
    static func inspect(_ url: URL, identifier: String, beforePin: () throws -> Void) throws -> Self {
        var code: SecStaticCode?, dictionary: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data, hash.count == 20,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber, CFGetTypeID(flags) != CFBooleanGetTypeID(),
              flags.uint32Value & 0x10002 == 0x10000,
              info[kSecCodeInfoTimestamp as String] is Date,
              info[kSecCodeInfoEntitlementsDict as String] == nil || (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?.isEmpty == true,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw DirectUpdateInstallSessionError.identity
        }
        let build = (info[kSecCodeInfoPList as String] as? [String: Any])?["CFBundleVersion"] as? String
        try beforePin()
        let pin = try ProxyRelayExpectedCode.qualifiedPin(at: url, expectedIdentifier: identifier,
            expectedTeamIdentifier: DirectUpdateCodeSignature.team, expectedCDHash: hash)
        return .init(pin: pin, cdHash: hash, build: build)
    }
}
