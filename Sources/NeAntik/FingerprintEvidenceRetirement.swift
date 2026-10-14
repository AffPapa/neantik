import CryptoKit
import Darwin
import Foundation
import Security

struct FingerprintEvidenceRetirementRequest: Equatable, Sendable {
    let candidateAppURL: URL
    let candidateManifestURL: URL
    let outputURL: URL
}

enum FingerprintEvidenceRetirement {
    /// An explicit prior candidate is inspected, never executed or installed.
    /// The fixed Direct identity/certificate, signed metadata and exact manager
    /// hash are checked before obtaining the manifest-bound audit authority.
    static func run(_ request: FingerprintEvidenceRetirementRequest) throws {
        let app = request.candidateAppURL
        guard normalizedTmp(app.path) == normalizedTmp(app.resolvingSymlinksInPath().path),
              app.lastPathComponent == "NeAntik.app",
              let bundle = Bundle(url: app)
        else { throw FingerprintEvidenceReleaseError.candidateMetadataMismatch }
        let before = try DirectUpdateCodeSignature.inspect(app, role: .manager)
        try before.requireReleaseCertificate()
        var selfCode: SecCode?, selfStaticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess,
              let selfCode,
              SecCodeCopyStaticCode(selfCode, SecCSFlags(), &selfStaticCode) == errSecSuccess,
              let selfStaticCode,
              SecCodeCopySigningInformation(selfStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let liveExecutable = fields[kSecCodeInfoMainExecutable as String] as? URL,
              let caller = NeAntikLaunchIntent.applicationBundleURL(forExecutablePath: liveExecutable.path),
              let ownIdentity = DirectProcessIdentityInspector.processIdentity(getpid()) else {
            throw FingerprintEvidenceReleaseError.candidateMetadataMismatch
        }
        try DirectUpdateCodeSignature.inspect(caller, role: .manager).requireReleaseCertificate()
        let ownCode = try ProxyRelayExpectedCode.qualifiedPin(at: caller, expectedIdentifier: "app.neantik.desktop", expectedTeamIdentifier: "H6VGU2M6JD")
        guard ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: ownIdentity, expectedCode: ownCode) else {
            throw FingerprintEvidenceReleaseError.candidateMetadataMismatch
        }
        let executable = app.appendingPathComponent("Contents/MacOS/NeAntik")
        let manifest = try FingerprintEvidenceReleaseContext.readStableRegularFile(
            request.candidateManifestURL, maximumBytes: FingerprintEvidenceEnvelopeCodec.maximumManifestBytes)
        let custody = try targetCustody(app)
        try validateInventory(app: app, manifest: manifest)
        let auditRequest = FingerprintEvidenceReleaseRequest(
            candidateManifestURL: request.candidateManifestURL,
            evidenceOutputURL: request.outputURL)
        // Recovery can consume qualification claims; it is deliberately absent
        // from this command. The output's private-directory/no-overwrite checks
        // run before signing or deleting anything.
        let authority = SecureEnclaveFingerprintEvidenceAuthority()
        let binding = try FingerprintEvidenceEnvelopeCodec.manifestBinding(in: manifest)
        guard case let .audit(context) = try FingerprintEvidenceReleaseContext.load(
            request: auditRequest, executableURL: executable, bundle: bundle,
            authority: authority, recoverExistingEvidence: false)
        else { throw FingerprintEvidenceReleaseError.invalidManifest }
        let intentURL = request.outputURL.deletingLastPathComponent().appendingPathComponent("fingerprint-retirement.intent.json")
        let existingIntent: Data?
        if FileManager.default.fileExists(atPath: intentURL.path) {
            existingIntent = try FingerprintEvidenceReleaseContext.readStableRegularFile(intentURL, maximumBytes: 4096)
        } else { existingIntent = nil }
        try context.retireAuditAuthority(validateCandidate: {
            let after = try DirectUpdateCodeSignature.inspect(app, role: .manager)
            try after.requireReleaseCertificate()
            guard before == after, try targetCustody(app) == custody,
                  try FingerprintEvidenceReleaseContext.readStableRegularFile(
                    request.candidateManifestURL, maximumBytes: FingerprintEvidenceEnvelopeCodec.maximumManifestBytes) == manifest
            else { throw FingerprintEvidenceReleaseError.candidateMetadataMismatch }
            try validateInventory(app: app, manifest: manifest)
        }, existingIntent: existingIntent, confirmRetired: {
            try authority.isRetired(sessionID: binding.sessionID)
        }, persistIntent: { bytes in
            let intent = try ReservedFingerprintEvidenceEnrollmentOutput(url: intentURL)
            try intent.commit(bytes)
        })
    }

    private static func normalizedTmp(_ path: String) -> String {
        path.hasPrefix("/tmp/") ? "/private/tmp/" + path.dropFirst(5) : path
    }

    static func targetCustody(_ app: URL) throws -> [UInt64] {
        var info = stat()
        guard lstat(app.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid() else { throw FingerprintEvidenceReleaseError.unsafeManifest }
        return [UInt64(info.st_dev), UInt64(info.st_ino)]
    }

    /// Reproduce the fixed manifest inventory including modes and link targets.
    /// Only the existing stapling mutation path is omitted, never arbitrary
    /// paths supplied by the request. Unexpected entries and unsafe links fail.
    static func validateInventory(app: URL, manifest: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let expected = root["bundleInventory"] as? [[String: Any]],
              root["postPreparationMutablePaths"] as? [String] == ["Contents/CodeResources"],
              (1...20_000).contains(expected.count),
              let walk = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        else { throw FingerprintEvidenceReleaseError.invalidManifest }
        var rows = [[String: Any]]()
        func append(_ url: URL, relative: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid() else {
                throw FingerprintEvidenceReleaseError.unsafeManifest
            }
            if relative == "Contents/CodeResources" {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
                      info.st_size <= 1_048_576 else { throw FingerprintEvidenceReleaseError.unsafeManifest }
                return
            }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                rows.append(["bundlePath": relative, "kind": "directory", "mode": Int(info.st_mode & 0o7777)])
            case mode_t(S_IFLNK):
                // DirectoryEnumerator does not follow symlinks. Calling
                // skipDescendants here can skip the last real directory.
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                guard url.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/") else {
                    throw FingerprintEvidenceReleaseError.unsafeManifest
                }
                rows.append(["bundlePath": relative, "kind": "symlink", "target": target])
            case mode_t(S_IFREG):
                let hash = try stableHash(url, expectedSize: info.st_size)
                rows.append(["bundlePath": relative, "kind": "file", "mode": Int(info.st_mode & 0o7777),
                             "size": info.st_size, "sha256": hash])
            default: throw FingerprintEvidenceReleaseError.unsafeManifest
            }
        }
        try append(app, relative: ".")
        for case let url as URL in walk {
            let rootPath = normalizedTmp(app.path), path = normalizedTmp(url.path)
            guard path.hasPrefix(rootPath + "/") else { throw FingerprintEvidenceReleaseError.unsafeManifest }
            let relative = String(path.dropFirst(rootPath.count + 1))
            try append(url, relative: relative)
            guard rows.count <= 20_000 else { throw FingerprintEvidenceReleaseError.unsafeManifest }
        }
        rows.sort { ($0["bundlePath"] as! String) < ($1["bundlePath"] as! String) }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: rows, options: options) == JSONSerialization.data(withJSONObject: expected, options: options) else {
            throw FingerprintEvidenceReleaseError.candidateMetadataMismatch
        }
    }

    private static func stableHash(_ url: URL, expectedSize: off_t) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FingerprintEvidenceReleaseError.unsafeManifest }
        defer { _ = close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size == expectedSize,
              (0...1_073_741_824).contains(before.st_size) else { throw FingerprintEvidenceReleaseError.unsafeManifest }
        var hash = SHA256(), bytes = [UInt8](repeating: 0, count: 65_536), count: off_t = 0
        while true {
            let n = read(fd, &bytes, bytes.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw FingerprintEvidenceReleaseError.unsafeManifest }
            if n == 0 { break }
            count += off_t(n)
            guard count <= before.st_size else { throw FingerprintEvidenceReleaseError.unsafeManifest }
            hash.update(data: bytes.prefix(n))
        }
        guard count == before.st_size, fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_nlink == after.st_nlink, before.st_size == after.st_size,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw FingerprintEvidenceReleaseError.unsafeManifest }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
