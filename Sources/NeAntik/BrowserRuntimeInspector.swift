import CryptoKit
import Darwin
import Foundation
import Security

struct BrowserRuntimeFileIdentity: Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

struct BrowserRuntimeInspection: Equatable, Hashable, Sendable {
    let version: String?
    let architectures: [String]
    let codeSignatureValid: Bool?
    let executableSHA256: String?
    let frameworkSHA256: String?
    let executableIdentity: BrowserRuntimeFileIdentity?

    init(
        version: String?,
        architectures: [String],
        codeSignatureValid: Bool?,
        executableSHA256: String? = nil,
        frameworkSHA256: String? = nil,
        executableIdentity: BrowserRuntimeFileIdentity? = nil
    ) {
        self.version = version
        self.architectures = architectures
        self.codeSignatureValid = codeSignatureValid
        self.executableSHA256 = executableSHA256
        self.frameworkSHA256 = frameworkSHA256
        self.executableIdentity = executableIdentity
    }

    var supportsAppleSilicon: Bool {
        architectures.contains("arm64")
    }
}

enum BrowserRuntimeInspector {
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let maximumInfoPlistBytes = 1 * 1_024 * 1_024

    static func inspect(executableURL: URL) -> BrowserRuntimeInspection {
        let frameworkURL = frameworkBinary(for: executableURL)
        return BrowserRuntimeInspection(
            version: bundleVersion(for: executableURL),
            architectures: machOArchitectures(at: executableURL),
            codeSignatureValid: codeSignatureValidity(
                for: executableURL
            ),
            executableSHA256: sha256(of: executableURL),
            frameworkSHA256: frameworkURL.flatMap(sha256),
            executableIdentity: fileIdentity(at: executableURL)
        )
    }

    static func inspectForStartup(
        executableURL: URL
    ) -> BrowserRuntimeInspection {
        BrowserRuntimeInspection(
            version: bundleVersion(for: executableURL),
            architectures: machOArchitectures(at: executableURL),
            codeSignatureValid: codeSignatureValidity(
                for: executableURL
            ),
            executableIdentity: fileIdentity(at: executableURL)
        )
    }

    static func inspectForLaunch(
        executableURL: URL
    ) -> BrowserRuntimeInspection {
        inspectForStartup(executableURL: executableURL)
    }

    private static func fileIdentity(
        at url: URL
    ) -> BrowserRuntimeFileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        else {
            return nil
        }
        return BrowserRuntimeFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: UInt64(max(0, value.st_size)),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }

    private static func bundleVersion(for executableURL: URL) -> String? {
        guard let bundleURL = appBundleURL(for: executableURL) else {
            return nil
        }
        let plistURL = bundleURL.appendingPathComponent(
            "Contents/Info.plist"
        )
        guard let data = try? AppPaths.readStableRegularFile(
                plistURL,
                maximumBytes: maximumInfoPlistBytes
              ),
              let object = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    private static func codeSignatureValidity(
        for executableURL: URL
    ) -> Bool? {
        let targetURL = appBundleURL(for: executableURL) ?? executableURL
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            targetURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return nil
        }
        let validationFlags = SecCSFlags(
            rawValue:
                kSecCSCheckAllArchitectures |
                kSecCSCheckNestedCode |
                kSecCSStrictValidate
        )
        return SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            nil
        ) == errSecSuccess
    }

    private static func appBundleURL(for executableURL: URL) -> URL? {
        var candidate = executableURL.deletingLastPathComponent()
        for _ in 0..<5 {
            if candidate.pathExtension.lowercased() == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func frameworkBinary(for executableURL: URL) -> URL? {
        guard let bundle = appBundleURL(for: executableURL) else {
            return nil
        }
        let root = bundle.appendingPathComponent(
            "Contents/Frameworks",
            isDirectory: true
        )
        let expectedFrameworkName =
            executableURL.lastPathComponent + " Framework"
        let expectedBundleName = expectedFrameworkName + ".framework"
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let frameworkBundles = children.filter { candidate in
            guard candidate.lastPathComponent == expectedBundleName,
                  let values = try? candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  )
            else { return false }
            return values.isDirectory == true &&
                values.isSymbolicLink != true
        }
        guard frameworkBundles.count == 1,
              let framework = frameworkBundles.first
        else { return nil }

        let versions = framework.appendingPathComponent(
            "Versions",
            isDirectory: true
        )
        guard let versionDirectories = try? FileManager.default
            .contentsOfDirectory(
                at: versions,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
        else { return nil }
        let binaries = versionDirectories.compactMap { version -> URL? in
            guard version.lastPathComponent != "Current",
                  let values = try? version.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { return nil }
            let binary = version.appendingPathComponent(
                expectedFrameworkName
            )
            guard let binaryValues = try? binary.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
            binaryValues.isRegularFile == true,
            binaryValues.isSymbolicLink != true
            else { return nil }
            return binary
        }
        guard binaries.count == 1 else { return nil }
        return binaries[0]
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func machOArchitectures(at url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 4_096)
        guard data.count >= 8 else { return [] }

        let littleMagic = readUInt32(data, at: 0, littleEndian: true)
        if littleMagic == 0xfeed_facf || littleMagic == 0xfeed_face {
            return architectureNames([
                readUInt32(data, at: 4, littleEndian: true)
            ])
        }

        let bigMagic = readUInt32(data, at: 0, littleEndian: false)
        if bigMagic == 0xfeed_facf || bigMagic == 0xfeed_face {
            return architectureNames([
                readUInt32(data, at: 4, littleEndian: false)
            ])
        }

        if bigMagic == 0xcafe_babe || bigMagic == 0xcafe_babf {
            let count = Int(readUInt32(data, at: 4, littleEndian: false))
            let stride = bigMagic == 0xcafe_babf ? 32 : 20
            var cpuTypes: [UInt32] = []
            for index in 0..<min(count, 32) {
                let offset = 8 + (index * stride)
                guard offset + 4 <= data.count else { break }
                cpuTypes.append(
                    readUInt32(data, at: offset, littleEndian: false)
                )
            }
            return architectureNames(cpuTypes)
        }

        return []
    }

    private static func architectureNames(_ cpuTypes: [UInt32]) -> [String] {
        var values: [String] = []
        for cpuType in cpuTypes {
            let name: String
            switch cpuType {
            case cpuTypeARM64:
                name = "arm64"
            case cpuTypeX86_64:
                name = "x86_64"
            default:
                name = String(format: "cpu-%08X", cpuType)
            }
            if !values.contains(name) {
                values.append(name)
            }
        }
        return values
    }

    private static func readUInt32(
        _ data: Data,
        at offset: Int,
        littleEndian: Bool
    ) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let bytes = data[offset..<(offset + 4)]
        if littleEndian {
            return bytes.enumerated().reduce(0) { result, entry in
                result | (UInt32(entry.element) << UInt32(entry.offset * 8))
            }
        }
        return bytes.reduce(0) { result, byte in
            (result << 8) | UInt32(byte)
        }
    }
}
