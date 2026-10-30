import AppKit
import CryptoKit
import Darwin
import Foundation

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
}

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
    let signedVariant = Bundle(url: app)?.object(forInfoDictionaryKey: "NeAntikPrivateQARuntimeVariant") as? String
    guard signedVariant == candidate.qaRuntimeVariant else { refuse("signed QA runtime variant mismatch") }
    if let variant = candidate.qaRuntimeVariant {
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
