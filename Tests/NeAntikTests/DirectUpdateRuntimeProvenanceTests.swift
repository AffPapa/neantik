import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

private final class RuntimeClosureFixture: @unchecked Sendable {
    let root = URL(fileURLWithPath: "/private/tmp/neantik-runtime-closure-" + UUID().uuidString)
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try write("dir/a.txt", Data("hello\n".utf8)); try write("é.txt", Data())
        guard symlink("dir/a.txt", root.appendingPathComponent("link").path) == 0 else { throw BackupFS.posix() }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ data: Data, mode: mode_t = 0o600) throws {
        let url = root.appendingPathComponent(path); try data.write(to: url)
        guard chmod(url.path, mode) == 0 else { throw BackupFS.posix() }
    }
    func measure(_ fault: (@Sendable (DirectRuntimeClosurePoint) throws -> Void)? = nil) throws -> DirectRuntimeClosureMeasurement {
        try DirectRuntimeClosure.measure(root, scope: "runtime", maximumEntries: 20, maximumBytes: 4_194_304, fault: fault)
    }
}

@Suite(.serialized) struct DirectUpdateRuntimeProvenanceTests {
    @Test func canonicalTranscriptMatchesIndependentPythonGoldenAndIsRepeatable() throws {
        let fixture = try RuntimeClosureFixture(), first = try fixture.measure(), repeated = try fixture.measure()
        #expect(first == repeated)
        #expect(first.digest == "a43d10f462c05cff07b361bfce4885cff3f9bbb921f053e9629436331dc51fa3")
        #expect(first.entries == 5 && first.regularBytes == 6 && first.machoPaths.isEmpty && first.capturedReport == nil)
        #expect(throws: DirectUpdateRuntimeProvenanceError.closure) { try DirectUpdateRuntimeProvenance.validateMeasurements(first, first) }
    }

    @Test(arguments: ["content", "mode", "extra-directory", "extra-empty-file", "renamed-empty-file", "missing-file", "alternate-link", "type", "signature-resource"])
    func exactClosureDetectsAllKindsOfNamespaceAndByteDrift(control: String) throws {
        let fixture = try RuntimeClosureFixture(), original = try fixture.measure()
        switch control {
        case "content": try fixture.write("dir/a.txt", Data("HELLO\n".utf8))
        case "mode": guard chmod(fixture.root.appendingPathComponent("dir/a.txt").path, 0o644) == 0 else { throw BackupFS.posix() }
        case "extra-directory": try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        case "extra-empty-file": try fixture.write("extra", Data())
        case "renamed-empty-file": try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("é.txt"), to: fixture.root.appendingPathComponent("empty"))
        case "missing-file": try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("é.txt"))
        case "alternate-link":
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("link"))
            guard symlink("./dir/a.txt", fixture.root.appendingPathComponent("link").path) == 0 else { throw BackupFS.posix() }
        case "type":
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("é.txt"))
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("é.txt"), withIntermediateDirectories: false)
        default: try fixture.write("CodeResources", Data("changed signature envelope".utf8))
        }
        #expect(try fixture.measure().digest != original.digest)
    }

    @Test(arguments: ["replace-leaf", "hardlink", "ancestor", "last-chunk", "mode", "earlier-leaf"])
    func CapturedDescriptorRefusesRacesDuringHashing(control: String) throws {
        let fixture = try RuntimeClosureFixture(), file = fixture.root.appendingPathComponent("dir/a.txt")
        #expect(throws: (any Error).self) {
            try fixture.measure { point in
                if control == "earlier-leaf" {
                    if case .beforeEntryValidation("é.txt") = point { try fixture.write("dir/a.txt", Data("tamper".utf8)) }
                } else if control == "last-chunk" {
                    if case .chunk("dir/a.txt", _) = point { try fixture.write("dir/a.txt", Data("tamper".utf8)) }
                } else if case .opened("dir/a.txt") = point {
                    switch control {
                    case "replace-leaf":
                        try FileManager.default.moveItem(at: file, to: fixture.root.appendingPathComponent("old-file"))
                        try fixture.write("dir/a.txt", Data("hello\n".utf8))
                    case "hardlink":
                        guard link(file.path, fixture.root.appendingPathComponent("linked").path) == 0 else { throw BackupFS.posix() }
                    case "ancestor":
                        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("dir"), to: fixture.root.appendingPathComponent("old-dir"))
                        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("dir"), withIntermediateDirectories: false)
                        try fixture.write("dir/a.txt", Data("hello\n".utf8))
                    default: guard chmod(file.path, 0o644) == 0 else { throw BackupFS.posix() }
                    }
                }
            }
        }
    }

    @Test func hardlinksSymlinkAncestorsAndSpecialFilesRefuseWithoutTraversal() throws {
        let fixture = try RuntimeClosureFixture()
        let alias = fixture.root.appendingPathComponent("alias")
        guard symlink("dir", alias.path) == 0 else { throw BackupFS.posix() }
        #expect(throws: (any Error).self) { try DirectRuntimeClosure.measure(alias, scope: "runtime", maximumEntries: 20, maximumBytes: 100) }
        let hardlink = fixture.root.appendingPathComponent("hard")
        guard link(fixture.root.appendingPathComponent("dir/a.txt").path, hardlink.path) == 0 else { throw BackupFS.posix() }
        #expect(throws: (any Error).self) { try fixture.measure() }
        try FileManager.default.removeItem(at: hardlink)
        guard mkfifo(fixture.root.appendingPathComponent("fifo").path, 0o600) == 0 else { throw BackupFS.posix() }
        #expect(throws: DirectUpdateRuntimeProvenanceError.changed) { try fixture.measure() }
    }

    @Test func boundsAndRootModeArePartOfAdmission() throws {
        let fixture = try RuntimeClosureFixture()
        #expect(throws: (any Error).self) { try DirectRuntimeClosure.measure(fixture.root, scope: "runtime", maximumEntries: 4, maximumBytes: 100) }
        #expect(throws: DirectUpdateRuntimeProvenanceError.limit) { try DirectRuntimeClosure.measure(fixture.root, scope: "runtime", maximumEntries: 20, maximumBytes: 5) }
        #expect(throws: DirectUpdateRuntimeProvenanceError.limit) { try DirectRuntimeClosure.measure(fixture.root, scope: "unknown", maximumEntries: 20, maximumBytes: 100) }
        let first = try fixture.measure()
        guard chmod(fixture.root.path, 0o755) == 0 else { throw BackupFS.posix() }
        #expect(try fixture.measure().digest != first.digest)
        guard chmod(fixture.root.path, 0o1700) == 0 else { throw BackupFS.posix() }
        #expect(throws: DirectUpdateRuntimeProvenanceError.changed) { try fixture.measure() }
    }

    @Test(arguments: ["short", "x86", "fat", "swapped"])
    func foreignMachORefusesEvenWithoutExecutableMode(control: String) throws {
        let fixture = try RuntimeClosureFixture()
        var bytes = Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1] + Array(repeating: UInt8(0), count: 24))
        if control == "short" { bytes = bytes.prefix(4) }
        if control == "x86" { bytes[4] = 7 }
        if control == "fat" { bytes.replaceSubrange(0..<4, with: [0xca,0xfe,0xba,0xbe]) }
        if control == "swapped" { bytes.replaceSubrange(0..<4, with: [0xfe,0xed,0xfa,0xcf]) }
        try fixture.write("hidden-code.bin", bytes)
        #expect(throws: DirectUpdateRuntimeProvenanceError.architecture) { try fixture.measure() }
    }

    @Test func evidenceRefusesSymlinkAndOversizedReportBeforeParsing() throws {
        let fixture = try RuntimeClosureFixture()
        #expect(throws: DirectUpdateRuntimeProvenanceError.changed) {
            try DirectRuntimeClosure.measure(fixture.root, scope: "evidence", maximumEntries: 20, maximumBytes: 100)
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("link"))
        try fixture.write("runtime-verification.json", Data(repeating: 65, count: 65_537))
        #expect(throws: DirectUpdateRuntimeProvenanceError.limit) {
            try DirectRuntimeClosure.measure(fixture.root, scope: "evidence", maximumEntries: 20, maximumBytes: 100_000)
        }
    }

    @Test(arguments: [false, true]) func cancellationBeforeStartAndAtLastChunkCannotReturnMeasurement(atLastChunk: Bool) async throws {
        let fixture = try RuntimeClosureFixture()
        let task = Task {
            if !atLastChunk { withUnsafeCurrentTask { $0?.cancel() } }
            return try fixture.measure { point in
                if atLastChunk, case .chunk("dir/a.txt", _) = point { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; Issue.record("Cancelled hash returned a measurement") }
        catch { #expect(error is CancellationError) }
        #expect(try fixture.measure().regularBytes == 6)
    }

    @Test func reportSchemaRejectsContradictionsAndDoesNotGrantAuthority() throws {
        // Strict schema is exercised independently; the product additionally
        // requires the exact captured report hash before parsing.
        var report: [String: Any] = DirectUpdateRuntimePins.reportHashes
        report.merge(["schemaVersion": 3, "chromiumVersion": DirectUpdateRuntimePins.chromiumVersion,
            "architecture": "arm64", "gpuMode": "metal", "machoCount": 16, "createdAt": "2026-10-10T07:09:29.793627Z",
            "codeSignature": "verified", "codeSignatureKind": "developer-id", "fingerprintProtocolStrings": "verified",
            "freshWholeSourceTreeObserved": false, "sourceEvidenceMode": "executed-final9-preserved-build-and-current-packaging-inputs",
            "buildArguments": ["sha256": "b32623308042c6b3b86f14ce9635ccc9abdc290148ce596c1e4f4a43ffde9a01"],
            "executable": ["path": DirectUpdateRuntimePins.executable, "sha256": "1b1e460981efe56aa8f4825b7f4f7c6f2e8cc51e244d718ba300db78ac872ff0"],
            "framework": ["path": DirectUpdateRuntimePins.framework, "sha256": "87374f1072a83850ea20da83897eac86de6d1357abcff0f0fad87dabd836e815"]], uniquingKeysWith: { _, new in new })
        try DirectUpdateRuntimeProvenance.validateReport(report)
        let controls: [(String, Any)] = [("schemaVersion", true), ("schemaVersion", "3"), ("machoCount", 15),
            ("freshWholeSourceTreeObserved", 0), ("freshWholeSourceTreeObserved", true), ("gpuMode", "no-metal"),
            ("architecture", "x86_64"), ("chromiumVersion", "157.0.0.0"), ("sourceLockSHA256", String(repeating: "0", count: 64)),
            ("createdAt", "invalid"), ("executable", ["path": "../fake", "sha256": "fake"]),
            ("buildArguments", ["sha256": "fake", "angle_enable_metal": "true"]), ("unknown", "ignored")]
        for (key, value) in controls {
            var broken = report; broken[key] = value
            #expect(throws: DirectUpdateRuntimeProvenanceError.metadata) { try DirectUpdateRuntimeProvenance.validateReport(broken) }
        }
        report.removeValue(forKey: "sourceEvidenceMode")
        #expect(throws: DirectUpdateRuntimeProvenanceError.metadata) { try DirectUpdateRuntimeProvenance.validateReport(report) }
        #expect(DirectUpdateRuntimePins.machoPaths.count == 16)
    }
}
