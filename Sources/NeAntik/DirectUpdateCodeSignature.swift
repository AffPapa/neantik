import Darwin
import Foundation
import Security

enum DirectUpdateCodeSignatureError: LocalizedError, Equatable {
    case identity, signature, policy, metadata, changed
    var errorDescription: String? {
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
enum DirectUpdateCodeRole: CaseIterable, Sendable {
    case manager, runtime, framework
    var identifier: String {
        switch self {
        case .manager: "app.neantik.desktop"
        case .runtime: "app.neantik.runtime"
        case .framework: "app.neantik.runtime.framework"
        }
    }
    var executable: String {
        switch self {
        case .manager: "NeAntik"
        case .runtime: "NeAntik Browser"
        case .framework: "NeAntik Browser Framework"
        }
    }
    var entitlements: [String: NSObject] {
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
        }
    }
}

/// Signature observation only; not notarization, provenance or permission to
/// install. In particular it cannot be decoded into an installation capability.
struct DirectUpdateCodeSignatureFields: Sendable, Equatable {
    let identifier: String, version: String, build: String, cdHash: Data
    let certifiedTimestamp: Date
}

struct DirectUpdateCodeSignatureObservation: Sendable, Equatable {
    private let fields: DirectUpdateCodeSignatureFields
    fileprivate init(_ fields: DirectUpdateCodeSignatureFields) { self.fields = fields }
    var identifier: String { fields.identifier }
    var version: String { fields.version }
    var build: String { fields.build }
    var cdHash: Data { fields.cdHash }
    var certifiedTimestamp: Date { fields.certifiedTimestamp }
    var developerIDVerified: Bool { true }
    var nestedAndAllArchitecturesVerified: Bool { true }
    var hardenedRuntimeVerified: Bool { true }
}

enum DirectUpdateCodeSignature {
    static let team = "H6VGU2M6JD"
    private static let validationFlags = SecCSFlags(rawValue:
        kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

    /// Internal primitive for an owned sealed stage (or an explicit local
    /// qualification fixture). Security.framework secures the plist supplied
    /// below; a separately parsed unsigned CFBundle dictionary is not trusted.
    static func inspect(_ url: URL, role: DirectUpdateCodeRole) throws -> DirectUpdateCodeSignatureObservation {
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
              try signingLeaf(freshInfo) == leaf else { throw DirectUpdateCodeSignatureError.changed }
        // Recheck authenticated grants with the current clock, including expiry,
        // after fresh signed-code information; do not downgrade on any failure.
        try profile?.authenticate(leaf: leaf, bundle: role.identifier)
        try Task.checkCancellation()
        return .init(result)
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
    static func admitsARM64Header(_ bytes: Data) -> Bool {
        guard bytes.count == 32 else { return false }
        return bytes.prefix(8) == Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1])
    }

    /// Pure scalar policy only. Supplied dictionaries cannot produce an
    /// observation claiming that a cryptographic signature was verified.
    static func validatedFields(_ info: [String: Any], role: DirectUpdateCodeRole,
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
              // CSCommon.h kSecCodeSignatureRuntime is not imported by Swift.
              flags.uint32Value & 0x10000 != 0,
              let timestamp = info[kSecCodeInfoTimestamp as String] as? Date,
              timestamp.timeIntervalSince1970.isFinite,
              let plist = info[kSecCodeInfoPList as String] as? [String: Any],
              let encoded = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              encoded.count <= 1_048_576 else { throw DirectUpdateCodeSignatureError.policy }
        let claims = provisionedManager ? DirectUpdateProvisioningPolicy.claims(bundle: role.identifier) : role.entitlements
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
                     certifiedTimestamp: timestamp)
    }

    /// Not a trusted-update constructor: runtime payload provenance and actual
    /// notary/Gatekeeper gates still have to follow these signature checks.
    static func inspectStageAsync(_ stage: ExtractedUpdateApp) async throws -> [DirectUpdateCodeSignatureObservation] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try inspectStage(stage) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    static func inspectStage(_ stage: ExtractedUpdateApp) throws -> [DirectUpdateCodeSignatureObservation] {
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

    static func admitStageLayout(_ inventory: DirectUpdateZIPInventory, chromiumVersion: String) throws {
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
