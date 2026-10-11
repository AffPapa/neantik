import Darwin
import DirectProvisioning
import Foundation

/// Scalar grants are checked only after native CMS authentication. This pure
/// policy is also testable with contradictory dictionaries; it grants no install
/// authority and never creates, reads or migrates a Keychain credential.
enum DirectUpdateProvisioningPolicy {
    static let maximumBytes = 2 * 1024 * 1024

    static func claims(bundle: String) -> [String: NSObject] {
        let appID = DirectUpdateCodeSignature.team + "." + bundle
        return ["com.apple.application-identifier": appID as NSString,
                "com.apple.developer.team-identifier": DirectUpdateCodeSignature.team as NSString,
                "keychain-access-groups": [appID] as NSArray]
    }

    static func grantAllows(_ value: Any?, claim: String) -> Bool {
        guard let value = value as? String else { return false }
        guard value.contains("*") else { return value == claim }
        return value.filter { $0 == "*" }.count == 1 && value.hasSuffix(".*") &&
            claim.hasPrefix(String(value.dropLast()))
    }

    static func validate(_ profile: [String: Any], bundle: String, leaf: Data, now: Date) throws {
        let team = DirectUpdateCodeSignature.team, appID = team + "." + bundle
        func boolean(_ value: Any?, _ expected: Bool) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue == expected
        }
        guard profile["Platform"] as? [String] == ["OSX"],
              boolean(profile["ProvisionsAllDevices"], true), profile["ProvisionedDevices"] == nil,
              profile["LocalProvision"] == nil || boolean(profile["LocalProvision"], false),
              profile["TeamIdentifier"] as? [String] == [team],
              profile["ApplicationIdentifierPrefix"] as? [String] == [team],
              let created = profile["CreationDate"] as? Date, let expires = profile["ExpirationDate"] as? Date,
              [created, expires, now].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              created <= now, now < expires,
              let grants = profile["Entitlements"] as? [String: Any],
              grants["com.apple.developer.team-identifier"] as? String == team,
              grantAllows(grants["com.apple.application-identifier"], claim: appID),
              let groups = grants["keychain-access-groups"] as? [String], groups.count <= 32,
              groups.contains(where: { grantAllows($0, claim: appID) }),
              let certificates = profile["DeveloperCertificates"] as? [Data],
              (1...16).contains(certificates.count),
              certificates.allSatisfy({ (1...32_768).contains($0.count) }),
              (1...32_768).contains(leaf.count), certificates.contains(leaf) else {
            throw DirectUpdateCodeSignatureError.policy
        }
        for key in ["get-task-allow", "com.apple.security.get-task-allow"] where grants[key] != nil {
            guard boolean(grants[key], false) else { throw DirectUpdateCodeSignatureError.policy }
        }
    }
}

/// This interval can only be obtained from authenticated CMS content whose
/// grants and signing leaf passed policy. It conveys no profile bytes/secrets.
struct DirectUpdateProvisioningValidity: Equatable, Sendable {
    private let created: Date, expires: Date
    fileprivate init(created: Date, expires: Date) { self.created = created; self.expires = expires }
    func validate(now: Date) throws {
        guard now.timeIntervalSince1970.isFinite, created <= now, now < expires else { throw DirectUpdateCodeSignatureError.policy }
    }
}

/// A bounded single-link profile held by captured descriptors. Absence is also
/// captured: a later profile cannot silently change legacy admission into a
/// provisioned contract. The enclosing extracted-stage seal adds tree custody.
final class DirectUpdateProvisioningSnapshot {
    private let directoryURL: URL, directory: Int32, directoryIdentity: BackupIdentity
    private let descriptor: Int32?, identity: BackupIdentity?, bytes: Data?
    private let name = "embedded.provisionprofile"

    init(app: URL) throws {
        try Task.checkCancellation()
        directoryURL = app.appendingPathComponent("Contents")
        directory = try BackupFS.directory(directoryURL)
        do {
            directoryIdentity = try BackupFS.identity(directory)
            guard try BackupFS.entry(directory, "embedded.mobileprovision") == nil else {
                throw DirectUpdateCodeSignatureError.policy
            }
            identity = try BackupFS.entry(directory, name)
            if let identity {
                try identity.validateFile(device: directoryIdentity.device)
                guard (1...Int64(DirectUpdateProvisioningPolicy.maximumBytes)).contains(identity.size) else {
                    throw DirectUpdateCodeSignatureError.policy
                }
                let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw DirectUpdateCodeSignatureError.policy }
                do {
                    guard try BackupFS.identity(fd) == identity else { throw DirectUpdateCodeSignatureError.changed }
                    let captured = try BackupFS.read(fd, at: 0, count: Int(identity.size))
                    guard captured.count == identity.size, try BackupFS.identity(fd) == identity,
                          try BackupFS.entry(directory, name) == identity else { throw DirectUpdateCodeSignatureError.changed }
                    bytes = captured; descriptor = fd
                } catch { Darwin.close(fd); throw error }
            } else { bytes = nil; descriptor = nil }
        } catch { Darwin.close(directory); throw error }
    }
    deinit { if let descriptor { Darwin.close(descriptor) }; Darwin.close(directory) }
    var present: Bool { bytes != nil }

    func authenticate(leaf: Data, bundle: String) throws {
        _ = try authenticatedValidity(leaf: leaf, bundle: bundle)
    }

    func authenticatedValidity(leaf: Data, bundle: String) throws -> DirectUpdateProvisioningValidity? {
        try revalidate()
        guard let bytes else { return nil }
        var status: Int32 = -1
        guard let decoded = neantik_profile_copy_authenticated_content(bytes as CFData, &status),
              status == NEANTIK_PROFILE_OK,
              let profile = try PropertyListSerialization.propertyList(from: decoded as Data, format: nil) as? [String: Any] else {
            throw DirectUpdateCodeSignatureError.policy
        }
        try DirectUpdateProvisioningPolicy.validate(profile, bundle: bundle, leaf: leaf, now: Date())
        try revalidate()
        // These exact types/dates have already passed authenticated policy.
        guard let created = profile["CreationDate"] as? Date, let expires = profile["ExpirationDate"] as? Date else {
            throw DirectUpdateCodeSignatureError.policy
        }
        return .init(created: created, expires: expires)
    }

    func revalidate() throws {
        try Task.checkCancellation()
        try BackupFS.validateDirectoryPath(directoryURL, directoryIdentity)
        guard try BackupFS.identity(directory) == directoryIdentity,
              try BackupFS.entry(directory, "embedded.mobileprovision") == nil,
              try BackupFS.entry(directory, name) == identity else { throw DirectUpdateCodeSignatureError.changed }
        if let descriptor, let identity, let bytes {
            guard try BackupFS.identity(descriptor) == identity,
                  try BackupFS.read(descriptor, at: 0, count: Int(identity.size)) == bytes,
                  try BackupFS.identity(descriptor) == identity else { throw DirectUpdateCodeSignatureError.changed }
        }
    }
}
