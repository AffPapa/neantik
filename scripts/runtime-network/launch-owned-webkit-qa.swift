import AppKit
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

/// One-use launcher for an owner-only, signed Dev QA candidate. It reads a
/// frozen stage receipt and refuses a changed archive, manager, or seed.
private struct Candidate: Decodable {
    let stage: String
    let root: String
    let app: String
    let archive: String
    let sha256: String
    let profileSeedSHA256: String
    let managerSignedSHA256: String
    let hostSHA256: String?
    let qaRuntimeVariant: String?
    let qaWebGPUSHA256: String?
    let qaRuntimeBindingSHA256: String?
    let qaSuccessorManifestSHA256: String?
    let qaNetworkSandboxSHA256: String?
    let releaseQualified: Bool?
    let disposableDebugFixture: Bool?
}

private let successorVariant = "OwnedWebKitSuccessorV1"
private let devManagerID = "app.neantik.desktop.dev"
private let devHostID = "app.neantik.desktop.dev.webkit-host"

private func refuse(_ reason: String) -> Never {
    fputs("REFUSED: \(reason)\n", stderr)
    exit(65)
}

private func digest(_ path: String) throws -> String {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    var hash = SHA256()
    while true {
        let block = try file.read(upToCount: 1024 * 1024) ?? Data()
        if block.isEmpty { break }
        hash.update(data: block)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func ownerOnly(_ path: String, mode: mode_t) -> Bool {
    var entry = stat()
    return lstat(path, &entry) == 0 &&
        entry.st_uid == geteuid() && entry.st_mode & 0o777 == mode &&
        entry.st_mode & mode_t(S_IFMT) == (mode == 0o700 ? mode_t(S_IFDIR) : mode_t(S_IFREG))
}

private func physicalFile(_ path: String) -> Bool {
    var entry = stat()
    return lstat(path, &entry) == 0 && entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
}

private func strictSignature(_ path: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    task.arguments = ["--verify", "--deep", "--strict", path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
    catch { return false }
}

private func canonicalPath(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    return url.standardizedFileURL.path == path && url.resolvingSymlinksInPath().path == path
}

private func physicalDirectory(_ path: String) -> Bool {
    var entry = stat()
    return lstat(path, &entry) == 0 && entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
}

private func lacksProvisioningProfile(_ bundlePath: String) -> Bool {
    var entry = stat()
    return lstat(bundlePath + "/Contents/embedded.provisionprofile", &entry) == -1 && errno == ENOENT
}

private func exactSHA256(_ value: String?) -> Bool {
    guard let value else { return false }
    return value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func developerIDSignedInfo(_ url: URL, identifier: String, manager: Bool) -> [String: Any]? {
    let expression = "anchor apple generic and identifier \"\(identifier)\" and " +
        "certificate leaf[subject.OU] = \"H6VGU2M6JD\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures |
                           (manager ? kSecCSCheckNestedCode : 0))
    var requirement: SecRequirement?
    var code: SecStaticCode?
    var dictionary: CFDictionary?
    guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess,
          let requirement,
          SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
          let info = dictionary as? [String: Any] else { return nil }
    if manager, let entitlements = info[kSecCodeInfoEntitlementsDict as String],
       (entitlements as? [String: Any])?.isEmpty != true { return nil }
    return info[kSecCodeInfoPList as String] as? [String: Any]
}

private func verifySuccessorPaths(_ candidate: Candidate, receiptPath: String) {
    let rootPattern = #"\A/private/tmp/neantik-dev-fixture\.[A-Za-z0-9_-]+\z"#
    guard candidate.releaseQualified == false, candidate.disposableDebugFixture == true,
          candidate.qaWebGPUSHA256 == nil,
          exactSHA256(candidate.qaSuccessorManifestSHA256), exactSHA256(candidate.qaNetworkSandboxSHA256),
          exactSHA256(candidate.qaRuntimeBindingSHA256), exactSHA256(candidate.hostSHA256)
    else { refuse("private successor receipt qualification invalid") }
    guard candidate.root.range(of: rootPattern, options: .regularExpression) != nil,
          candidate.stage != candidate.root,
          ownerOnly(receiptPath, mode: 0o600), canonicalPath(receiptPath),
          canonicalPath(candidate.root), canonicalPath(candidate.stage),
          physicalDirectory(candidate.app), canonicalPath(candidate.app),
          physicalFile(candidate.archive), canonicalPath(candidate.archive),
          URL(fileURLWithPath: candidate.archive).deletingLastPathComponent().path == candidate.stage,
          canonicalPath(candidate.app + "/Contents/MacOS/NeAntik"),
          physicalFile(candidate.app + "/Contents/MacOS/NeAntik")
    else { refuse("private successor staged paths invalid") }
}

private func verifySuccessor(_ candidate: Candidate, app: URL) throws {
    let host = candidate.app + "/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app"
    let executable = host + "/Contents/MacOS/NeAntikWebKitHost"
    let binding = host + "/Contents/Resources/NeAntikRuntimeEvidence/NeAntikRuntimeImageBinding.json"
    let sandbox = host + "/Contents/Frameworks/WebKit.framework/Versions/A/Resources/com.apple.WebKit.NetworkProcess.sb"
    guard physicalDirectory(host), canonicalPath(host),
          [executable, binding, sandbox].allSatisfy({ physicalFile($0) && canonicalPath($0) }),
          lacksProvisioningProfile(candidate.app), lacksProvisioningProfile(host),
          let managerInfo = developerIDSignedInfo(app, identifier: devManagerID, manager: true),
          managerInfo["NeAntikPrivateQARuntimeVariant"] as? String == successorVariant,
          managerInfo["NeAntikDevelopmentFixtureRoot"] as? String == candidate.root,
          let hostPin = managerInfo["NeAntikWebKitHostV1"] as? [String: Any],
          hostPin["identifier"] as? String == devHostID,
          hostPin["sha256"] as? String == candidate.hostSHA256,
          let hostInfo = developerIDSignedInfo(URL(fileURLWithPath: host), identifier: devHostID, manager: false),
          hostInfo["NeAntikWebKitNetworkSandboxSHA256"] as? String == candidate.qaNetworkSandboxSHA256,
          let marker = hostInfo["NeAntikOwnedWebKitPrivateSuccessorV1"] as? [String: Any],
          Set(marker.keys) == ["manifestSHA256", "releaseQualified"],
          marker["manifestSHA256"] as? String == candidate.qaSuccessorManifestSHA256,
          let release = marker["releaseQualified"] as? NSNumber,
          CFGetTypeID(release) == CFBooleanGetTypeID(), !release.boolValue,
          try digest(executable) == candidate.hostSHA256,
          try digest(binding) == candidate.qaRuntimeBindingSHA256,
          try digest(sandbox) == candidate.qaNetworkSandboxSHA256
    else { refuse("private successor signature, host or sandbox identity mismatch") }
}

@MainActor
private func launch() async throws {
    guard CommandLine.arguments.count == 3 ||
          (CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--check-only")
    else { refuse("candidate and expected SHA required") }
    let receiptPath = CommandLine.arguments[1]
    let expectedSHA = CommandLine.arguments[2]
    guard expectedSHA.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          receiptPath.hasPrefix("/private/tmp/neantik-") else { refuse("invalid arguments") }
    let candidate = try JSONDecoder().decode(Candidate.self,
        from: Data(contentsOf: URL(fileURLWithPath: receiptPath)))
    if candidate.qaRuntimeVariant == successorVariant {
        verifySuccessorPaths(candidate, receiptPath: receiptPath)
    } else if candidate.qaSuccessorManifestSHA256 != nil || candidate.qaNetworkSandboxSHA256 != nil {
        refuse("private successor runtime variant missing")
    }
    let stage = URL(fileURLWithPath: candidate.stage, isDirectory: true)
    let root = URL(fileURLWithPath: candidate.root, isDirectory: true)
    let app = URL(fileURLWithPath: candidate.app, isDirectory: true)
    guard candidate.sha256 == expectedSHA,
          stage.deletingLastPathComponent().path == "/private/tmp",
          root.deletingLastPathComponent().path == "/private/tmp",
          stage.lastPathComponent.hasPrefix("neantik-"),
          root.lastPathComponent.hasPrefix("neantik-"),
          candidate.app == stage.appendingPathComponent("NeAntik.app").path,
          candidate.archive.hasPrefix(candidate.stage + "/"),
          receiptPath == stage.appendingPathComponent("stage.json").path,
          ownerOnly(candidate.stage, mode: 0o700),
          ownerOnly(candidate.root, mode: 0o700),
          ownerOnly(candidate.root + "/profiles.json", mode: 0o600),
          ownerOnly(candidate.root + "/profiles.previous.json", mode: 0o600),
          try digest(candidate.archive) == expectedSHA,
          try digest(candidate.app + "/Contents/MacOS/NeAntik") == candidate.managerSignedSHA256,
          try digest(candidate.root + "/profiles.json") == candidate.profileSeedSHA256,
          try digest(candidate.root + "/profiles.previous.json") == candidate.profileSeedSHA256,
          let bundle = Bundle(url: app),
          bundle.bundleIdentifier == "app.neantik.desktop.dev",
          bundle.object(forInfoDictionaryKey: "NeAntikDevelopmentFixtureRoot") as? String == candidate.root
    else { refuse("archive, bundle, manager, root or seed mismatch") }
    let signedVariant = bundle.object(forInfoDictionaryKey: "NeAntikPrivateQARuntimeVariant") as? String
    guard signedVariant == candidate.qaRuntimeVariant else { refuse("signed QA runtime variant mismatch") }
    if candidate.qaRuntimeVariant == successorVariant {
        try verifySuccessor(candidate, app: app)
    } else if let variant = candidate.qaRuntimeVariant {
        guard variant == "V508",
              candidate.qaWebGPUSHA256 == "6dbb393c3fae9515e10e6cc9fd42e960ca89270cb35e948c3fe8434a65aa0abc",
              candidate.qaRuntimeBindingSHA256 == "c4264d49e80670c09cf769f4031fae9740cbc1accfa5d37372b78d270b0df39a",
              let hostSHA = candidate.hostSHA256,
              hostSHA.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        else { refuse("private QA runtime identity invalid") }
        let host = candidate.app + "/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app"
        let executable = host + "/Contents/MacOS/NeAntikWebKitHost"
        let gpu = host + "/Contents/Frameworks/WebGPU.framework/Versions/A/WebGPU"
        let binding = host + "/Contents/Resources/NeAntikRuntimeEvidence/NeAntikRuntimeImageBinding.json"
        guard physicalFile(executable), physicalFile(gpu), physicalFile(binding),
              try digest(executable) == hostSHA,
              try digest(gpu) == candidate.qaWebGPUSHA256,
              try digest(binding) == candidate.qaRuntimeBindingSHA256,
              Bundle(url: URL(fileURLWithPath: host))?.bundleIdentifier == "app.neantik.desktop.dev.webkit-host",
              strictSignature(candidate.app)
        else { refuse("private QA staged host or runtime identity mismatch") }
    } else if candidate.qaWebGPUSHA256 != nil || candidate.qaRuntimeBindingSHA256 != nil {
        refuse("private QA runtime variant missing")
    }
    if CommandLine.arguments.count == 4 {
        print("PASS: exact QA archive, signed manager bytes, bundle root and isolated profile seed; no app launched")
        return
    }
    guard NSWorkspace.shared.runningApplications.filter({
        $0.bundleIdentifier == "app.neantik.desktop.dev"
    }).isEmpty else { refuse("another Dev manager is running") }
    let marker = candidate.root + "/qa-" + String(expectedSHA.prefix(12)) + "-single-start-consumed"
    let descriptor = marker.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
    guard descriptor >= 0 else { refuse("single start already consumed") }
    close(descriptor)
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.allowsRunningApplicationSubstitution = false
    config.environment = ["NEANTIK_DEVELOPMENT_DATA_ROOT": candidate.root]
    let running = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
    guard running.bundleIdentifier == "app.neantik.desktop.dev",
          running.bundleURL?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path
    else { refuse("Launch Services returned another app") }
    print("LAUNCHED pid=\(running.processIdentifier) exact signed Dev QA app; synthetic root")
}

@main private struct Main {
    static func main() async {
        do { try await launch() }
        catch { refuse("launch failed: \(type(of: error))") }
    }
}
