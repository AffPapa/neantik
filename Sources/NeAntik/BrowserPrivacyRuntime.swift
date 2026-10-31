import Foundation
import DirectUpdateCore

/// A measured signed engine, never a caller-supplied capability bit.
struct BrowserPrivacyQualification: Hashable, Sendable {
    let runtimeDigest: String
    let sourceContractSHA256: String
    fileprivate init(_ record: BrowserPrivacyRuntime.Record) {
        runtimeDigest = record.runtimeDigest
        sourceContractSHA256 = record.sourceContractSHA256
    }
}

enum BrowserPrivacyRuntime {
    struct Record: Hashable, Sendable {
        let executableSHA256: String
        let runtimeDigest: String
        let sourceContractSHA256: String
        let entries: Int
        let regularBytes: Int64
        let machoCount: Int
    }
    // Source18/native-smoke-20261031.json records measured scopes and limits.
    // Whole signed-byte qualification is shared with the updater's reviewed
    // record; caller bits and downloaded manifests cannot add capabilities.
    static let records: [Record] = [
        .init(executableSHA256: DirectUpdatePrivacyRuntimePins.executableDigest,
              runtimeDigest: DirectUpdatePrivacyRuntimePins.runtimeDigest,
              sourceContractSHA256: DirectUpdatePrivacyRuntimePins.reportHashes["sourceContractSHA256"]!,
              entries: DirectUpdatePrivacyRuntimePins.runtimeEntries,
              regularBytes: DirectUpdatePrivacyRuntimePins.runtimeBytes,
              machoCount: DirectUpdatePrivacyRuntimePins.machoCount)
    ]

    static func inspect(executableURL: URL) -> BrowserPrivacyQualification? {
        guard !records.isEmpty,
              executableURL.lastPathComponent == "NeAntik Browser",
              executableURL.deletingLastPathComponent().lastPathComponent == "MacOS",
              executableURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              let hash = BrowserFontPolicyRuntime.executableDigest(executableURL),
              let record = records.first(where: { $0.executableSHA256 == hash }) else { return nil }
        do {
            let app = try OwnedProfileDirectory.platformPath(executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            guard app.lastPathComponent == "NeAntik Browser.app" else { return nil }
            _ = try DirectUpdateCodeSignature.inspect(app, role: .runtime)
            let measured = try DirectRuntimeClosure.measure(app, scope: "runtime", maximumEntries: record.entries, maximumBytes: record.regularBytes)
            guard measured.digest == record.runtimeDigest, measured.entries == record.entries,
                  measured.regularBytes == record.regularBytes, measured.machoPaths.count == record.machoCount else { return nil }
            return .init(record)
        } catch { return nil }
    }
}
