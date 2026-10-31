import Darwin
import Foundation
import Testing
import DirectUpdateCore
@testable import NeAntik

/// Opt-in filesystem measurement only. Does not enroll or launch a browser,
/// inspect profiles, change signatures or admit an unqualified capability.
struct PrivateRuntimeClosureMeasurementTests {
    private static let input = ProcessInfo.processInfo.environment["NEANTIK_PRIVATE_RUNTIME_MEASUREMENT_INPUT"]
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_PRIVATE_RUNTIME_MEASUREMENT_INPUT"] != nil))
    func updaterRecognizesTheExactFrozenSignedRuntimeAndEvidence() throws {
        let resources = URL(fileURLWithPath: "/private/tmp/neantik-privacy20-pin-reference18/Contents/Resources", isDirectory: true)
        let observation = try DirectUpdateRuntimeProvenance.inspectResources(resources)
        #expect(observation.chromiumVersion == "156.0.8078.80")
        #expect(observation.runtimeSHA256 == DirectUpdatePrivacyRuntimePins.runtimeDigest)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_PRIVATE_RUNTIME_MEASUREMENT_INPUT"] != nil))
    func measuredSuccessorAdmitsTypedPoliciesButOldSignedPackagingDoesNot() throws {
        let raw = try #require(Self.input)
        let app = try OwnedProfileDirectory.platformPath(URL(fileURLWithPath: raw))
        let runtime = BrowserRuntime(name: "Own signed privacy engine", executableURL: app.appendingPathComponent("Contents/MacOS/NeAntik Browser"), source: "Own QA", flavor: .fingerprintChromium)
        #expect(runtime.supportsProfilePrivacy)
        #expect(runtime.supportsSystemFontPolicy)
        let profile = BrowserProfile(name: "Own policy", fontPolicy: .systemV1, privacyPolicy: .strict)
        try BrowserLaunchPolicy.validatePrivacyPolicy(profile, runtime: runtime)
        try BrowserLaunchPolicy.validateFontPolicy(profile, runtime: runtime)
        let old = URL(fileURLWithPath: "/private/tmp/neantik-privacy20-candidate17/NeAntik Browser.app/Contents/MacOS/NeAntik Browser")
        #expect(BrowserPrivacyRuntime.inspect(executableURL: old) == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_PRIVATE_RUNTIME_MEASUREMENT_INPUT"] != nil))
    func measureExactSignedPrivateRuntimeWithoutLaunchingIt() throws {
        let raw = try #require(Self.input)
        let root = try OwnedProfileDirectory.platformPath(URL(fileURLWithPath: raw))
        let outputRaw = try #require(ProcessInfo.processInfo.environment["NEANTIK_PRIVATE_RUNTIME_MEASUREMENT_OUTPUT"])
        let rawOutput = URL(fileURLWithPath: outputRaw)
        let outputParent = try OwnedProfileDirectory.platformPath(rawOutput.deletingLastPathComponent())
        let output = outputParent.appendingPathComponent(rawOutput.lastPathComponent, isDirectory: false)
        #expect(root.path.hasPrefix("/private/tmp/neantik-"))
        #expect(root.lastPathComponent == "NeAntik Browser.app")
        guard root.path.hasPrefix("/private/tmp/neantik-"), root.lastPathComponent == "NeAntik Browser.app",
              output.path.hasPrefix("/private/tmp/neantik-"), output.pathExtension == "json",
              !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteInvalidFileName) }
        _ = try DirectUpdateCodeSignature.inspect(root, role: .runtime)
        let measured = try DirectRuntimeClosure.measure(root, scope: "runtime", maximumEntries: 2_000, maximumBytes: 1_073_741_824)
        let executable = root.appendingPathComponent("Contents/MacOS/NeAntik Browser")
        let executableSHA = try #require(BrowserFontPolicyRuntime.executableDigest(executable))
        let record: [String: Any] = [
            "schemaVersion": 1, "status": "measured-signed-closure-behavior-unqualified",
            "runtimeDigest": measured.digest, "entries": measured.entries,
            "regularBytes": measured.regularBytes, "machoCount": measured.machoPaths.count,
            "executableSHA256": executableSHA, "browserLaunched": false,
            "nativeBehaviorQualified": false, "releaseQualified": false
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        // Component-wise no-follow directory authority is the filesystem
        // check; Foundation URL equality is not an alias/inode check.
        let parent = try BackupFS.directory(outputParent); defer { Darwin.close(parent) }
        let fd = openat(parent, output.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteFileExists) }
        defer { Darwin.close(fd) }
        try BackupFS.write(fd, data, at: 0)
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        #expect(measured.machoPaths.count == 16)
    }
}
