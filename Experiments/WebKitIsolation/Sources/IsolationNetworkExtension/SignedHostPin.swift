import Foundation
import Security
import NetworkExtension
import IsolationCore

/// Supplied by a trusted installer after bundle hash/signature qualification,
/// never derived from flow-provided signing identifiers or a user path.
public final class SignedHostPin: @unchecked Sendable {
    private let requirement: SecRequirement
    private let expression: String
    private let identifier: String
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
    }
    /// Dynamic guest lookup by the complete kernel audit token includes PID
    /// incarnation. Static path validation and same-team checks are insufficient.
    public func verify(kernelAuditToken: Data) throws -> ProcessToken {
        let token = try ProcessToken(kernelBytes: kernelAuditToken)
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: kernelAuditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw IsolationRefusal.invalidToken }
        return token
    }
    /// Recipe only. No saveToPreferences/install is performed by this library.
    /// A dedicated host is mandatory: matching the shared manager would mingle
    /// profile traffic. No domain/tool exclusions are allowed in the recipe.
    public func dedicatedHostRule() -> NEAppRule {
        let rule = NEAppRule(signingIdentifier: identifier, designatedRequirement: expression)
        rule.matchDomains = nil; rule.matchTools = nil; return rule
    }
}
