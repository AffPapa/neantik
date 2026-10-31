import CryptoKit
import Darwin
import Foundation

/// Public Developer ID certificate pin, supplementary to the verified Apple
/// chain, role/team requirements and separately pinned helper payloads.
package enum DirectUpdateDeveloperIdentity {
    package static let certificateSHA256 = "781a0b9f09d3c3ac3bd34017699882ae0bec2c1ecfbbce77077ead353f592728"
    package static func matches(_ certificate: Data) -> Bool {
        SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined() == certificateSHA256
    }
}

package struct DirectUpdateHelperPin: Sendable, Equatable {
    package let sha256: String, cdHash: Data
    private init(sha256: String, cdHash: Data) { self.sha256 = sha256; self.cdHash = cdHash }
    /// Scalar parsing only, not a claim that a helper or signature was checked.
    static func parse(_ value: Any?) throws -> Self {
        guard let value = value as? [String: Any], Set(value.keys) == ["sha256", "cdHash"],
              let hash = value["sha256"] as? String, hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let encoded = value["cdHash"] as? String, encoded.utf8.count == 40,
              encoded.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DirectUpdateCodeSignatureError.policy
        }
        let bytes = Array(encoded.utf8)
        let hashBytes = stride(from: 0, to: bytes.count, by: 2).map { index -> UInt8 in
            func digit(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
            return digit(bytes[index]) * 16 + digit(bytes[index + 1])
        }
        return .init(sha256: hash, cdHash: Data(hashBytes))
    }
}

/// Parsed scalars, never install authority. Production obtains them through a
/// genuine CodeSignatureObservation; this parser remains independently testable.
package struct DirectUpdateInstalledMetadata: Sendable, Equatable {
    package static let helpersKey = "NeAntikUpdateHelpers"
    package static let modernHelpersKey = "NeAntikUpdateHelpersV2"
    package let configuration: UpdateChannelConfiguration
    package let version: String, build: Int
    package let owner, assessment: DirectUpdateHelperPin
    package let legacyOwner, legacyAssessment: DirectUpdateHelperPin?
    package var modernHelpers: Bool { legacyOwner != nil }
    private init(configuration: UpdateChannelConfiguration, version: String, build: Int,
                 owner: DirectUpdateHelperPin, assessment: DirectUpdateHelperPin,
                 legacyOwner: DirectUpdateHelperPin? = nil, legacyAssessment: DirectUpdateHelperPin? = nil) {
        self.configuration = configuration; self.version = version; self.build = build
        self.owner = owner; self.assessment = assessment
        self.legacyOwner = legacyOwner; self.legacyAssessment = legacyAssessment
    }
    static func parseSigned(_ plist: [String: Any], version: String, build: String) throws -> Self {
        guard let enabled = plist[UpdateChannelConfiguration.enabledKey] as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue else { throw UpdateManifestError.channelDisabled }
        let configuration = UpdateChannelConfiguration.fromInfoDictionary(plist)
        guard configuration.isEnabled, let number = Int(build), number > 0, String(number) == build,
              !version.isEmpty, version.utf8.count <= 32,
              plist["CFBundleShortVersionString"] as? String == version,
              plist["CFBundleVersion"] as? String == build,
              let helpers = plist[helpersKey] as? [String: Any], Set(helpers.keys) == ["schemaVersion", "owner", "assessment"],
              let schema = helpers["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: schema.objCType)),
              schema == NSNumber(value: 1) else {
            throw DirectUpdateCodeSignatureError.policy
        }
        let legacyOwner = try DirectUpdateHelperPin.parse(helpers["owner"])
        let legacyAssessment = try DirectUpdateHelperPin.parse(helpers["assessment"])
        if let continuity = plist["NeAntikUpdateOwnerContinuityRequired"] {
            guard let required = continuity as? NSNumber,
                  CFGetTypeID(required) == CFBooleanGetTypeID(),
                  !required.boolValue || plist.keys.contains(modernHelpersKey) else { throw DirectUpdateCodeSignatureError.policy }
        }
        // A malformed modern policy cannot silently select the older installer.
        // Both objects are covered by the manager's genuine code signature.
        if plist.keys.contains(modernHelpersKey) {
            guard let modern = plist[modernHelpersKey] as? [String: Any],
                  Set(modern.keys) == ["schemaVersion", "owner", "assessment"],
                  let schema = modern["schemaVersion"] as? NSNumber,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(),
                  ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: schema.objCType)),
                  schema == NSNumber(value: 2) else { throw DirectUpdateCodeSignatureError.policy }
            return try .init(configuration: configuration, version: version, build: number,
                             owner: .parse(modern["owner"]), assessment: .parse(modern["assessment"]),
                             legacyOwner: legacyOwner, legacyAssessment: legacyAssessment)
        }
        return .init(configuration: configuration, version: version, build: number,
                     owner: legacyOwner, assessment: legacyAssessment)
    }
}

/// Authenticated installed policy plus retained helper custody. Neither a JSON
/// request, an archive, nor an unsigned Info.plist can manufacture this object.
/// Security and disk operations belong on an owner/utility worker, not MainActor.
final package class DirectUpdateInstalledPolicy: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    package let metadata: DirectUpdateInstalledMetadata
    package let owner, assessment: DirectAssessmentHelper
    package let managerCDHash: Data
    private let app: URL, root: Int32, rootIdentity: BackupIdentity, role: DirectUpdateCodeRole
    package var description: String { "DirectUpdateInstalledPolicy(<redacted>)" }
    package var customMirror: Mirror { Mirror(self, children: [:]) }
    private init(app: URL, root: Int32, rootIdentity: BackupIdentity, metadata: DirectUpdateInstalledMetadata,
                 managerCDHash: Data, owner: DirectAssessmentHelper, assessment: DirectAssessmentHelper, role: DirectUpdateCodeRole) {
        self.app = app; self.root = root; self.rootIdentity = rootIdentity; self.metadata = metadata
        self.managerCDHash = managerCDHash; self.owner = owner; self.assessment = assessment
        self.role = role
    }
    deinit { close(root) }
    package static func inspect(installedApp app: URL) throws -> Self {
        try inspect(app: app, role: .manager)
    }
    /// Bootstrap may be driven by the carried prior owner or this release's
    /// primary owner. Each pin comes from signed policy AND a fixed retained
    /// helper payload with the pinned certificate; a same-team process is not enough.
    package static func continuationOwners(in app: URL) throws -> [ProxyRelayExpectedCode] {
        let code = try DirectUpdateCodeSignature.inspect(app, role: .manager)
        let metadata = try code.installedUpdateMetadata()
        let current = try DirectAssessmentHelper.packagedOwner(in: app,
            releasePayloadSHA256: metadata.owner.sha256, releaseCDHash: metadata.owner.cdHash,
            modern: metadata.modernHelpers)
        try current.validate()
        var pins = [current.expectedCode]
        if let legacy = metadata.legacyOwner {
            let prior = try DirectAssessmentHelper.packagedOwner(in: app,
                releasePayloadSHA256: legacy.sha256, releaseCDHash: legacy.cdHash)
            try prior.validate(); pins.append(prior.expectedCode)
        }
        return pins
    }
    #if DEBUG
    /// Actual signed QA code, never production identity or Keychain access.
    /// No arbitrary identifier/certificate/entitlements are accepted here.
    package static func qualification(app: URL) throws -> Self {
        let base = app.deletingLastPathComponent()
        guard base.deletingLastPathComponent().path == "/private/tmp",
              base.lastPathComponent.hasPrefix("neantik-update-helper-package-"),
              app.lastPathComponent == "PolicyQA.app",
              try String(contentsOf: base.appendingPathComponent("fixture.marker"), encoding: .utf8) == "isolated-update-helper-package-qa\n" else {
            throw DirectUpdateCodeSignatureError.policy
        }
        let parent = try BackupFS.directory(base); defer { close(parent) }
        guard try BackupFS.identity(parent).mode & 0o777 == 0o700 else { throw DirectUpdateCodeSignatureError.policy }
        return try inspect(app: app, role: .updatePolicyQualification)
    }
    #endif
    private static func metadata(_ code: DirectUpdateCodeSignatureObservation, role: DirectUpdateCodeRole) throws -> DirectUpdateInstalledMetadata {
        #if DEBUG
        if role == .updatePolicyQualification { return try code.qualificationUpdateMetadata() }
        #endif
        return try code.installedUpdateMetadata()
    }
    private static func inspect(app: URL, role: DirectUpdateCodeRole) throws -> Self {
        let root = try BackupFS.directory(app)
        var kept = false; defer { if !kept { close(root) } }
        let rootIdentity = try BackupFS.identity(root)
        let code = try DirectUpdateCodeSignature.inspect(app, role: role)
        let metadata = try metadata(code, role: role)
        let owner = try DirectAssessmentHelper.packagedOwner(in: app, releasePayloadSHA256: metadata.owner.sha256, releaseCDHash: metadata.owner.cdHash, modern: metadata.modernHelpers)
        let assessment = try DirectAssessmentHelper.packaged(in: app, releasePayloadSHA256: metadata.assessment.sha256, releaseCDHash: metadata.assessment.cdHash, modern: metadata.modernHelpers)
        let policy = Self(app: app, root: root, rootIdentity: rootIdentity, metadata: metadata,
                          managerCDHash: code.cdHash, owner: owner, assessment: assessment, role: role)
        kept = true
        try policy.validate()
        return policy
    }
    package func validate() throws {
        try Task.checkCancellation()
        try BackupFS.validateDirectoryPath(app, rootIdentity)
        guard try BackupFS.identity(root).sameObject(rootIdentity) else { throw DirectUpdateCodeSignatureError.changed }
        let code = try DirectUpdateCodeSignature.inspect(app, role: role)
        guard code.cdHash == managerCDHash, try Self.metadata(code, role: role) == metadata else {
            throw DirectUpdateCodeSignatureError.changed
        }
        try owner.validate(); try assessment.validate()
        try BackupFS.validateDirectoryPath(app, rootIdentity)
        try Task.checkCancellation()
    }
}
