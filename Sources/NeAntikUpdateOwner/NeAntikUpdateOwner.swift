import Darwin
import DirectInstallFilesystem
import DirectUpdateCore
import Foundation
import Security

/// Independent executable outside the two application slots. Installation is
/// deliberately unavailable until authenticated bootstrap/stopped authority
/// and premigration readiness have their real-process qualification.
@main enum NeAntikUpdateOwner {
    static func main() async {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["--qa-inspect", "--qa-prepare"].contains(arguments[1]) else { exit(64) }
        do {
            try authenticateQAOwner()
            let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let fixture = try QAOwnerFixture(root: root)
            let coordinator = DirectUpdateAdmissionCoordinator(configuration: fixture.configuration,
                installedVersion: "0.7.29", installedBuild: 92,
                assessmentHelper: { try DirectAssessmentHelper.qualification(in: fixture.helperRoot, payloadSHA256: fixture.helperSHA256) })
            let result = try await coordinator.inspectLocalArchive(root.appendingPathComponent("archive.zip"),
                signedManifest: fixture.manifest, archiveParent: root.appendingPathComponent("archives"),
                extractionParent: root.appendingPathComponent("apps"))
            guard case .observed = result.system.reply else { exit(1) }
            var transferred = false
            if arguments[1] == "--qa-prepare" {
                let lease = try InstallFilesystemLease(parentURL: root.appendingPathComponent("install"))
                let slot = try await coordinator.prepareInstallSlot(lease: lease)
                // Recheck the actual moved candidate under its retained slot.
                // This remains observation; no transaction/launch is invoked.
                let signature = try slot.withValidatedCandidate { try DirectUpdateCodeSignature.inspect($0, role: .manager) }
                guard signature.cdHash == result.system.managerCDHash,
                      await coordinator.snapshot() == .transferred else { exit(1) }
                do { _ = try await coordinator.prepareInstallSlot(lease: lease); exit(1) }
                catch DirectUpdateAdmissionError.alreadyAttempted { }
                transferred = true
            }
            // No paths, raw identifiers, entitlements, tokens or profile data.
            let report: [String: Any] = ["schema": 1, "candidateObserved": true,
                "version": result.version, "build": result.build, "archiveSHA256": result.archiveSHA256,
                "runtimeSHA256": result.runtime.runtimeSHA256, "stageTransferred": transferred,
                "secondTransferRefused": transferred, "installAuthorized": false]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("Independent owner inspection refused.\n".utf8))
            exit(1)
        }
        #else
        // Release has no QA policy, fixture key, profile access or install path.
        exit(64)
        #endif
    }

    #if DEBUG
    private static func authenticateQAOwner() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[0])
        let expected = try ProxyRelayExpectedCode.qualifiedPin(at: url,
            expectedIdentifier: "app.neantik.update-owner-qa", expectedTeamIdentifier: DirectUpdateCodeSignature.team)
        var code: SecStaticCode?, dictionary: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              CFGetTypeID(flags) != CFBooleanGetTypeID(), flags.uint32Value & 0x10002 == 0x10000,
              info[kSecCodeInfoTimestamp as String] is Date,
              info[kSecCodeInfoEntitlementsDict as String] == nil || (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?.isEmpty == true,
              let identity = DirectProcessIdentityInspector.processIdentity(getpid()),
              ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: identity, expectedCode: expected)
        else { throw DirectAssessmentParentError.admission }
    }
    #endif
}

#if DEBUG
/// Bounded synthetic inputs only. This type does not exist in the release
/// executable and cannot supply shipping channel policy or install authority.
private struct QAOwnerFixture: Sendable {
    let configuration: UpdateChannelConfiguration
    let helperRoot: URL, helperSHA256: String, manifest: Data
    private struct Policy: Decodable {
        let publicKey: String, helperRoot: String, helperSHA256: String
    }
    init(root: URL) throws {
        let prefix = "neantik-update-owner-"
        guard root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))),
              root.lastPathComponent == prefix + id.uuidString.lowercased() else { throw DirectAssessmentParentError.request }
        let directory = try BackupFS.directory(root); defer { close(directory) }
        let identity = try BackupFS.identity(directory)
        guard identity.mode & 0o777 == 0o700 else { throw DirectAssessmentParentError.request }
        func read(_ name: String, maximum: Int) throws -> Data {
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw DirectAssessmentParentError.request }; defer { close(fd) }
            let before = try BackupFS.identity(fd); try before.validateFile(device: identity.device)
            guard before.mode & 0o777 == 0o600, before.size > 0, before.size <= maximum else { throw DirectAssessmentParentError.request }
            let bytes = try BackupFS.read(fd, at: 0, count: Int(before.size))
            guard bytes.count == before.size, try BackupFS.identity(fd) == before,
                  try BackupFS.entry(directory, name) == before else { throw DirectAssessmentParentError.request }
            return bytes
        }
        guard try read("fixture.marker", maximum: 64) == Data("isolated-update-owner-qa\n".utf8) else { throw DirectAssessmentParentError.request }
        let policy = try JSONDecoder().decode(Policy.self, from: read("policy.json", maximum: 4_096))
        guard let key = Data(base64Encoded: policy.publicKey), key.count == 32,
              policy.helperSHA256.utf8.count == 64,
              policy.helperSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw DirectAssessmentParentError.request }
        configuration = UpdateChannelConfiguration.fromInfoDictionary([
            UpdateChannelConfiguration.enabledKey: true,
            UpdateChannelConfiguration.manifestURLKey: "https://browser.free/update.json",
            UpdateChannelConfiguration.publicKeyIDKey: "independent-owner-fixture",
            UpdateChannelConfiguration.publicKeyKey: key.base64EncodedString()])
        guard configuration.isEnabled else { throw DirectAssessmentParentError.request }
        helperRoot = URL(fileURLWithPath: policy.helperRoot); helperSHA256 = policy.helperSHA256
        manifest = try read("manifest.json", maximum: 16_384)
        for name in ["archives", "apps", "install"] {
            let fd = try BackupFS.directory(root.appendingPathComponent(name)); defer { close(fd) }
            guard try BackupFS.identity(fd).mode & 0o777 == 0o700 else { throw DirectAssessmentParentError.request }
        }
        try BackupFS.validateDirectoryPath(root, identity)
    }
}
#endif
