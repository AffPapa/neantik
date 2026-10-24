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
