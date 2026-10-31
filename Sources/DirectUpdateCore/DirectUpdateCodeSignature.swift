import Darwin
import Foundation
import Security

package enum DirectUpdateCodeSignatureError: LocalizedError, Equatable {
    case identity, signature, policy, metadata, changed
    package var errorDescription: String? {
        switch self {
        case .identity: "Обновление подписано не ожидаемым Developer ID NeAntik."
        case .signature: "Подпись приложения или вложенного кода не прошла проверку."
        case .policy: "Права или защита подписанного приложения не соответствуют этому каналу обновлений."
        case .metadata: "Подписанная версия приложения или движка не совпадает с обновлением."
        case .changed: "Файлы обновления изменились во время проверки."
        }
    }
}

/// Fixed product identities, never requirements supplied by an archive, MCP
/// client, Info.plist team declaration or a downloaded manifest.
package enum DirectUpdateCodeRole: CaseIterable, Sendable {
    case manager, runtime, framework
    /// A debug qualification role must never expand the shipping stage contract.
    package static let shippingRoles: [Self] = [.manager, .runtime, .framework]
    #if DEBUG
    case updatePolicyQualification
    #endif
    package var identifier: String {
        switch self {
        case .manager: "app.neantik.desktop"
        case .runtime: "app.neantik.runtime"
        case .framework: "app.neantik.runtime.framework"
        #if DEBUG
        case .updatePolicyQualification: "app.neantik.desktop.update-policy-qa"
        #endif
        }
    }
    package var executable: String {
        switch self {
        case .manager: "NeAntik"
        case .runtime: "NeAntik Browser"
        case .framework: "NeAntik Browser Framework"
        #if DEBUG
        case .updatePolicyQualification: "NeAntik"
        #endif
        }
    }
    package var entitlements: [String: NSObject] {
        switch self {
        // Legacy Direct contract. The provisioned manager has three exact
        // claims and additionally requires an authenticated matching profile.
        case .manager:
            ["com.apple.application-identifier": "H6VGU2M6JD.app.neantik.desktop" as NSString]
        case .runtime:
            Dictionary(uniqueKeysWithValues: (
                ["audio-input", "bluetooth", "camera", "print", "usb"].map { "com.apple.security.device." + $0 }
                + ["location", "photos-library"].map { "com.apple.security.personal-information." + $0 }
            ).map { ($0, NSNumber(value: true) as NSObject) })
        case .framework: [:]
        #if DEBUG
        case .updatePolicyQualification: [:]
        #endif
        }
    }
}

/// Signature observation only; not notarization, provenance or permission to
/// install. In particular it cannot be decoded into an installation capability.
package struct DirectUpdateCodeSignatureFields: Sendable, Equatable {
    package let identifier: String, version: String, build: String, cdHash: Data
    package let certifiedTimestamp: Date
    package let hardenedRuntimeVerified: Bool
}

package struct DirectUpdateCodeSignatureObservation: Sendable, Equatable {
    private let fields: DirectUpdateCodeSignatureFields
    private let profileValidity: DirectUpdateProvisioningValidity?
    private let signedPlist: Data, signingCertificate: Data
    fileprivate init(_ fields: DirectUpdateCodeSignatureFields, profileValidity: DirectUpdateProvisioningValidity?, signedPlist: Data, signingCertificate: Data) {
        self.fields = fields; self.profileValidity = profileValidity
        self.signedPlist = signedPlist; self.signingCertificate = signingCertificate
    }
    package static func == (lhs: Self, rhs: Self) -> Bool {
        // Foundation can serialize identical authenticated dictionaries in a
        // different key order after other allocations. Byte equality of that
        // derived serialization incorrectly refused an unchanged candidate.
        // The CodeDirectory and certificate remain exact byte comparisons.
        lhs.fields == rhs.fields && lhs.profileValidity == rhs.profileValidity &&
            lhs.signingCertificate == rhs.signingCertificate &&
            DirectUpdateSignedPlistComparison.equal(lhs.signedPlist, rhs.signedPlist)
    }
    /// Only a genuine Security.framework observation can supply update policy.
    /// Parsing an unsigned Bundle dictionary cannot construct this value.
    package func installedUpdateMetadata() throws -> DirectUpdateInstalledMetadata {
        try updateMetadata(expectedIdentifier: DirectUpdateCodeRole.manager.identifier)
    }
    package func requireReleaseCertificate() throws {
        guard DirectUpdateDeveloperIdentity.matches(signingCertificate) else { throw DirectUpdateCodeSignatureError.identity }
    }
    #if DEBUG
    package func qualificationUpdateMetadata() throws -> DirectUpdateInstalledMetadata {
        try updateMetadata(expectedIdentifier: DirectUpdateCodeRole.updatePolicyQualification.identifier)
    }
    #endif
    private func updateMetadata(expectedIdentifier: String) throws -> DirectUpdateInstalledMetadata {
        guard identifier == expectedIdentifier,
              DirectUpdateDeveloperIdentity.matches(signingCertificate),
              let plist = try PropertyListSerialization.propertyList(from: signedPlist, format: nil) as? [String: Any] else {
            throw DirectUpdateCodeSignatureError.policy
        }
        return try DirectUpdateInstalledMetadata.parseSigned(plist, version: version, build: build)
    }
    fileprivate func validateTimePolicy(now: Date) throws { try profileValidity?.validate(now: now) }
    package var identifier: String { fields.identifier }
    package var version: String { fields.version }
    package var build: String { fields.build }
    package var cdHash: Data { fields.cdHash }
    package var certifiedTimestamp: Date { fields.certifiedTimestamp }
    package var developerIDVerified: Bool { true }
    package var nestedAndAllArchitecturesVerified: Bool { true }
    package var hardenedRuntimeVerified: Bool { fields.hardenedRuntimeVerified }
}

/// Genuine signature observations bound to one sealed stage's lifetime. The
/// retained object prevents identity reuse; callers cannot construct this from
/// an array, a receipt or downloaded JSON. Every subsequent use still borrows
/// and validates the same stage. This is not installation authority.
final package class DirectUpdateStageSignature: Sendable {
    private let stage: ExtractedUpdateApp
    package let observations: [DirectUpdateCodeSignatureObservation]
    fileprivate init(stage: ExtractedUpdateApp, observations: [DirectUpdateCodeSignatureObservation]) {
        self.stage = stage; self.observations = observations
    }
    package func requireBinding(to stage: ExtractedUpdateApp, now: Date = Date()) throws {
        guard self.stage === stage else { throw DirectUpdateCodeSignatureError.changed }
        for observation in observations { try observation.validateTimePolicy(now: now) }
    }
    package var manager: DirectUpdateCodeSignatureObservation { observations[0] }
}

package enum DirectUpdateCodeSignature {
    package static let team = "H6VGU2M6JD"
    private static let validationFlags = SecCSFlags(rawValue:
        kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

    /// Internal primitive for an owned sealed stage (or an explicit local
    /// qualification fixture). Security.framework secures the plist supplied
    /// below; a separately parsed unsigned CFBundle dictionary is not trusted.
    package static func inspect(_ url: URL, role: DirectUpdateCodeRole) throws -> DirectUpdateCodeSignatureObservation {
        try Task.checkCancellation()
        let profile = role == .manager ? try DirectUpdateProvisioningSnapshot(app: url) : nil
        var requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"\(role.identifier)\" and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { throw DirectUpdateCodeSignatureError.identity }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { throw DirectUpdateCodeSignatureError.signature }
        guard SecStaticCodeCheckValidity(code, validationFlags, requirement) == errSecSuccess else {
            throw DirectUpdateCodeSignatureError.signature
        }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any] else { throw DirectUpdateCodeSignatureError.signature }
        let result = try validatedFields(info, role: role, provisionedManager: profile?.present == true)
        let leaf = try signingLeaf(info)
        guard let signedPlist = info[kSecCodeInfoPList as String] as? [String: Any] else { throw DirectUpdateCodeSignatureError.metadata }
        let encodedPlist = try PropertyListSerialization.data(fromPropertyList: signedPlist, format: .binary, options: 0)
        try profile?.authenticate(leaf: leaf, bundle: role.identifier)
        guard let executable = info[kSecCodeInfoMainExecutable as String] as? URL else { throw DirectUpdateCodeSignatureError.metadata }
        let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DirectUpdateCodeSignatureError.metadata }
        defer { Darwin.close(fd) }
        let identity = try BackupFS.identity(fd)
        try identity.validateFile(device: nil)
        guard identity.size >= 32, admitsARM64Header(try BackupFS.read(fd, at: 0, count: 32)) else {
            throw DirectUpdateCodeSignatureError.metadata
        }
        try Task.checkCancellation()
        // A fresh validity check detects changes during signing-info inspection;
        // owned stage custody must additionally be checked before/after borrowing.
        var freshCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &freshCode) == errSecSuccess,
              let freshCode,
              SecStaticCodeCheckValidity(freshCode, validationFlags, requirement) == errSecSuccess,
              try BackupFS.identity(fd) == identity else {
            throw DirectUpdateCodeSignatureError.changed
        }
        var freshDictionary: CFDictionary?
        guard SecCodeCopySigningInformation(freshCode, SecCSFlags(rawValue: kSecCSSigningInformation), &freshDictionary) == errSecSuccess,
              let freshInfo = freshDictionary as? [String: Any],
              try validatedFields(freshInfo, role: role, provisionedManager: profile?.present == true) == result,
              let freshPlist = freshInfo[kSecCodeInfoPList as String] as? NSDictionary,
              freshPlist.isEqual(signedPlist as NSDictionary),
              try signingLeaf(freshInfo) == leaf else { throw DirectUpdateCodeSignatureError.changed }
        // Recheck authenticated grants with the current clock, including expiry,
        // after fresh signed-code information; do not downgrade on any failure.
        let validity = try profile?.authenticatedValidity(leaf: leaf, bundle: role.identifier)
        try Task.checkCancellation()
        return .init(result, profileValidity: validity, signedPlist: encodedPlist, signingCertificate: leaf)
    }

    private static func signingLeaf(_ info: [String: Any]) throws -> Data {
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              (1...16).contains(certificates.count) else { throw DirectUpdateCodeSignatureError.identity }
        let leaf = SecCertificateCopyData(certificates[0]) as Data
        guard (1...32_768).contains(leaf.count) else { throw DirectUpdateCodeSignatureError.identity }
        return leaf
    }

    // Current distribution is thin 64-bit ARM64. Universal/future formats must
    // get an explicit contract instead of silently truncating a fat-arch list.
    package static func admitsARM64Header(_ bytes: Data) -> Bool {
        guard bytes.count == 32 else { return false }
        return bytes.prefix(8) == Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1])
    }

    /// Pure scalar policy only. Supplied dictionaries cannot produce an
    /// observation claiming that a cryptographic signature was verified.
    /// Purpose strings are part of the verified signed plist. Old managers keep
    /// their immutable exact contract; only both valid strings admit media claims.
    package static func managerMediaClaims(_ plist: [String: Any]) throws -> [String: NSObject] {
        let keys = ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"]
        if let raw = plist["NeAntikWebKitMediaPolicyEnabled"] {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                throw DirectUpdateCodeSignatureError.policy
            }
            let present = keys.filter { plist[$0] != nil }.count
            guard flag.boolValue ? present == 2 : present == 0 else {
                throw DirectUpdateCodeSignatureError.policy
            }
        }
        guard keys.contains(where: { plist[$0] != nil }) else { return [:] }
        guard keys.allSatisfy({ (plist[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            throw DirectUpdateCodeSignatureError.policy
        }
        return ["com.apple.security.device.camera": NSNumber(value: true),
                "com.apple.security.device.audio-input": NSNumber(value: true)]
    }

    package static func validatedFields(_ info: [String: Any], role: DirectUpdateCodeRole,
                                provisionedManager: Bool = false) throws -> DirectUpdateCodeSignatureFields {
        guard !provisionedManager || role == .manager else { throw DirectUpdateCodeSignatureError.policy }
        guard info[kSecCodeInfoIdentifier as String] as? String == role.identifier,
              info[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let cdHash = info[kSecCodeInfoUnique as String] as? Data, cdHash.count == 20 else {
            throw DirectUpdateCodeSignatureError.identity
        }
        // Timestamp is TSA-certified; signer-supplied kSecCodeInfoTime is not
        // an acceptable substitute. No Keychain credential access occurs here.
        guard let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              CFGetTypeID(flags) != CFBooleanGetTypeID(),
              // Hardened Runtime applies to executables. Chromium signs its
              // framework dylib with options=0; its integrity, Developer ID,
              // timestamp, empty entitlements and frozen payload remain checked.
              // CSCommon.h kSecCodeSignatureRuntime is not imported by Swift.
              role == .framework ? [UInt32(0), UInt32(0x10000)].contains(flags.uint32Value)
                  : flags.uint32Value & 0x10000 != 0,
              let timestamp = info[kSecCodeInfoTimestamp as String] as? Date,
              timestamp.timeIntervalSince1970.isFinite,
              let plist = info[kSecCodeInfoPList as String] as? [String: Any],
              let encoded = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              encoded.count <= 1_048_576 else { throw DirectUpdateCodeSignatureError.policy }
        var claims = provisionedManager ? DirectUpdateProvisioningPolicy.claims(bundle: role.identifier) : role.entitlements
        if role == .manager {
            for (key, value) in try managerMediaClaims(plist) { claims[key] = value }
        }
        let expected = claims as NSDictionary
        if let rawDictionary = info[kSecCodeInfoEntitlementsDict as String] {
            guard let actual = rawDictionary as? NSDictionary else { throw DirectUpdateCodeSignatureError.policy }
            // NSDictionary equality intentionally also checks values. The later
            // strict scalar check prevents true from being admitted as integer1.
            guard actual.isEqual(expected),
                  actual.count == expected.count else { throw DirectUpdateCodeSignatureError.policy }
            for (key, value) in claims {
                let actualValue = actual[key]
                if value is NSNumber {
                    guard let number = actualValue as? NSNumber,
                          CFGetTypeID(number) == CFBooleanGetTypeID(), number.boolValue else { throw DirectUpdateCodeSignatureError.policy }
                } else if let array = value as? [String] {
                    guard actualValue as? [String] == array else { throw DirectUpdateCodeSignatureError.policy }
                } else {
                    guard actualValue is String || actualValue is NSString else { throw DirectUpdateCodeSignatureError.policy }
                }
            }
        } else if expected.count != 0 || info[kSecCodeInfoEntitlements as String] != nil {
            throw DirectUpdateCodeSignatureError.policy
        }
        guard plist["CFBundleIdentifier"] as? String == role.identifier,
              plist["CFBundleExecutable"] as? String == role.executable,
              let version = plist["CFBundleShortVersionString"] as? String,
              let build = plist["CFBundleVersion"] as? String,
              !version.isEmpty, version.utf8.count <= 32, !build.isEmpty, build.utf8.count <= 32 else {
            throw DirectUpdateCodeSignatureError.metadata
        }
        if role == .runtime {
            guard plist["NeAntikRuntimeFlavor"] as? String == "fingerprint-chromium",
                  plist["NeAntikRuntimeBuildMode"] as? String == "source-build" else { throw DirectUpdateCodeSignatureError.metadata }
        }
        return .init(identifier: role.identifier, version: version, build: build, cdHash: cdHash,
                     certifiedTimestamp: timestamp, hardenedRuntimeVerified: flags.uint32Value & 0x10000 != 0)
    }

    /// Not a trusted-update constructor: runtime payload provenance and actual
    /// notary/Gatekeeper gates still have to follow these signature checks.
    package static func inspectStageAsync(_ stage: ExtractedUpdateApp) async throws -> [DirectUpdateCodeSignatureObservation] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try inspectStage(stage) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    package static func inspectBoundStage(_ stage: ExtractedUpdateApp) async throws -> DirectUpdateStageSignature {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            let observations = try inspectStage(stage)
            return DirectUpdateStageSignature(stage: stage, observations: observations)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation(); return result
        } onCancel: { worker.cancel() }
    }

    package static func inspectStage(_ stage: ExtractedUpdateApp) throws -> [DirectUpdateCodeSignatureObservation] {
        try Task.checkCancellation()
        let receipt = stage.archiveIntegrity
        try admitStageLayout(stage.inventory, chromiumVersion: receipt.chromiumVersion)
        return try stage.withValidatedApp { app in
            let runtime = app.appendingPathComponent("Contents/Resources/NeAntik Browser.app")
            let framework = runtime.appendingPathComponent("Contents/Frameworks/NeAntik Browser Framework.framework")
            let managerInfo = try inspect(app, role: .manager)
            let runtimeInfo = try inspect(runtime, role: .runtime)
            let frameworkInfo = try inspect(framework, role: .framework)
            guard managerInfo.version == receipt.version, managerInfo.build == String(receipt.build),
                  runtimeInfo.version == receipt.chromiumVersion,
                  frameworkInfo.version == receipt.chromiumVersion else { throw DirectUpdateCodeSignatureError.metadata }
            return [managerInfo, runtimeInfo, frameworkInfo]
        }
    }

    package static func admitStageLayout(_ inventory: DirectUpdateZIPInventory, chromiumVersion: String) throws {
        let prefix = "NeAntik.app/Contents/", runtime = prefix + "Resources/NeAntik Browser.app/Contents/"
        let framework = runtime + "Frameworks/NeAntik Browser Framework.framework/Versions/" + chromiumVersion + "/"
        let plists = [prefix + "Info.plist", runtime + "Info.plist", framework + "Resources/Info.plist"]
        let executables = [prefix + "MacOS/NeAntik", runtime + "MacOS/NeAntik Browser", framework + "NeAntik Browser Framework"]
        var entries: [String: DirectUpdateZIPInventory.Entry] = [:]
        var metadataBytes: Int64 = 0
        for entry in inventory.entries {
            try Task.checkCancellation()
            guard entries.updateValue(entry, forKey: entry.path) == nil else { throw DirectUpdateCodeSignatureError.metadata }
            // Deep Security validation also parses nested helper bundles.
            let limit: Int64?
            if entry.path.split(separator: "/").last == "Info.plist" { limit = 1_048_576 }
            else if entry.path.hasSuffix("/_CodeSignature/CodeResources") { limit = 8_388_608 }
            else { limit = nil }
            if let limit {
                guard entry.kind == .file, entry.expanded > 0, entry.expanded <= limit else {
                    throw DirectUpdateCodeSignatureError.metadata
                }
                metadataBytes += entry.expanded
                guard metadataBytes <= 33_554_432 else { throw DirectUpdateCodeSignatureError.metadata }
            }
        }
        for entry in inventory.entries {
            let name = entry.path.split(separator: "/").last
            if name == "embedded.mobileprovision" { throw DirectUpdateCodeSignatureError.policy }
            if name == "embedded.provisionprofile" {
                guard entry.path == prefix + "embedded.provisionprofile", entry.kind == .file,
                      entry.expanded > 0, entry.expanded <= DirectUpdateProvisioningPolicy.maximumBytes else {
                    throw DirectUpdateCodeSignatureError.policy
                }
            }
        }
        for path in plists {
            guard let e = entries[path], e.kind == .file, e.expanded > 0, e.expanded <= 1_048_576 else {
                throw DirectUpdateCodeSignatureError.metadata
            }
        }
        for path in executables {
            guard let e = entries[path], e.kind == .file, e.expanded >= 32, e.mode & 0o100 != 0 else {
                throw DirectUpdateCodeSignatureError.metadata
            }
        }
    }
}
