import Darwin
import Foundation
import Security

/// Owned release-selected helper bytes, not a path supplied by an update/MCP.
/// Authentication and hashing are synchronous utility-worker operations only.
final package class DirectAssessmentHelper: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    package static let identifier = "app.neantik.update-assessment"
    package let url: URL, expectedCode: ProxyRelayExpectedCode
    private let parentURL: URL, parent: Int32, file: Int32
    private let parentIdentity: BackupIdentity, fileIdentity: BackupIdentity, sha256: String
    private let codeIdentifier: String, codeHash: Data, releaseCertificateRequired: Bool
    package var description: String { "DirectAssessmentHelper(<redacted>)" }
    package var customMirror: Mirror { Mirror(self, children: [:]) }
    private init(url: URL, sha256: String, cdHash: Data, identifier: String, requireReleaseCertificate: Bool = true) throws {
        guard cdHash.count == 20, sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw DirectAssessmentParentError.helper }
        let parentURL = url.deletingLastPathComponent(), parent = try BackupFS.directory(parentURL)
        var kept = false, file: Int32 = -1
        defer { if !kept { if file >= 0 { close(file) }; close(parent) } }
        let parentIdentity = try BackupFS.identity(parent)
        guard parentIdentity.mode & 0o7022 == 0 else { throw DirectAssessmentParentError.helper }
        file = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw DirectAssessmentParentError.helper }
        let identity = try BackupFS.identity(file); try identity.validateFile(device: parentIdentity.device)
        guard identity.size >= 32, identity.size <= 16 * 1_024 * 1_024, identity.mode & 0o7022 == 0,
              identity.mode & 0o100 != 0, try BackupFS.entry(parent, url.lastPathComponent) == identity,
              DirectUpdateCodeSignature.admitsARM64Header(try BackupFS.read(file, at: 0, count: 32)),
              try BackupFS.hash(file, size: identity.size) == sha256 else { throw DirectAssessmentParentError.helper }
        try Self.noACLOrFlags(parent); try Self.noACLOrFlags(file)
        let pin = try ProxyRelayExpectedCode.qualifiedPin(at: url, expectedIdentifier: identifier, expectedTeamIdentifier: DirectUpdateCodeSignature.team, expectedCDHash: cdHash)
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], info[kSecCodeInfoUnique as String] as? Data == cdHash, let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              CFGetTypeID(flags) != CFBooleanGetTypeID(), flags.uint32Value & 0x10002 == 0x10000,
              let date = info[kSecCodeInfoTimestamp as String] as? Date, date.timeIntervalSince1970.isFinite,
              info[kSecCodeInfoDigestAlgorithm as String] as? Int == 2,
              info[kSecCodeInfoEntitlementsDict as String] == nil || (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?.isEmpty == true
        else { throw DirectAssessmentParentError.helper }
        if requireReleaseCertificate {
            guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
                  let leaf = certificates.first, DirectUpdateDeveloperIdentity.matches(SecCertificateCopyData(leaf) as Data) else {
                throw DirectAssessmentParentError.helper
            }
        }
        self.url = url; self.parentURL = parentURL; self.parent = parent; self.file = file
        self.parentIdentity = parentIdentity; fileIdentity = identity; self.sha256 = sha256; expectedCode = pin
        codeIdentifier = identifier; codeHash = cdHash; releaseCertificateRequired = requireReleaseCertificate
        kept = true
    }
    deinit { close(file); close(parent) }
    package static func packaged(in qualifiedInstalledApp: URL, releasePayloadSHA256: String, releaseCDHash: Data, modern: Bool = false) throws -> DirectAssessmentHelper {
        try .init(url: qualifiedInstalledApp.appendingPathComponent(modern ? "Contents/Helpers/v2/NeAntikUpdateAssessment" : "Contents/Helpers/NeAntikUpdateAssessment"),
                  sha256: releasePayloadSHA256, cdHash: releaseCDHash, identifier: identifier)
    }
    /// The owner uses the same bounded retained-file checks, but a different
    /// fixed identifier and path. A caller cannot select an arbitrary helper.
    package static func packagedOwner(in qualifiedInstalledApp: URL, releasePayloadSHA256: String, releaseCDHash: Data, modern: Bool = false) throws -> DirectAssessmentHelper {
        try .init(url: qualifiedInstalledApp.appendingPathComponent(modern ? "Contents/Helpers/v2/NeAntikUpdateOwner" : "Contents/Helpers/NeAntikUpdateOwner"),
                  sha256: releasePayloadSHA256, cdHash: releaseCDHash, identifier: "app.neantik.update-owner")
    }
    // These constructors are used only after the owner derives and validates
    // its fixed operation root. Their pins come from installed signed policy.
    package static func relocatedOwner(in operationRoot: URL, pin: DirectUpdateHelperPin) throws -> DirectAssessmentHelper {
        try .init(url: operationRoot.appendingPathComponent("Helpers/NeAntikUpdateOwner"),
                  sha256: pin.sha256, cdHash: pin.cdHash, identifier: "app.neantik.update-owner")
    }
    package static func relocatedAssessment(in operationRoot: URL, pin: DirectUpdateHelperPin) throws -> DirectAssessmentHelper {
        try .init(url: operationRoot.appendingPathComponent("Helpers/NeAntikUpdateAssessment"),
                  sha256: pin.sha256, cdHash: pin.cdHash, identifier: identifier)
    }
    #if DEBUG
    /// Only separately signed QA files, in a marked isolated UUID root. It
    /// accepts no production identifier or entitlements. Never shipping policy.
    package static func qualification(in root: URL, payloadSHA256: String) throws -> DirectAssessmentHelper {
        guard root.path.hasPrefix("/private/tmp/neantik-assessment-parent-"), root.deletingLastPathComponent().path == "/private/tmp",
              try String(contentsOf: root.appendingPathComponent("fixture.marker"), encoding: .utf8) == "isolated-assessment-parent-qa\n" else { throw DirectAssessmentParentError.helper }
        let fd = try BackupFS.directory(root); defer { close(fd) }
        guard try BackupFS.identity(fd).mode & 0o777 == 0o700 else { throw DirectAssessmentParentError.helper }
        let url = root.appendingPathComponent("Helpers/NeAntikUpdateAssessment")
        var code: SecStaticCode?, dictionary: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let hash = (dictionary as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw DirectAssessmentParentError.helper }
        return try .init(url: url, sha256: payloadSHA256, cdHash: hash,
                         identifier: "app.neantik.update-assessment-qa", requireReleaseCertificate: false)
    }
    #endif
    package func validate() throws {
        try BackupFS.validateDirectoryPath(parentURL, parentIdentity)
        guard try BackupFS.identity(parent).sameObject(parentIdentity),
              try BackupFS.identity(parent).mode & 0o7022 == 0,
              try BackupFS.identity(file) == fileIdentity, try BackupFS.entry(parent, url.lastPathComponent) == fileIdentity,
              try BackupFS.hash(file, size: fileIdentity.size) == sha256 else { throw DirectAssessmentParentError.helper }
        try Self.noACLOrFlags(parent); try Self.noACLOrFlags(file)
        guard try BackupFS.identity(parent).mode & 0o7022 == 0, try BackupFS.identity(file) == fileIdentity, try BackupFS.entry(parent, url.lastPathComponent) == fileIdentity else { throw DirectAssessmentParentError.helper }
    }
    /// Copies only this already authenticated retained file. The destination
    /// is an exclusive regular file under a retained private directory, never
    /// a manifest-selected executable. A fresh signature capture binds the copy.
    package func relocate(to directory: URL) throws -> DirectAssessmentHelper {
        try validate()
        let fd = try BackupFS.directory(directory); defer { close(fd) }
        let identity = try BackupFS.identity(fd)
        guard identity.mode & 0o7777 == 0o700 else { throw DirectAssessmentParentError.helper }
        try Self.noACLOrFlags(fd)
        let output = openat(fd, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o500)
        guard output >= 0 else { throw DirectAssessmentParentError.helper }; defer { close(output) }
        let initial = try BackupFS.identity(output); try initial.validateFile(device: identity.device)
        var offset: Int64 = 0
        while offset < fileIdentity.size {
            let count = Int(min(Int64(DirectFileIOLimits.hashChunkBytes), fileIdentity.size - offset))
            let bytes = try BackupFS.read(file, at: offset, count: count)
            guard bytes.count == count else { throw DirectAssessmentParentError.helper }
            try BackupFS.write(output, bytes, at: offset); offset += Int64(count)
        }
        guard fsync(output) == 0, fsync(fd) == 0,
              try BackupFS.identity(output).sameObject(initial),
              try BackupFS.entry(fd, url.lastPathComponent) == BackupFS.identity(output) else { throw DirectAssessmentParentError.helper }
        try validate(); try BackupFS.validateDirectoryPath(directory, identity)
        guard try BackupFS.identity(fd).mode & 0o7777 == 0o700 else { throw DirectAssessmentParentError.helper }
        return try .init(url: directory.appendingPathComponent(url.lastPathComponent), sha256: sha256,
                         cdHash: codeHash, identifier: codeIdentifier, requireReleaseCertificate: releaseCertificateRequired)
    }
    package static func validatePrivateDirectory(_ descriptor: Int32) throws {
        let identity = try BackupFS.identity(descriptor)
        guard identity.directory, identity.uid == geteuid(), identity.mode & 0o7777 == 0o700 else { throw DirectAssessmentParentError.helper }
        try noACLOrFlags(descriptor)
    }
    private static func noACLOrFlags(_ fd: Int32) throws {
        var stat = Darwin.stat(); guard fstat(fd, &stat) == 0, stat.st_flags == 0 else { throw DirectAssessmentParentError.helper }
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { guard errno == ENOENT else { throw DirectAssessmentParentError.helper }; return }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }; var entry: acl_entry_t?; errno = 0
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL, entry == nil else { throw DirectAssessmentParentError.helper }
    }
}
