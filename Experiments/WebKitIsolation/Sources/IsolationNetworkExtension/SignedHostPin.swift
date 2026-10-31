import Foundation
import Security
import NetworkExtension
import IsolationCore

/// Redacted failure stages, never the audit token, executable path or identity.
public enum HostVerificationFailure: Error, Sendable {
    case malformedToken
    case guestLookup(OSStatus)
    case missingGuest
    case requirement(OSStatus)

    public var diagnostic: String {
        switch self {
        case .malformedToken: return "malformed-token"
        case .guestLookup(let status): return "guest-lookup:\(status)"
        case .missingGuest: return "missing-guest"
        case .requirement(let status): return "requirement:\(status)"
        }
    }
}

/// Supplied by a trusted installer after bundle hash/signature qualification,
/// never derived from flow-provided signing identifiers or a user path.
public final class SignedHostPin: @unchecked Sendable {
    private let requirement: SecRequirement
    private let expression: String
    private let identifier: String
    private let expectedClauses: [(name: String, value: SecRequirement)]
    public init(identifier: String, team: String, cdHash: Data) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !identifier.isEmpty, identifier.utf8.count <= 200,
              identifier.unicodeScalars.allSatisfy(allowed.contains),
              team.utf8.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              cdHash.count == 20 else { throw IsolationRefusal.invalidToken }
        self.identifier = identifier
        let hash = cdHash.map { String(format: "%02x", $0) }.joined()
        expression = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\" and cdhash H\"\(hash)\""
        var value: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &value) == errSecSuccess,
              let value else { throw IsolationRefusal.invalidToken }
        requirement = value
        // Expected values only. Never derive clauses from a flow's reported
        // identity, or use these partial matches to authorize a connection.
        expectedClauses = try [
            ("apple", "anchor apple generic"),
            ("developer-id", "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
            ("team", "certificate leaf[subject.OU] = \"\(team)\""),
            ("identifier", "identifier \"\(identifier)\""),
            ("cdhash", "cdhash H\"\(hash)\"")
        ].map { name, text in
            var clause: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &clause) == errSecSuccess,
                  let clause else { throw IsolationRefusal.invalidToken }
            return (name, clause)
        }
    }
    /// Dynamic guest lookup by the complete kernel audit token includes PID
    /// incarnation. Static path validation and same-team checks are insufficient.
    public func verify(kernelAuditToken: Data) throws -> ProcessToken {
        guard let token = try? ProcessToken(kernelBytes: kernelAuditToken) else {
            throw HostVerificationFailure.malformedToken
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: kernelAuditToken] as CFDictionary
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        guard lookup == errSecSuccess else { throw HostVerificationFailure.guestLookup(lookup) }
        guard let code else { throw HostVerificationFailure.missingGuest }
        let validity = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        guard validity == errSecSuccess else { throw HostVerificationFailure.requirement(validity) }
        return token
    }

    /// QA-only explanation after BOTH full A/B checks failed. These statuses
    /// never grant ownership. No signing metadata, actual identity or token is
    /// returned; each label is fixed and each value is a signed OSStatus.
    public func expectedClauseDiagnostics(kernelAuditToken: Data) -> String {
        guard (try? ProcessToken(kernelBytes: kernelAuditToken)) != nil else { return "malformed-token" }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: kernelAuditToken] as CFDictionary
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        guard lookup == errSecSuccess else { return "guest-lookup:\(lookup)" }
        guard let code else { return "missing-guest" }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        let full = SecCodeCheckValidity(code, flags, requirement)
        let integrity = SecCodeCheckValidity(code, flags, nil)
        let clauses = expectedClauses.map { "\($0.name):\(SecCodeCheckValidity(code, flags, $0.value))" }
        // A separate lookup is diagnostic sampling, not a revision of the
        // original verdict. Even full:0 here never changes unknown ownership.
        return (["full:\(full)", "integrity:\(integrity)"] + clauses).joined(separator: ",")
    }
    /// Recipe only. No saveToPreferences/install is performed by this library.
    /// A dedicated host is mandatory: matching the shared manager would mingle
    /// profile traffic. No domain/tool exclusions are allowed in the recipe.
    public func dedicatedHostRule() -> NEAppRule {
        let rule = NEAppRule(signingIdentifier: identifier, designatedRequirement: expression)
        rule.matchDomains = nil; rule.matchTools = nil; return rule
    }
}
