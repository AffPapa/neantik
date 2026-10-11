import CryptoKit
import Darwin
import Foundation

enum DirectUpdateRuntimeProvenanceError: LocalizedError, Equatable {
    case unsupported, metadata, closure, architecture, changed, limit
    var errorDescription: String? {
        switch self {
        case .unsupported: "Для этого движка нет проверенного контракта обновления."
        case .metadata: "Сведения о происхождении движка не соответствуют проверенному выпуску."
        case .closure: "Файлы движка или доказательств отличаются от проверенного выпуска."
        case .architecture: "В обновлении найден неподдерживаемый исполняемый код."
        case .changed: "Файлы движка изменились во время проверки."
        case .limit: "Доказательства движка превышают допустимый размер."
        }
    }
}

/// A fixed, installed policy for the previously qualified, unchanged signed
/// M156 payload. Downloaded reports/manifests cannot select these pins. A new
/// runtime, a new nested signature or changed evidence needs a reviewed policy
/// update; a higher version number alone is never sufficient.
enum DirectUpdateRuntimePins {
    static let chromiumVersion = "156.0.8078.12"
    static let runtimeDigest = "176c65a1e1e069dcc36ef56ab6210753db7fc23527efc5bfbcb4afc5714a6efe"
    static let evidenceDigest = "f16a5b823ffaf05da6e0882ec89ef09684a0302c097aa39a6d85cd5384425b6b"
    static let reportDigest = "a367417b75da00de4655c6c0c1c03a1c0fe2ee5f30f38743c44549775c2f94a9"
    static let runtimeEntries = 946, evidenceEntries = 114
    static let runtimeBytes: Int64 = 411_177_721, evidenceBytes: Int64 = 49_527_984
    static let executable = "Contents/MacOS/NeAntik Browser"
    static let frameworkPrefix = "Contents/Frameworks/NeAntik Browser Framework.framework/Versions/156.0.8078.12/"
    static let framework = frameworkPrefix + "NeAntik Browser Framework"
    static let machoPaths: Set<String> = Set([
        executable, framework,
        "Libraries/libaperitif.dylib", "Libraries/libvk_swiftshader.dylib", "Libraries/libvulkan.dylib",
        "Helpers/app_mode_loader", "Helpers/chrome_crashpad_handler", "Helpers/web_app_shortcut_copier"
    ].map { $0.hasPrefix("Contents/") ? $0 : frameworkPrefix + $0 } + [
        "", " (Alerts)", " (GPU)", " (Renderer)", " (Aperitif)",
        " (Aperitif Alerts)", " (Aperitif GPU)", " (Aperitif Renderer)"
    ].map { frameworkPrefix + "Helpers/NeAntik Browser Helper\($0).app/Contents/MacOS/NeAntik Browser Helper\($0)" })
    static let reportHashes: [String: String] = [
        "sourceLockSHA256": "bca02c9e891ea4dfab36966202f1d5bf6824f327af683499d48a7722220ece68",
        "candidateLockSHA256": "bca02c9e891ea4dfab36966202f1d5bf6824f327af683499d48a7722220ece68",
        "sourceContractSHA256": "f8ee0079edb447343edb136b52ccba4aa00a91b77b61b0b8d88a62963d818757",
        "sourceProvenanceSHA256": "300cb51a52d169c1b41d5a5dce7f4c2ec62399de7b614db8c02720c2ebf28140",
        "neantikPatchManifestSHA256": "c79ee59b55b1ad474229313660c31c19fcc3b67051bca4f1da1e6098b0b69748",
        "appleDeviceTuplesManifestSHA256": "3c355a6a6708386c410c98cb9310a6f6e62ea5da065eb0faf0290b2a4a4ff6f2",
        "securityBaselineSHA256": "0e511d404b873a211db26cc2bcddb97ed317986f38a7d1be7e33036c9c9908a9",
        "fullFDObservationSHA256": "d6836d97a7a24d370663976063516306bfc646c826149f579a319fdb5578722c"
    ]
}

/// Scalar observation of exact bytes under current custody, not a source build,
/// notarization/Gatekeeper decision, installation capability or runtime test.
struct DirectUpdateRuntimeProvenanceObservation: Sendable, Equatable {
    let chromiumVersion: String
    let runtimeSHA256: String, evidenceSHA256: String
    let machoCount: Int
    fileprivate init(runtime: DirectRuntimeClosureMeasurement, evidence: DirectRuntimeClosureMeasurement) {
        chromiumVersion = DirectUpdateRuntimePins.chromiumVersion
        runtimeSHA256 = runtime.digest; evidenceSHA256 = evidence.digest
        machoCount = runtime.machoPaths.count
    }
}

struct DirectRuntimeClosureMeasurement: Sendable, Equatable {
    let digest: String, entries: Int, regularBytes: Int64
    let machoPaths: Set<String>
    let capturedReport: Data?
}

enum DirectUpdateRuntimeProvenance {
    static func inspectStage(_ stage: ExtractedUpdateApp) throws -> DirectUpdateRuntimeProvenanceObservation {
        try Task.checkCancellation()
        guard stage.archiveIntegrity.chromiumVersion == DirectUpdateRuntimePins.chromiumVersion else {
            throw DirectUpdateRuntimeProvenanceError.unsupported
        }
        // Separate custody scopes avoid re-entering the stage's nonrecursive
        // lock. Neither result confers installation authority.
        _ = try DirectUpdateCodeSignature.inspectStage(stage)
        return try stage.withValidatedApp { app in
            let resources = app.appendingPathComponent("Contents/Resources")
            let runtime = try DirectRuntimeClosure.measure(resources.appendingPathComponent("NeAntik Browser.app"),
                scope: "runtime", maximumEntries: DirectUpdateRuntimePins.runtimeEntries,
                maximumBytes: DirectUpdateRuntimePins.runtimeBytes)
            let evidence = try DirectRuntimeClosure.measure(resources.appendingPathComponent("NeAntikRuntimeEvidence"),
                scope: "evidence", maximumEntries: DirectUpdateRuntimePins.evidenceEntries,
                maximumBytes: DirectUpdateRuntimePins.evidenceBytes)
            try validateMeasurements(runtime, evidence)
            // Hash the very same bounded descriptor-read report bytes before
            // parsing. Unknown JSON, duplicate keys or altered scalar types
            // cannot pass the pinned byte-level report digest.
            guard let bytes = evidence.capturedReport,
                  BackupFS.hex(SHA256.hash(data: bytes)) == DirectUpdateRuntimePins.reportDigest,
                  let report = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw DirectUpdateRuntimeProvenanceError.metadata
            }
            try validateReport(report)
            try Task.checkCancellation()
            return .init(runtime: runtime, evidence: evidence)
        }
    }

    static func inspectStageAsynchronously(_ stage: ExtractedUpdateApp) async throws -> DirectUpdateRuntimeProvenanceObservation {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try inspectStage(stage) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation(); return result
        } onCancel: { worker.cancel() }
    }

    static func validateMeasurements(_ runtime: DirectRuntimeClosureMeasurement, _ evidence: DirectRuntimeClosureMeasurement) throws {
        guard runtime.digest == DirectUpdateRuntimePins.runtimeDigest,
              evidence.digest == DirectUpdateRuntimePins.evidenceDigest,
              runtime.entries == DirectUpdateRuntimePins.runtimeEntries,
              evidence.entries == DirectUpdateRuntimePins.evidenceEntries,
              runtime.regularBytes == DirectUpdateRuntimePins.runtimeBytes,
              evidence.regularBytes == DirectUpdateRuntimePins.evidenceBytes else {
            throw DirectUpdateRuntimeProvenanceError.closure
        }
        guard runtime.machoPaths == DirectUpdateRuntimePins.machoPaths, evidence.machoPaths.isEmpty else {
            throw DirectUpdateRuntimeProvenanceError.architecture
        }
    }

    /// Pure schema/policy tests do not manufacture provenance observations.
    static func validateReport(_ report: [String: Any]) throws {
        func integer(_ value: Any?, equals expected: Int) -> Bool {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
            return n.doubleValue == Double(expected)
        }
        let keys = Set(["schemaVersion", "chromiumVersion", "architecture", "buildArguments", "createdAt", "executable", "framework",
                        "codeSignature", "codeSignatureKind", "fingerprintProtocolStrings", "gpuMode", "machoCount",
                        "freshWholeSourceTreeObserved", "sourceEvidenceMode"] + Array(DirectUpdateRuntimePins.reportHashes.keys))
        guard Set(report.keys) == keys, integer(report["schemaVersion"], equals: 3),
              integer(report["machoCount"], equals: DirectUpdateRuntimePins.machoPaths.count),
              report["chromiumVersion"] as? String == DirectUpdateRuntimePins.chromiumVersion,
              report["architecture"] as? String == "arm64", report["gpuMode"] as? String == "metal",
              report["codeSignature"] as? String == "verified", report["codeSignatureKind"] as? String == "developer-id",
              report["fingerprintProtocolStrings"] as? String == "verified",
              report["sourceEvidenceMode"] as? String == "executed-final9-preserved-build-and-current-packaging-inputs",
              let observed = report["freshWholeSourceTreeObserved"] as? NSNumber,
              CFGetTypeID(observed) == CFBooleanGetTypeID(), !observed.boolValue,
              let created = report["createdAt"] as? String, created == "2026-10-10T07:09:29.793627Z",
              DirectUpdateRuntimePins.reportHashes.allSatisfy({ report[$0.key] as? String == $0.value }),
              let args = report["buildArguments"] as? [String: String],
              args == ["sha256": "b32623308042c6b3b86f14ce9635ccc9abdc290148ce596c1e4f4a43ffde9a01"],
              let executable = report["executable"] as? [String: String],
              executable == ["path": DirectUpdateRuntimePins.executable, "sha256": "1b1e460981efe56aa8f4825b7f4f7c6f2e8cc51e244d718ba300db78ac872ff0"],
              let framework = report["framework"] as? [String: String],
              framework == ["path": DirectUpdateRuntimePins.framework, "sha256": "87374f1072a83850ea20da83897eac86de6d1357abcff0f0fad87dabd836e815"] else {
            throw DirectUpdateRuntimeProvenanceError.metadata
        }
    }
}

enum DirectRuntimeClosurePoint: Sendable {
    case opened(String), chunk(String, Int64), beforeEntryValidation(String)
}

/// Captured no-follow descriptor walk of actual files, including every directory
/// and exact symlink spelling. Does not follow symlinks or parse large evidence.
/// The enclosing stage seal validates namespace and custody before/after.
enum DirectRuntimeClosure {
    private struct Record {
        let path: String, bytes: Data
    }
    static func measure(_ url: URL, scope: String, maximumEntries: Int, maximumBytes: Int64,
                        fault: (@Sendable (DirectRuntimeClosurePoint) throws -> Void)? = nil) throws -> DirectRuntimeClosureMeasurement {
        guard ["runtime", "evidence"].contains(scope), (1...2_000).contains(maximumEntries),
              (0...1_073_741_824).contains(maximumBytes) else { throw DirectUpdateRuntimeProvenanceError.limit }
        try Task.checkCancellation()
        let fd = try BackupFS.directory(url); defer { Darwin.close(fd) }
        let rootIdentity = try BackupFS.identity(fd)
        var records: [Record] = [], total: Int64 = 0, machoPaths: Set<String> = []
        var captured: [String: BackupIdentity] = [:]
        var capturedReport: Data?
        func add(_ path: String, _ bytes: Data) throws {
            guard records.count < maximumEntries else { throw DirectUpdateRuntimeProvenanceError.limit }
            records.append(.init(path: path, bytes: bytes))
        }
        func prefix(_ path: String, _ kind: UInt8) throws -> Data {
            guard path.utf8.count <= 1_024, path.split(separator: "/").count <= 32 else {
                throw DirectUpdateRuntimeProvenanceError.limit
            }
            var bytes = Data(); bytes.appendSizedUTF8(path); bytes.append(kind); return bytes
        }
        func walk(_ directory: Int32, _ path: String) throws {
            try Task.checkCancellation()
            let identity = try BackupFS.identity(directory)
            guard identity.directory, identity.uid == geteuid(), identity.mode & 0o7000 == 0 else {
                throw DirectUpdateRuntimeProvenanceError.changed
            }
            var record = try prefix(path, 68); record.appendBE(UInt32(identity.mode & 0o777)); try add(path, record)
            let names = try BackupFS.names(directory)
            for name in names {
                try Task.checkCancellation()
                guard records.count < maximumEntries,
                      let before = try BackupFS.entry(directory, name), before.uid == geteuid(),
                      before.device == rootIdentity.device, before.mode & 0o7000 == 0 else {
                    throw DirectUpdateRuntimeProvenanceError.changed
                }
                // ZIP namespace admission uses NFC. APFS enumeration can return
                // decomposed names even when extraction wrote NFC bytes. Keep
                // admitted path spelling NFC; never normalize link targets.
                let canonicalName = name.precomposedStringWithCanonicalMapping
                let relative = path.isEmpty ? canonicalName : path + "/" + canonicalName
                guard captured.updateValue(before, forKey: relative) == nil else {
                    throw DirectUpdateRuntimeProvenanceError.changed
                }
                if before.directory {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw DirectUpdateRuntimeProvenanceError.changed }
                    defer { Darwin.close(child) }
                    guard try BackupFS.identity(child) == before else { throw DirectUpdateRuntimeProvenanceError.changed }
                    try walk(child, relative)
                    guard try BackupFS.identity(child) == before else { throw DirectUpdateRuntimeProvenanceError.changed }
                } else if before.mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                    try before.validateFile(device: rootIdentity.device)
                    guard before.size >= 0, before.size <= maximumBytes - total else { throw DirectUpdateRuntimeProvenanceError.limit }
                    total += before.size
                    let child = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { throw DirectUpdateRuntimeProvenanceError.changed }
                    defer { Darwin.close(child) }
                    guard try BackupFS.identity(child) == before else { throw DirectUpdateRuntimeProvenanceError.changed }
                    try fault?(.opened(relative)); try Task.checkCancellation()
                    var hash = SHA256(), offset: Int64 = 0, report: Data?
                    if scope == "evidence", relative == "runtime-verification.json" {
                        guard (1...65_536).contains(before.size) else { throw DirectUpdateRuntimeProvenanceError.limit }
                        report = Data()
                    }
                    let header = try BackupFS.read(child, at: 0, count: Int(min(32, before.size)))
                    if isMachO(header) {
                        guard scope == "runtime", DirectUpdateCodeSignature.admitsARM64Header(header) else {
                            throw DirectUpdateRuntimeProvenanceError.architecture
                        }
                        machoPaths.insert(relative)
                    }
                    while offset < before.size {
                        try Task.checkCancellation()
                        let bytes = try BackupFS.read(child, at: offset, count: Int(min(1_048_576, before.size - offset)))
                        guard !bytes.isEmpty else { throw DirectUpdateRuntimeProvenanceError.changed }
                        hash.update(data: bytes); report?.append(bytes); offset += Int64(bytes.count)
                        try fault?(.chunk(relative, offset)); try Task.checkCancellation()
                    }
                    guard offset == before.size, try BackupFS.identity(child) == before else {
                        throw DirectUpdateRuntimeProvenanceError.changed
                    }
                    if let report { capturedReport = report }
                    var record = try prefix(relative, 70); record.appendBE(UInt32(before.mode & 0o777))
                    record.appendBE(UInt64(before.size)); record.append(contentsOf: hash.finalize()); try add(relative, record)
                } else if before.mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    guard scope == "runtime", before.links == 1 else { throw DirectUpdateRuntimeProvenanceError.changed }
                    var bytes = [CChar](repeating: 0, count: 1_025)
                    let count = readlinkat(directory, name, &bytes, bytes.count)
                    guard count > 0, count <= 1_024,
                          let target = String(bytes: bytes.prefix(count).map({ UInt8(bitPattern: $0) }), encoding: .utf8) else {
                        throw DirectUpdateRuntimeProvenanceError.changed
                    }
                    // Symlink permission bits are deliberately not represented:
                    // extraction creates symlinkat links without chmod. Exact
                    // path/kind/target remain pinned, with no target traversal.
                    var record = try prefix(relative, 76); record.appendSizedUTF8(target); try add(relative, record)
                } else { throw DirectUpdateRuntimeProvenanceError.changed }
                try fault?(.beforeEntryValidation(relative)); try Task.checkCancellation()
                guard try BackupFS.entry(directory, name) == before else { throw DirectUpdateRuntimeProvenanceError.changed }
            }
            guard try BackupFS.names(directory) == names, try BackupFS.identity(directory) == identity else {
                throw DirectUpdateRuntimeProvenanceError.changed
            }
        }
        try walk(fd, "")
        // Detect a late overwrite of an already hashed leaf. Retaining every
        // descriptor would exhaust the FD limit on this payload; use the
        // captured identities and fresh no-follow relative-parent descriptors.
        // The enclosing full stage seal also brackets this scalar observation.
        for (path, identity) in captured {
            try Task.checkCancellation()
            let parent = try BackupFS.relativeParent(fd, path); defer { Darwin.close(parent) }
            let name = path.split(separator: "/").last!.description
            guard try BackupFS.entry(parent, name) == identity else { throw DirectUpdateRuntimeProvenanceError.changed }
        }
        try BackupFS.validateDirectoryPath(url, rootIdentity)
        guard try BackupFS.identity(fd) == rootIdentity else { throw DirectUpdateRuntimeProvenanceError.changed }
        var transcript = Data("neantik-exact-runtime-closure-v1\0".utf8)
        transcript.appendSizedUTF8(scope); transcript.appendBE(UInt32(records.count))
        var hash = SHA256(); hash.update(data: transcript)
        for record in records.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            try Task.checkCancellation(); hash.update(data: record.bytes)
        }
        return .init(digest: BackupFS.hex(hash.finalize()), entries: records.count,
                     regularBytes: total, machoPaths: machoPaths, capturedReport: capturedReport)
    }

    static func isMachO(_ bytes: Data) -> Bool {
        guard bytes.count >= 4 else { return false }
        let magics: [[UInt8]] = [[0xcf,0xfa,0xed,0xfe], [0xce,0xfa,0xed,0xfe],
            [0xfe,0xed,0xfa,0xcf], [0xfe,0xed,0xfa,0xce], [0xca,0xfe,0xba,0xbe],
            [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]]
        return magics.contains(Array(bytes.prefix(4)))
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    mutating func appendSizedUTF8(_ value: String) { appendBE(UInt32(value.utf8.count)); append(contentsOf: value.utf8) }
}
