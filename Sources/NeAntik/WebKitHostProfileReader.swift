import Darwin
import Foundation

/// Read-only metadata boundary for the separately linked WebKit child.
/// The manager retains recovery and migration authority; a child refuses
/// ambiguous or pending metadata instead of repairing it during launch.
enum WebKitHostProfileReader {
    enum Failure: Error {
        case unavailable
        case unsupportedSchema
        case duplicateIdentity
    }

    private struct Document: Decodable {
        let schemaVersion: Int
        let profiles: [BrowserProfile]
    }

    static func requireNoPending(rootURL: URL) throws {
        let fd = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        var root = stat()
        guard fstat(fd, &root) == 0, root.st_uid == geteuid(),
              root.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw Failure.unavailable
        }
        var pending = stat()
        guard fstatat(fd, ".browser-data-restore-active", &pending, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else { throw Failure.unavailable }
    }

    static func profile(id: UUID, paths: AppPaths) throws -> BrowserProfile {
        try paths.withProfilesMetadataGuard {
            try paths.validatePrivateFile(paths.profilesFile)
            let fd = Darwin.open(paths.profilesFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(fd) }
            var info = stat()
            let maximum = 64 * 1_024 * 1_024
            guard fstat(fd, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == geteuid(), info.st_nlink == 1,
                  info.st_size >= 0, info.st_size <= maximum else { throw Failure.unavailable }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                .read(upToCount: maximum + 1) ?? Data()
            guard data.count <= maximum else { throw Failure.unavailable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profiles: [BrowserProfile]
            if data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == 0x7B {
                let document = try decoder.decode(Document.self, from: data)
                guard (1...5).contains(document.schemaVersion),
                      (document.schemaVersion >= 2 || !document.profiles.contains(where: { $0.engine == .webkit })),
                      (document.schemaVersion >= 3 || !document.profiles.contains(where: { $0.webKitMediaPolicy == .deny })),
                      (document.schemaVersion >= 4 || !document.profiles.contains(where: { $0.fontPolicy != .native })),
                      (document.schemaVersion >= 5 || !document.profiles.contains(where: { $0.webKitRuntimeGeneration != .system }))
                else { throw Failure.unsupportedSchema }
                profiles = document.profiles
            } else {
                let decoded = try decoder.decode([BrowserProfile].self, from: data)
                guard !decoded.contains(where: { $0.engine == .webkit || $0.fontPolicy != .native || $0.webKitRuntimeGeneration != .system })
                else { throw Failure.unsupportedSchema }
                profiles = decoded
            }
            guard profiles.count <= ProfileStorageLimits.maximumProfileCount else {
                throw Failure.unavailable
            }
            var seenIDs = Set<UUID>(), seenSeeds = Set<UInt32>()
            for profile in profiles {
                guard seenIDs.insert(profile.id).inserted,
                      seenSeeds.insert(profile.identity.runtimeSeed).inserted else {
                    throw Failure.duplicateIdentity
                }
            }
            guard let profile = profiles.first(where: { $0.id == id }) else {
                throw Failure.unavailable
            }
            return profile
        }
    }
}
