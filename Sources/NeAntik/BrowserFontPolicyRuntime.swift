import CryptoKit
import Darwin
import DirectUpdateCore
import Foundation

/// A local observation of the qualified runtime, never a user-supplied flag.
struct BrowserFontPolicyQualification: Hashable, Sendable {
    let runtimeDigest: String
    let sourceContractSHA256: String
    fileprivate init(record: BrowserFontPolicyRuntime.Record) {
        runtimeDigest = record.runtimeDigest
        sourceContractSHA256 = record.sourceContractSHA256
    }
}

enum BrowserFontPolicyRuntime {
    // Independent policy: do not rewrite historical updater/runtime pins.
    // Source/build/sign and headed evidence: font-variation-headed-development.json.
    static let version = "156.0.8078.12"
    static let executableSHA256 = "27d0378671dd946f2b19c518f928a60a44b19ae0f97552569adb3eecc7e95c6c"
    static let runtimeDigest = "f0bd944a15e57476f7f2d78ea8df8f743dd9d7dbd1647c69c8e89d5754485b80"
    static let entries = 948
    static let regularBytes: Int64 = 411_230_673
    static let machoCount = 16
    static let sourceContractSHA256 = "5c6f00023ed4f4c63ed6f585544a5f61d3e239f640a56e1c53f058170d2e038d"

    /// One complete, source-selected capability. A caller cannot construct a
    /// qualification from these scalars; inspect still measures signed files.
    struct Record: Hashable, Sendable {
        let executableSHA256: String, runtimeDigest: String, sourceContractSHA256: String
        let entries: Int, regularBytes: Int64, machoCount: Int
        fileprivate init(update: DirectUpdateRuntimeRecord, sourceContract: String) {
            executableSHA256 = update.executableDigest
            runtimeDigest = update.runtimeDigest
            sourceContractSHA256 = sourceContract
            entries = update.runtimeEntries
            regularBytes = update.runtimeBytes
            machoCount = 16
        }
    }

    // Security source/build/sign and one configured page/worker smoke are
    // recorded separately; predecessor hashes and evidence stay unchanged.
    static let supportedRecords: [Record] = [
        Record(update: .fontSystemV1, sourceContract: sourceContractSHA256),
        Record(update: .fontSystemSecurity20261015V1,
               sourceContract: "5da10213b79c97a4bc3b13a0fd6af5e26d6034179bcdbe160bd244463a06f903"),
        Record(update: .componentCompletionV1,
               sourceContract: "a7e6ee9d61543784d74d4b8b1ee0aaa155dd4b97db8bb30aaf27e239486fb10e")
    ]

    /// Pure comparison only. It cannot manufacture a launch qualification.
    static func acceptsMeasurement(digest: String, entries: Int, bytes: Int64,
                                   machoCount: Int) -> Bool {
        acceptsMeasurement(digest: digest, entries: entries, bytes: bytes,
                           machoCount: machoCount, record: supportedRecords[0])
    }

    static func acceptsMeasurement(digest: String, entries: Int, bytes: Int64,
                                   machoCount: Int, record: Record) -> Bool {
        digest == record.runtimeDigest && entries == record.entries &&
            bytes == record.regularBytes && machoCount == record.machoCount
    }

    static func inspect(executableURL: URL) -> BrowserFontPolicyQualification? {
        // Cheap rejection keeps ordinary/older runtimes on the existing startup
        // path. Full closure work is needed only for this exact signed successor.
        guard executableURL.lastPathComponent == "NeAntik Browser",
              executableURL.deletingLastPathComponent().lastPathComponent == "MacOS",
              executableURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              let observedExecutable = executableDigest(executableURL),
              let record = supportedRecords.first(where: {
                  $0.executableSHA256 == observedExecutable
              }) else { return nil }
        let app = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        guard app.lastPathComponent == "NeAntik Browser.app",
              app.resolvingSymlinksInPath() == app else { return nil }
        do {
            _ = try DirectUpdateCodeSignature.inspect(app, role: .runtime)
            let measured = try DirectRuntimeClosure.measure(app, scope: "runtime",
                maximumEntries: record.entries, maximumBytes: record.regularBytes)
            guard acceptsMeasurement(digest: measured.digest, entries: measured.entries,
                bytes: measured.regularBytes, machoCount: measured.machoPaths.count, record: record) else { return nil }
            return BrowserFontPolicyQualification(record: record)
        } catch { return nil }
    }

    private static func executableDigest(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0, status.st_size <= 16 * 1_024 * 1_024 else { return nil }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            total += Int64(count)
            guard total <= status.st_size else { return nil }
            hash.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard total == status.st_size, fstat(fd, &after) == 0,
              after.st_dev == status.st_dev, after.st_ino == status.st_ino,
              after.st_size == status.st_size,
              after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec else { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
