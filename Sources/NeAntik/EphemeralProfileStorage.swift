import CryptoKit
import Darwin
import Foundation

struct EphemeralProfileStorageError: LocalizedError {
    var errorDescription: String? {
        "Очистка одноразового профиля не подтверждена. Его данные сохранены; запуск и изменение режима хранения заблокированы до безопасного завершения."
    }
}

/// Only an exclusively created profile can receive an issuance marker. Cleanup
/// never adopts an existing persistent directory. All destructive work requires
/// the caller's held process-maintenance authority plus both-path inventories.
enum EphemeralProfileStorage {
    static let markerName = ".neantik-ephemeral-owner-v1.json"
    static let journalName = ".neantik-ephemeral-cleanup-v1.json"
    enum Phase: String, Codable { case ready, active, clean, staged }
    struct Marker: Codable {
        let schemaVersion: Int
        let profileID: UUID
        var issuance: UUID
        var policySHA256: String
        let parent: BackupIdentity
        var root: BackupIdentity?
        var phase: Phase
        var stagedName: String?
    }
    struct Journal: Codable {
        let schemaVersion: Int
        let issuance: UUID
        let root: BackupIdentity
        let retiredName: String
        var phase: String
    }
    struct CreationMarker {
        let identity: BackupIdentity
        let bytes: Data
    }

    static func policyDigest(_ profile: BrowserProfile) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(profile.privacyPolicy))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func issueForExclusiveCreation(profile: BrowserProfile, parent: Int32, browser: Int32) throws -> CreationMarker {
        guard profile.privacyPolicy.retention == .ephemeral,
              profile.engine == .chromium,
              try BackupFS.names(browser).isEmpty else { throw EphemeralProfileStorageError() }
        let owner = try BackupFS.identity(parent), root = try BackupFS.identity(browser)
        try requirePrivate(owner); try requirePrivate(root)
        guard try BackupFS.entry(parent, "BrowserData")?.sameObject(root) == true else { throw EphemeralProfileStorageError() }
        let marker = Marker(schemaVersion: 1, profileID: profile.id, issuance: UUID(),
                            policySHA256: try policyDigest(profile), parent: owner,
                            root: root, phase: .ready, stagedName: nil)
        let data = try JSONEncoder().encode(marker)
        let fd = openat(parent, markerName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw EphemeralProfileStorageError() }
        defer { Darwin.close(fd) }
        try BackupFS.write(fd, data, at: 0)
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw BackupFS.posix() }
        return CreationMarker(identity: try BackupFS.identity(fd), bytes: data)
    }

    static func validateCreatedMarker(parent: Int32, expected: CreationMarker) throws {
        let (data, observed) = try readBytes(parent: parent, name: markerName)
        guard observed.sameObject(expected.identity), data == expected.bytes,
              try BackupFS.entry(parent, markerName)?.sameObject(observed) == true else { throw EphemeralProfileStorageError() }
    }

    static func removeCreatedMarker(parent: Int32, expected: CreationMarker) throws {
        try validateCreatedMarker(parent: parent, expected: expected)
        let (data, observed) = try readBytes(parent: parent, name: markerName)
        guard observed.sameObject(expected.identity), data == expected.bytes,
              try BackupFS.entry(parent, markerName)?.sameObject(observed) == true,
              unlinkat(parent, markerName, 0) == 0 else { throw EphemeralProfileStorageError() }
        guard fsync(parent) == 0 else { throw BackupFS.posix() }
    }

    static func pending(paths: AppPaths, profile: BrowserProfile) throws -> Bool {
        guard profile.privacyPolicy.retention == .ephemeral else { return false }
        let fd = try BackupFS.directory(OwnedProfileDirectory.platformPath(paths.profileDirectory(for: profile.id))); defer { Darwin.close(fd) }
        let marker: Marker = try read(parent: fd, name: markerName)
        try validate(marker, parent: fd, profile: profile, checkPolicy: false)
        if marker.phase == .active { return true }
        return try BackupFS.entry(fd, journalName) != nil
    }

    /// Called under the launch lease before exec. A prior active session must
    /// be cleaned; it must never become the next private session's initial state.
    static func prepareLaunch(paths: AppPaths, profile: BrowserProfile) throws {
        guard profile.privacyPolicy.retention == .ephemeral else { return }
        let parentURL = try OwnedProfileDirectory.platformPath(paths.profileDirectory(for: profile.id))
        let fd = try BackupFS.directory(parentURL); defer { Darwin.close(fd) }
        var marker: Marker = try read(parent: fd, name: markerName)
        try validate(marker, parent: fd, profile: profile, checkPolicy: false)
        guard marker.phase != .active, try BackupFS.entry(fd, journalName) == nil else { throw EphemeralProfileStorageError() }
        if marker.phase == .clean, let recreated = try BackupFS.entry(fd, "BrowserData") {
            // Ordinary profile-directory preparation may recreate the empty
            // container. Its parent already has exclusive ephemeral issuance;
            // a populated or substituted active session is never adopted.
            try requirePrivate(recreated)
            let empty = try BackupFS.directory(OwnedProfileDirectory.platformPath(paths.browserDataDirectory(for: profile.id)))
            defer { Darwin.close(empty) }
            guard try BackupFS.identity(empty).sameObject(recreated), try BackupFS.names(empty).isEmpty else { throw EphemeralProfileStorageError() }
            marker.issuance = UUID(); marker.root = recreated; marker.phase = .ready
            marker.policySHA256 = try policyDigest(profile)
            try save(marker, paths: paths, url: parentURL.appendingPathComponent(markerName))
        }
        if marker.phase == .clean {
            let generation = UUID(), name = ".neantik-ephemeral-prepared-" + generation.uuidString
            guard mkdirat(fd, name, 0o700) == 0 else { throw BackupFS.posix() }
            let staged = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard staged >= 0 else { throw EphemeralProfileStorageError() }; defer { Darwin.close(staged) }
            marker.issuance = generation; marker.root = try BackupFS.identity(staged)
            marker.policySHA256 = try policyDigest(profile); marker.phase = .staged; marker.stagedName = name
            try save(marker, paths: paths, url: parentURL.appendingPathComponent(markerName))
        }
        if marker.phase == .staged {
            guard let name = marker.stagedName, name == ".neantik-ephemeral-prepared-" + marker.issuance.uuidString,
                  let expected = marker.root else { throw EphemeralProfileStorageError() }
            if let staged = try BackupFS.entry(fd, name) {
                guard staged.sameObject(expected), try BackupFS.entry(fd, "BrowserData") == nil,
                      renameatx_np(fd, name, fd, "BrowserData", UInt32(RENAME_EXCL)) == 0 else { throw EphemeralProfileStorageError() }
            }
            guard try BackupFS.entry(fd, "BrowserData")?.sameObject(expected) == true else { throw EphemeralProfileStorageError() }
            marker.phase = .ready; marker.stagedName = nil
        }
        guard marker.phase == .ready, let expected = marker.root else { throw EphemeralProfileStorageError() }
        let data = try BackupFS.directory(OwnedProfileDirectory.platformPath(paths.browserDataDirectory(for: profile.id))); defer { Darwin.close(data) }
        guard try BackupFS.identity(data).sameObject(expected), try BackupFS.names(data).isEmpty else { throw EphemeralProfileStorageError() }
        marker.policySHA256 = try policyDigest(profile); marker.phase = .active
        try save(marker, paths: paths, url: parentURL.appendingPathComponent(markerName))
        guard fsync(fd) == 0 else { throw BackupFS.posix() }
    }

    /// The guard must validate the current metadata revision, held maintenance
    /// lease and absence of browser/relay for the ORIGINAL path. The second
    /// callback inspects the detached path too. Unknown always throws.
    static func clear(paths: AppPaths, profile: BrowserProfile,
                      validateAuthority: () throws -> Void,
                      requireAbsent: (URL) throws -> Void,
                      beforeUnlink: (() throws -> Void)? = nil) throws {
        guard profile.privacyPolicy.retention == .ephemeral else { throw EphemeralProfileStorageError() }
        try validateAuthority()
        let parentURL = try OwnedProfileDirectory.platformPath(paths.profileDirectory(for: profile.id))
        let parent = try BackupFS.directory(parentURL); defer { Darwin.close(parent) }
        var marker: Marker = try read(parent: parent, name: markerName)
        try validate(marker, parent: parent, profile: profile, checkPolicy: true)
        let original = paths.browserDataDirectory(for: profile.id)
        try requireAbsent(original)
        if marker.phase == .clean {
            // A crash may leave the final journal after all data was removed.
            if try BackupFS.entry(parent, journalName) != nil {
                let journal: Journal = try read(parent: parent, name: journalName)
                guard journal.schemaVersion == 1, journal.issuance == marker.issuance,
                      journal.phase == "removed",
                      journal.retiredName == ".neantik-ephemeral-retired-" + marker.issuance.uuidString,
                      try BackupFS.entry(parent, journal.retiredName) == nil else { throw EphemeralProfileStorageError() }
                guard unlinkat(parent, journalName, 0) == 0 else { throw BackupFS.posix() }
            }
            return
        }
        guard marker.phase == .active || marker.phase == .ready, let root = marker.root else { throw EphemeralProfileStorageError() }
        let name = ".neantik-ephemeral-retired-" + marker.issuance.uuidString
        let journalURL = parentURL.appendingPathComponent(journalName)
        var journal: Journal
        if try BackupFS.entry(parent, journalName) != nil {
            journal = try read(parent: parent, name: journalName)
            guard journal.schemaVersion == 1, journal.issuance == marker.issuance,
                  journal.root.sameObject(root), journal.retiredName == name,
                  ["prepared", "detached", "removing", "removed"].contains(journal.phase) else { throw EphemeralProfileStorageError() }
        } else {
            guard try BackupFS.entry(parent, "BrowserData")?.sameObject(root) == true,
                  try BackupFS.entry(parent, name) == nil else { throw EphemeralProfileStorageError() }
            journal = Journal(schemaVersion: 1, issuance: marker.issuance, root: root, retiredName: name, phase: "prepared")
            try save(journal, paths: paths, url: journalURL)
        }
        let retired = parentURL.appendingPathComponent(name)
        if journal.phase == "prepared" {
            if let current = try BackupFS.entry(parent, "BrowserData") {
                guard current.sameObject(root), try BackupFS.entry(parent, name) == nil,
                      renameatx_np(parent, "BrowserData", parent, name, UInt32(RENAME_EXCL)) == 0 else { throw EphemeralProfileStorageError() }
            }
            guard try BackupFS.entry(parent, name)?.sameObject(root) == true else { throw EphemeralProfileStorageError() }
            journal.phase = "detached"; try save(journal, paths: paths, url: journalURL)
        }
        try validateAuthority(); try requireAbsent(original); try requireAbsent(retired)
        if let actual = try BackupFS.entry(parent, name) {
            guard actual.sameObject(root) else { throw EphemeralProfileStorageError() }
            // Chromium singleton links are unlinked as entries, never followed.
            let fd = try BackupFS.directory(retired); defer { Darwin.close(fd) }
            for item in ["SingletonLock", "SingletonCookie", "SingletonSocket"] {
                if let entry = try BackupFS.entry(fd, item), entry.mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    guard entry.uid == geteuid(), entry.device == root.device,
                          try BackupFS.entry(fd, item) == entry, unlinkat(fd, item, 0) == 0 else { throw EphemeralProfileStorageError() }
                }
            }
            let tree = try BackupTree.capture(retired, checksCancellation: false, includeHashes: false, excludeRootTransients: false)
            defer { tree.close() }
            try tree.validateAll(); try validateAuthority(); try requireAbsent(original); try requireAbsent(retired)
            try beforeUnlink?()
            journal.phase = "removing"; try save(journal, paths: paths, url: journalURL)
            try tree.validateAll(); try validateAuthority(); try requireAbsent(original); try requireAbsent(retired)
            try tree.removeContents()
            guard try BackupFS.entry(parent, name)?.sameObject(root) == true,
                  unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw EphemeralProfileStorageError() }
        } else {
            guard journal.phase == "removing" || journal.phase == "removed" else { throw EphemeralProfileStorageError() }
        }
        journal.phase = "removed"; try save(journal, paths: paths, url: journalURL)
        marker.phase = .clean; marker.root = nil; marker.stagedName = nil
        try save(marker, paths: paths, url: parentURL.appendingPathComponent(markerName))
        guard unlinkat(parent, journalName, 0) == 0, fsync(parent) == 0 else { throw BackupFS.posix() }
    }

    private static func validate(_ marker: Marker, parent: Int32, profile: BrowserProfile, checkPolicy: Bool) throws {
        let actual = try BackupFS.identity(parent); try requirePrivate(actual)
        let expectedPolicy = try policyDigest(profile)
        guard marker.schemaVersion == 1, marker.profileID == profile.id,
              actual.sameObject(marker.parent), profile.privacyPolicy.retention == .ephemeral,
              !checkPolicy || marker.policySHA256 == expectedPolicy else { throw EphemeralProfileStorageError() }
    }
    private static func requirePrivate(_ identity: BackupIdentity) throws {
        guard identity.directory, identity.uid == geteuid(), identity.mode & 0o077 == 0 else { throw EphemeralProfileStorageError() }
    }
    private static func readBytes(parent: Int32, name: String) throws -> (Data, BackupIdentity) {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw EphemeralProfileStorageError() }; defer { Darwin.close(fd) }
        let identity = try BackupFS.identity(fd); try identity.validateFile(device: try BackupFS.identity(parent).device)
        guard identity.size > 0, identity.size <= 65_536, identity.mode & 0o077 == 0 else { throw EphemeralProfileStorageError() }
        let bytes = try BackupFS.read(fd, at: 0, count: Int(identity.size))
        guard try BackupFS.identity(fd) == identity, try BackupFS.entry(parent, name) == identity else { throw EphemeralProfileStorageError() }
        return (bytes, identity)
    }
    private static func read<T: Decodable>(parent: Int32, name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: readBytes(parent: parent, name: name).0)
    }
    private static func save<T: Encodable>(_ value: T, paths: AppPaths, url: URL) throws {
        try paths.writePrivateFile(JSONEncoder().encode(value), to: url)
    }
}
