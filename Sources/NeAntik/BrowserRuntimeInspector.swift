import CryptoKit
import Foundation
import Security

struct BrowserRuntimeInspection: Equatable, Hashable, Sendable {
    let version: String?
    let architectures: [String]
    let codeSignatureValid: Bool?
    let executableSHA256: String?
    let frameworkSHA256: String?

    init(
        version: String?,
        architectures: [String],
        codeSignatureValid: Bool?,
        executableSHA256: String? = nil,
        frameworkSHA256: String? = nil
    ) {
        self.version = version
        self.architectures = architectures
        self.codeSignatureValid = codeSignatureValid
        self.executableSHA256 = executableSHA256
        self.frameworkSHA256 = frameworkSHA256
    }

    var supportsAppleSilicon: Bool {
        architectures.contains("arm64")
    }
}

enum BrowserRuntimeInspector {
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    static func inspect(executableURL: URL) -> BrowserRuntimeInspection {
        let frameworkURL = frameworkBinary(for: executableURL)
        return BrowserRuntimeInspection(
            version: bundleVersion(for: executableURL),
            architectures: machOArchitectures(at: executableURL),
            codeSignatureValid: codeSignatureValidity(
                for: executableURL
            ),
            executableSHA256: sha256(of: executableURL),
            frameworkSHA256: frameworkURL.flatMap(sha256)
        )
    }

    private static func bundleVersion(for executableURL: URL) -> String? {
        guard let bundleURL = appBundleURL(for: executableURL) else {
            return nil
        }
        let plistURL = bundleURL.appendingPathComponent(
            "Contents/Info.plist"
        )
        guard let data = try? Data(contentsOf: plistURL),
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
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(),
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
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent.hasSuffix(" Framework"),
                  (try? candidate.resourceValues(
                    forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true
            else {
                continue
            }
            return candidate
        }
        return nil
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
