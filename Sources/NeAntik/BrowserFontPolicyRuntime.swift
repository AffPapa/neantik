import CryptoKit
import Darwin
import DirectUpdateCore
import Foundation

/// A local observation of the qualified runtime, never a user-supplied flag.
struct BrowserFontPolicyQualification: Hashable, Sendable {
    let runtimeDigest: String
    let sourceContractSHA256: String
    fileprivate init() {
        runtimeDigest = BrowserFontPolicyRuntime.runtimeDigest
        sourceContractSHA256 = BrowserFontPolicyRuntime.sourceContractSHA256
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

    /// Pure comparison only. It cannot manufacture a launch qualification.
    static func acceptsMeasurement(digest: String, entries: Int, bytes: Int64,
                                   machoCount: Int) -> Bool {
        digest == runtimeDigest && entries == self.entries &&
            bytes == regularBytes && machoCount == self.machoCount
    }

    static func inspect(executableURL: URL) -> BrowserFontPolicyQualification? {
        // Cheap rejection keeps ordinary/older runtimes on the existing startup
        // path. Full closure work is needed only for this exact signed successor.
        guard executableURL.lastPathComponent == "NeAntik Browser",
              executableURL.deletingLastPathComponent().lastPathComponent == "MacOS",
              executableURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              executableDigest(executableURL) == executableSHA256 else { return nil }
        let app = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        guard app.lastPathComponent == "NeAntik Browser.app",
              app.resolvingSymlinksInPath() == app else { return nil }
        do {
            _ = try DirectUpdateCodeSignature.inspect(app, role: .runtime)
            let measured = try DirectRuntimeClosure.measure(app, scope: "runtime",
                maximumEntries: entries, maximumBytes: regularBytes)
            guard acceptsMeasurement(digest: measured.digest, entries: measured.entries,
                bytes: measured.regularBytes, machoCount: measured.machoPaths.count) else { return nil }
            return BrowserFontPolicyQualification()
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
