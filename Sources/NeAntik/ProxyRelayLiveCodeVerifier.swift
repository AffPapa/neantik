import Darwin
import Foundation
import Security

/// A pinned code identity from the qualified runtime, not from a client or a
/// path supplied by MCP. The explicit requirement includes the live code's
/// CDHash; another app signed by the same team does not satisfy it.
final class ProxyRelayExpectedCode: @unchecked Sendable {
    enum Failure: Error { case invalidIdentity, invalidRequirement }
    fileprivate let requirement: SecRequirement

    init(identifier: String, teamIdentifier: String, cdHash: Data) throws {
        let identifierBytes = Array(identifier.utf8), teamBytes = Array(teamIdentifier.utf8)
        guard !identifierBytes.isEmpty, identifierBytes.count <= 200,
              identifierBytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }),
              teamBytes.count == 10, teamBytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              cdHash.count == 20
        else { throw Failure.invalidIdentity }
        let hash = cdHash.map { String(format: "%02x", $0) }.joined()
        // Developer ID Application only. This is live identity validation;
        // notarization/Gatekeeper and full payload hashes remain separate.
        let expression = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(identifier)\" and cdhash H\"\(hash)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { throw Failure.invalidRequirement }
        self.requirement = requirement
    }

    /// Called only for a helper/main inside an already hash-qualified runtime.
    /// Static inspection supplies a pin; admission still validates live code.
    /// This does not substitute for runtime payload provenance/notarization.
    static func qualifiedPin(at url: URL, expectedIdentifier: String,
                             expectedTeamIdentifier: String) throws -> ProxyRelayExpectedCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { throw Failure.invalidIdentity }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == expectedIdentifier,
              info[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeamIdentifier,
              let hash = info[kSecCodeInfoUnique as String] as? Data
        else { throw Failure.invalidIdentity }
        let pin = try ProxyRelayExpectedCode(identifier: expectedIdentifier,
                                             teamIdentifier: expectedTeamIdentifier, cdHash: hash)
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), pin.requirement) == errSecSuccess
        else { throw Failure.invalidIdentity }
        return pin
    }
}

/// Validates the running guest of the kernel. SecCodeCopyStaticCode/path
/// validation is deliberately not substituted: Apple's SecCode.h documents
/// that the dynamic→filesystem link is not a secure live-process identity.
/// Inspect only the supplied PID. No argv, payload or credential access.
/// This is a fresh observation, not a process lease or session authorization.
enum ProxyRelayLiveCodeVerifier {
    static func matches(processID: pid_t, expectedProcess: ProxyRelayOwnerProcessIdentity,
                        expectedCode: ProxyRelayExpectedCode) -> Bool {
        guard processID > 0, expectedProcess.userID == geteuid(),
              ProxyRelaySocketOwnerInspector.processIdentity(processID) == expectedProcess
        else { return false }
        for _ in 0..<2 {
            var guest: SecCode?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guest) == errSecSuccess,
                  let guest,
                  SecCodeCheckValidity(guest, SecCSFlags(), expectedCode.requirement) == errSecSuccess,
                  ProxyRelaySocketOwnerInspector.processIdentity(processID) == expectedProcess
            else { return false }
            // Fetch a fresh guest for the second validation rather than
            // reusing an object captured before a possible same-PID exec.
        }
        return true
    }
}
