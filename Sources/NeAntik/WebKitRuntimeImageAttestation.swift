import CryptoKit
import Darwin
import Foundation

/// Proves that this process loaded the exact WebKit binary sealed into its
/// helper bundle. A manifest or `otool` load command alone does not prove which
/// framework dyld selected at runtime.
enum WebKitRuntimeImageAttestation {
    static let pinKey = "NeAntikWebKitRuntimeV1"

    /// QA diagnosis only. The counts contain no image paths or profile data.
    struct StartupCheckpoint: Equatable {
        let systemAtEntry: Int
        let systemAfterAppKit: Int
    }

    enum Failure: Error, Equatable {
        case malformedPin
        case unsafeBundle
        case missingRuntimeImage
        case ambiguousRuntimeImage
        case wrongRuntimeImage
        case runtimeHashMismatch
        case unsupportedOperatingSystem
    }

    /// QA-only failure payload: bounded counts, never image paths. Nine means
    /// nine or more. This diagnoses multiplicity without relaxing attestation.
    struct AmbiguousImageDiagnostic: Error, Equatable {
        var code: String

        init(imagePaths: [String], bundleURL: URL,
             checkpoint: StartupCheckpoint? = nil) {
            let expected = bundleURL.appendingPathComponent(
                "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")
                .resolvingSymlinksInPath().standardizedFileURL.path
            let system = "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"
            var owned = 0, shared = 0, other = 0
            for path in runtimeCandidates(imagePaths) {
                let canonical = URL(fileURLWithPath: path)
                    .resolvingSymlinksInPath().standardizedFileURL.path
                if canonical == expected { owned += 1 }
                else if canonical == system { shared += 1 }
                else { other += 1 }
            }
            code = "ambiguousImages-owned\(min(owned, 9))-system\(min(shared, 9))-other\(min(other, 9))"
            if let checkpoint {
                code += "-entry\(min(checkpoint.systemAtEntry, 9))-appkit\(min(checkpoint.systemAfterAppKit, 9))"
            }
        }
    }

    struct Pin: Equatable, Sendable {
        let webKitSHA256: String
        let minimumOSVersion: String

        init(propertyList value: Any?) throws {
            guard let object = value as? [String: Any],
                  Set(object.keys) == Set(["schemaVersion", "webKitSHA256", "minimumOSVersion"]),
                  object["schemaVersion"] as? Int == 2,
                  let sha256 = object["webKitSHA256"] as? String,
                  sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let minimumOSVersion = object["minimumOSVersion"] as? String,
                  minimumOSVersion.range(of: "^\\d+\\.\\d+\\.\\d+$", options: .regularExpression) != nil
            else { throw Failure.malformedPin }
            webKitSHA256 = sha256
            self.minimumOSVersion = minimumOSVersion
        }

        func supports(_ current: OperatingSystemVersion) -> Bool {
            Self.supports(minimumOSVersion, current: current)
        }

        static func supports(_ minimum: String, current: OperatingSystemVersion) -> Bool {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 3 else { return false }
            let required = OperatingSystemVersion(majorVersion: parts[0],
                minorVersion: parts[1], patchVersion: parts[2])
            if current.majorVersion != required.majorVersion {
                return current.majorVersion > required.majorVersion
            }
            if current.minorVersion != required.minorVersion {
                return current.minorVersion > required.minorVersion
            }
            return current.patchVersion >= required.patchVersion
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
    static func attestCurrentProcess(
        bundleURL: URL = Bundle.main.bundleURL,
        startupCheckpoint: StartupCheckpoint? = nil
    ) throws -> VerifiedImage {
        guard let info = Bundle(url: bundleURL)?.infoDictionary else {
            throw Failure.unsafeBundle
        }
        let pin = try Pin(propertyList: info[pinKey])
        guard pin.supports(ProcessInfo.processInfo.operatingSystemVersion) else {
            throw Failure.unsupportedOperatingSystem
        }
        let images = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return String(cString: name)
        }
        let url: URL
        do {
            url = try verify(imagePaths: images, bundleURL: bundleURL,
                             expectedSHA256: pin.webKitSHA256)
        } catch Failure.ambiguousRuntimeImage {
            #if DEBUG || NEANTIK_WEBKIT_PROXY_QUALIFICATION
            throw AmbiguousImageDiagnostic(imagePaths: images, bundleURL: bundleURL,
                                           checkpoint: startupCheckpoint)
            #else
            throw Failure.ambiguousRuntimeImage
            #endif
        }
        return VerifiedImage(url: url, sha256: pin.webKitSHA256)
    }

    /// Count only Apple's system WebKit image at an early host milestone.
    /// A change between milestones identifies the loading phase without
    /// exposing dyld paths or weakening the final uniqueness check.
    static func systemImageCount() -> Int {
        let system = URL(fileURLWithPath:
            "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit")
            .resolvingSymlinksInPath().standardizedFileURL.path
        return (0..<_dyld_image_count()).reduce(into: 0) { count, index in
            guard let name = _dyld_get_image_name(index) else { return }
            let path = URL(fileURLWithPath: String(cString: name))
                .resolvingSymlinksInPath().standardizedFileURL.path
            if path == system { count += 1 }
        }
    }

    static func pin(in hostBundleURL: URL) throws -> Pin {
        guard hostBundleURL.isFileURL, hostBundleURL.pathExtension == "app",
              isPhysicalDirectory(hostBundleURL),
              isPhysicalDirectory(hostBundleURL.appendingPathComponent("Contents", isDirectory: true)),
              let info = Bundle(url: hostBundleURL)?.infoDictionary else {
            throw Failure.unsafeBundle
        }
        return try Pin(propertyList: info[pinKey])
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

        let candidates = runtimeCandidates(imagePaths)
        guard !candidates.isEmpty else { throw Failure.missingRuntimeImage }
        guard candidates.count == 1 else { throw Failure.ambiguousRuntimeImage }

        let actual = URL(fileURLWithPath: candidates[0]).resolvingSymlinksInPath().standardizedFileURL
        let expectedPhysical = expected.resolvingSymlinksInPath().standardizedFileURL
        guard actual == expectedPhysical else { throw Failure.wrongRuntimeImage }
        guard sha256(expected) == expectedSHA256 else { throw Failure.runtimeHashMismatch }
        return actual
    }

    private static func runtimeCandidates(_ paths: [String]) -> [String] {
        paths.filter { path in
            URL(fileURLWithPath: path).standardizedFileURL.pathComponents.suffix(4)
                == ["WebKit.framework", "Versions", "A", "WebKit"]
        }
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
