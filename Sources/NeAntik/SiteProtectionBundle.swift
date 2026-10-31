import CryptoKit
import Darwin
import Foundation

struct SiteProtectionPreparationError: LocalizedError {
    var errorDescription: String? {
        "Не удалось безопасно подготовить защиту сайтов. Запуск отменён; существующие данные не удалены."
    }
}

struct PreparedSiteProtection: Sendable {
    let directory: URL
    let extensionID: String
    let baselineRuleCount: Int
    let sourceSealSHA256: String
}

/// Signed resources are immutable. Chromium's DNR metadata belongs in the
/// profile's private cache, never inside the application's resource seal.
enum SiteProtectionBundle {
    static let extensionID = "amkgfbjfocbfnpeamfekgijcnfnegndh"
    static let baselineRuleCount = 253
    static let sealSHA256 = "96b1c18a5f6a84f28e3d1f36b6c9a1f04fd204cc0e048cfbe0aafd0fae3e8ee2"
    private static let cacheName = ".neantik-site-protection-v1"
    private static let ownerName = ".neantik-owner-v1.json"
    private static let payloadNames: Set<String> = [
        "SOURCE-NOTICE.txt", "baseline-provenance.json", "cert-rules.json", "manifest.json",
        "policy.mjs", "popup.html", "popup.mjs", "profile-policy.json", "query-rules.json",
        "tracker-rules.json", "worker.mjs", "tracker-provenance.json", "TRACKER-LICENSE-GPL-3.0.txt"
    ]
    private struct Seal: Decodable {
        let schemaVersion: Int, extensionID: String, baselineRuleCount: Int
        let files: [String: String]
    }
    private struct Owner: Codable {
        let schemaVersion: Int, profileID: UUID, root: BackupIdentity
        let payloadDigest: String?
    }

    static func prepare(resources: URL, browserData: URL, profile: BrowserProfile) throws -> PreparedSiteProtection {
        guard profile.engine == .chromium else { throw SiteProtectionPreparationError() }
        let sourceURL = try OwnedProfileDirectory.platformPath(resources)
        let source = try BackupFS.directory(sourceURL); defer { Darwin.close(source) }
        guard Set(try BackupFS.names(source)) == payloadNames.union(["seal.json"]) else { throw SiteProtectionPreparationError() }
        let sealBytes = try read(source, "seal.json", maximum: 65_536, privateFile: false)
        guard hash(sealBytes) == sealSHA256 else { throw SiteProtectionPreparationError() }
        let seal = try JSONDecoder().decode(Seal.self, from: sealBytes)
        guard seal.schemaVersion == 1, seal.extensionID == extensionID,
              seal.baselineRuleCount == baselineRuleCount, Set(seal.files.keys) == payloadNames else { throw SiteProtectionPreparationError() }
        var payload: [String: Data] = [:]
        for name in payloadNames.sorted() {
            let data = try read(source, name, maximum: 4 * 1_024 * 1_024, privateFile: false)
            guard hash(data) == seal.files[name] else { throw SiteProtectionPreparationError() }
            payload[name] = data
        }
        let manifest = try JSONSerialization.jsonObject(with: payload["manifest.json"]!) as? [String: Any]
        guard manifest?["manifest_version"] as? Int == 3,
              let publicKey = manifest?["key"] as? String, let keyBytes = Data(base64Encoded: publicKey),
              extensionIdentifier(keyBytes) == extensionID,
              Set(manifest?["permissions"] as? [String] ?? []) == Set(["declarativeNetRequest", "storage", "alarms", "privacy"]),
              let rules = try JSONSerialization.jsonObject(with: payload["cert-rules.json"]!) as? [[String: Any]],
              rules.count == baselineRuleCount else { throw SiteProtectionPreparationError() }
        payload["profile-policy.json"] = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "siteProtection": profile.privacyPolicy.siteProtection,
            "trackingParameterCleanup": profile.privacyPolicy.trackingParameterCleanup,
            "blockThirdPartyCookies": profile.privacyPolicy != .legacy,
            "intent": profile.privacyPolicy.safeIntent
        ], options: [.sortedKeys])
        let digest = hash(Data((sealSHA256 + ":" + hash(payload["profile-policy.json"]!)).utf8))
        let browserURL = try OwnedProfileDirectory.platformPath(browserData)
        let browser = try BackupFS.directory(browserURL); defer { Darwin.close(browser) }
        try privateDirectory(browser)
        let cache = try child(browser, cacheName); defer { Darwin.close(cache.fd) }
        try ownership(cache.fd, created: cache.created, profile: profile.id, digest: nil)
        let targetName = "payload-" + digest
        let target = try child(cache.fd, targetName); defer { Darwin.close(target.fd) }
        try ownership(target.fd, created: target.created, profile: profile.id, digest: digest)
        // An interrupted own copy may be resumed, but existing modified bytes
        // are never silently overwritten. Validate all present payloads first.
        let initialNames = Set(try BackupFS.names(target.fd))
        guard initialNames.subtracting(payloadNames.union([ownerName, "_metadata"])).isEmpty else { throw SiteProtectionPreparationError() }
        for name in payloadNames where initialNames.contains(name) {
            guard try read(target.fd, name, maximum: 4 * 1_024 * 1_024, privateFile: true) == payload[name] else { throw SiteProtectionPreparationError() }
        }
        for name in payloadNames.sorted() where !initialNames.contains(name) { try writeNew(target.fd, name, payload[name]!) }
        guard fsync(target.fd) == 0, fsync(cache.fd) == 0 else { throw BackupFS.posix() }
        let names = Set(try BackupFS.names(target.fd))
        guard names.subtracting(payloadNames.union([ownerName, "_metadata"])).isEmpty,
              names.isSuperset(of: payloadNames.union([ownerName])) else { throw SiteProtectionPreparationError() }
        for name in payloadNames {
            guard try read(target.fd, name, maximum: 4 * 1_024 * 1_024, privateFile: true) == payload[name] else { throw SiteProtectionPreparationError() }
        }
        let targetURL = browserURL.appendingPathComponent(cacheName, isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
        // _metadata is generated by Chromium. Its content is not a publisher
        // resource; refuse symlinks/special files throughout the owned copy.
        let tree = try BackupTree.capture(targetURL, checksCancellation: false, includeHashes: false, excludeRootTransients: false)
        defer { tree.close() }; try tree.validateAll()
        guard tree.entries.count <= 1_000, tree.entries.reduce(UInt64(0), { $0 + $1.size }) <= 64 * 1_024 * 1_024 else { throw SiteProtectionPreparationError() }
        try BackupFS.validateDirectoryPath(browserURL, try BackupFS.identity(browser))
        guard try BackupFS.entry(browser, cacheName)?.sameObject(BackupFS.identity(cache.fd)) == true,
              try BackupFS.entry(cache.fd, targetName)?.sameObject(BackupFS.identity(target.fd)) == true,
              !targetURL.path.contains(",") else { throw SiteProtectionPreparationError() }
        return .init(directory: targetURL, extensionID: extensionID,
                     baselineRuleCount: baselineRuleCount, sourceSealSHA256: sealSHA256)
    }

    private static func extensionIdentifier(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(16).map { byte in
            String(UnicodeScalar(97 + Int(byte >> 4))!) + String(UnicodeScalar(97 + Int(byte & 15))!)
        }.joined()
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func privateDirectory(_ fd: Int32) throws {
        let value = try BackupFS.identity(fd)
        guard value.directory, value.uid == geteuid(), value.mode & 0o077 == 0 else { throw SiteProtectionPreparationError() }
    }
    private static func child(_ parent: Int32, _ name: String) throws -> (fd: Int32, created: Bool) {
        let created = mkdirat(parent, name, 0o700) == 0
        guard created || errno == EEXIST else { throw BackupFS.posix() }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SiteProtectionPreparationError() }
        do { try privateDirectory(fd); return (fd, created) }
        catch { Darwin.close(fd); throw error }
    }
    private static func ownership(_ directory: Int32, created: Bool, profile: UUID, digest: String?) throws {
        let root = try BackupFS.identity(directory)
        if created {
            let marker = Owner(schemaVersion: 1, profileID: profile, root: root, payloadDigest: digest)
            try writeNew(directory, ownerName, JSONEncoder().encode(marker))
            guard fsync(directory) == 0 else { throw BackupFS.posix() }
        }
        let marker = try JSONDecoder().decode(Owner.self, from: read(directory, ownerName, maximum: 65_536, privateFile: true))
        guard marker.schemaVersion == 1, marker.profileID == profile, marker.root.sameObject(root),
              marker.payloadDigest == digest else { throw SiteProtectionPreparationError() }
    }
    private static func writeNew(_ parent: Int32, _ name: String, _ bytes: Data) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SiteProtectionPreparationError() }; defer { Darwin.close(fd) }
        try BackupFS.write(fd, bytes, at: 0)
        guard fsync(fd) == 0 else { throw BackupFS.posix() }
    }
    private static func read(_ parent: Int32, _ name: String, maximum: Int, privateFile: Bool) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SiteProtectionPreparationError() }; defer { Darwin.close(fd) }
        let before = try BackupFS.identity(fd)
        guard before.mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.links == 1,
              before.uid == geteuid() || (!privateFile && before.uid == 0),
              before.mode & 0o022 == 0, before.size > 0, before.size <= maximum,
              !privateFile || before.mode & 0o077 == 0 else { throw SiteProtectionPreparationError() }
        var bytes = Data(), offset: Int64 = 0
        while offset < before.size {
            let chunk = try BackupFS.read(fd, at: offset, count: Int(min(before.size - offset, 1_048_576)))
            bytes.append(chunk); offset += Int64(chunk.count)
        }
        guard try BackupFS.identity(fd) == before,
              try BackupFS.entry(parent, name) == before else { throw SiteProtectionPreparationError() }
        return bytes
    }
}
