import CryptoKit
import Darwin
import Foundation

/// Proves that this process loaded the exact WebKit binary sealed into its
/// helper bundle. A manifest or `otool` load command alone does not prove which
/// framework dyld selected at runtime.
enum WebKitRuntimeImageAttestation {
    static let pinKey = "NeAntikWebKitRuntimeV1"

    enum Failure: Error, Equatable {
        case malformedPin
        case unsafeBundle
        case missingRuntimeImage
        case ambiguousRuntimeImage
        case wrongRuntimeImage
        case runtimeHashMismatch
    }

    struct Pin: Equatable, Sendable {
        let webKitSHA256: String

        init(propertyList value: Any?) throws {
            guard let object = value as? [String: Any],
                  Set(object.keys) == Set(["schemaVersion", "webKitSHA256"]),
                  object["schemaVersion"] as? Int == 1,
                  let sha256 = object["webKitSHA256"] as? String,
                  sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            else { throw Failure.malformedPin }
            webKitSHA256 = sha256
        }
    }

    struct VerifiedImage: Equatable, Sendable {
        let url: URL
        let sha256: String

        fileprivate init(url: URL, sha256: String) {
            self.url = url
            self.sha256 = sha256
        }
    }

    /// Read the helper's signed pin and inspect dyld's live image table. Call
    /// this before bootstrap reads profile metadata or opens a WebKit store.
    static func verifyCurrentProcess(bundleURL: URL = Bundle.main.bundleURL) throws -> URL {
        try attestCurrentProcess(bundleURL: bundleURL).url
    }

    /// Returns a capability for the exact embedded image only after the
    /// current process's signed bundle pin and dyld image table agree.
    static func attestCurrentProcess(bundleURL: URL = Bundle.main.bundleURL) throws -> VerifiedImage {
        guard let info = Bundle(url: bundleURL)?.infoDictionary else {
            throw Failure.unsafeBundle
        }
        let pin = try Pin(propertyList: info[pinKey])
        let images = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return String(cString: name)
        }
        let url = try verify(imagePaths: images, bundleURL: bundleURL,
                             expectedSHA256: pin.webKitSHA256)
        return VerifiedImage(url: url, sha256: pin.webKitSHA256)
    }

    /// Isolated contract used by tests and packaging verification. Both the
    /// loaded image and the pinned on-disk framework must resolve to the same
    /// physical bundle path; a system image or duplicate framework is refused.
    static func verify(imagePaths: [String], bundleURL: URL,
                       expectedSHA256: String) throws -> URL {
        guard expectedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              bundleURL.isFileURL, bundleURL.pathExtension == "app",
              isPhysicalDirectory(bundleURL),
              isPhysicalDirectory(bundleURL.appendingPathComponent("Contents", isDirectory: true)),
              isPhysicalDirectory(bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true))
        else { throw Failure.unsafeBundle }

        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let webKitRoot = frameworks.appendingPathComponent("WebKit.framework", isDirectory: true)
        let versions = webKitRoot.appendingPathComponent("Versions", isDirectory: true)
        let versionA = versions.appendingPathComponent("A", isDirectory: true)
        let expected = versionA.appendingPathComponent("WebKit")
        guard isPhysicalDirectory(webKitRoot), isPhysicalDirectory(versions),
              isPhysicalDirectory(versionA), isPhysicalFile(expected) else {
            throw Failure.unsafeBundle
        }

        let candidates = imagePaths.filter { path in
            let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            return components.suffix(4) == ["WebKit.framework", "Versions", "A", "WebKit"]
        }
        guard !candidates.isEmpty else { throw Failure.missingRuntimeImage }
        guard candidates.count == 1 else { throw Failure.ambiguousRuntimeImage }

        let actual = URL(fileURLWithPath: candidates[0]).resolvingSymlinksInPath().standardizedFileURL
        let expectedPhysical = expected.resolvingSymlinksInPath().standardizedFileURL
        guard actual == expectedPhysical else { throw Failure.wrongRuntimeImage }
        guard sha256(expected) == expectedSHA256 else { throw Failure.runtimeHashMismatch }
        return actual
    }

    #if DEBUG
    /// Test-only form that produces the same image capability after applying
    /// the path, bundle-layout and digest checks used by production. It is not
    /// present in Release, where capabilities come only from live dyld state.
    static func attest(imagePaths: [String], bundleURL: URL,
                       expectedSHA256: String) throws -> VerifiedImage {
        let url = try verify(imagePaths: imagePaths, bundleURL: bundleURL,
                             expectedSHA256: expectedSHA256)
        return VerifiedImage(url: url, sha256: expectedSHA256)
    }
    #endif

    private static func isPhysicalDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isPhysicalFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func sha256(_ url: URL) -> String? {
        guard isPhysicalFile(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 1 << 20) else { break }
                chunk = next
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
