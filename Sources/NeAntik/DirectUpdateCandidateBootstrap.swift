import CryptoKit
import Darwin
import Foundation
import Security

/// Runs before lifecycle admission, ProfileStore, backup composition and
/// credential services. This mode is a bounded owner handshake, never MCP input
/// or a shortcut around ordinary startup fences.
enum DirectUpdateCandidateBootstrap {
    static let argument = "--neantik-update-bootstrap-v1"
    static func runIfRequested() {
        guard CommandLine.arguments.contains(where: { $0.hasPrefix("--neantik-update-bootstrap") }) else { return }
        do {
            guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == argument else {
                throw DirectUpdateInstallSessionError.request
            }
            let app = try ownApp()
            #if DEBUG
            let qa = Bundle(url: app)?.bundleIdentifier == "app.neantik.desktop.update-bootstrap-qa"
            #else
            let qa = false
            #endif
            let request = try DirectUpdateBootstrapRequest.parse(readExactly(DirectUpdateBootstrapRequest.byteCount))
            let root = try BackupFS.directory(app); defer { close(root) }
            let rootIdentity = try BackupFS.identity(root)
            guard rootIdentity.uid == geteuid(), rootIdentity.device >= 0, UInt64(rootIdentity.device) == request.candidateDevice,
                  UInt64(rootIdentity.inode) == request.candidateInode else { throw DirectUpdateInstallSessionError.custody }
            try BackupFS.validateDirectoryPath(app, rootIdentity)
            let fields: (code: ProxyRelayExpectedCode, cdHash: Data, build: UInt64)
            if qa {
                #if DEBUG
                fields = try qaCode(app)
                #else
                throw DirectUpdateInstallSessionError.identity
                #endif
            } else {
                let signed = try DirectUpdateCodeSignature.inspect(app, role: .manager)
                guard let build = UInt64(signed.build), build > 0 else { throw DirectUpdateInstallSessionError.identity }
                fields = (try ProxyRelayExpectedCode.qualifiedPin(at: app, expectedIdentifier: DirectUpdateCodeRole.manager.identifier,
                    expectedTeamIdentifier: DirectUpdateCodeSignature.team, expectedCDHash: signed.cdHash), signed.cdHash, build)
            }
            guard let selfIdentity = DirectProcessIdentityInspector.processIdentity(getpid()),
                  selfIdentity.parentProcessID > 1,
                  ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: selfIdentity, expectedCode: fields.code),
                  let owner = DirectProcessIdentityInspector.processIdentity(selfIdentity.parentProcessID), owner.userID == geteuid() else {
                throw DirectUpdateInstallSessionError.identity
            }
            // The only parent pin comes from this signed candidate's protected
            // helper payload. A supplied path, same team or argv cannot replace it.
            let ownerURL = app.appendingPathComponent("Contents/Helpers/NeAntikUpdateOwner")
            let ownerCode = try DirectUpdateEmptyEntitlementCode.inspect(ownerURL, identifier: qa ? "app.neantik.update-owner-qa" : "app.neantik.update-owner").pin
            guard ProxyRelayLiveCodeVerifier.matches(processID: selfIdentity.parentProcessID, expectedProcess: owner, expectedCode: ownerCode) else {
                throw DirectUpdateInstallSessionError.identity
            }
            let resources = app.appendingPathComponent("Contents/Resources")
            let runtimeURL = resources.appendingPathComponent("NeAntik Browser.app")
            _ = try DirectUpdateCodeSignature.inspect(runtimeURL, role: .runtime)
            _ = try DirectUpdateCodeSignature.inspect(runtimeURL.appendingPathComponent("Contents/Frameworks/NeAntik Browser Framework.framework"), role: .framework)
            let runtime = try DirectRuntimeClosure.measure(runtimeURL, scope: "runtime",
                maximumEntries: DirectUpdateRuntimePins.runtimeEntries, maximumBytes: DirectUpdateRuntimePins.runtimeBytes)
            let evidence = try DirectRuntimeClosure.measure(resources.appendingPathComponent("NeAntikRuntimeEvidence"), scope: "evidence",
                maximumEntries: DirectUpdateRuntimePins.evidenceEntries, maximumBytes: DirectUpdateRuntimePins.evidenceBytes)
            try DirectUpdateRuntimeProvenance.validateMeasurements(runtime, evidence)
            guard let report = evidence.capturedReport, BackupFS.hex(SHA256.hash(data: report)) == DirectUpdateRuntimePins.reportDigest,
                  let dictionary = try JSONSerialization.jsonObject(with: report) as? [String: Any] else { throw DirectUpdateInstallSessionError.custody }
            try DirectUpdateRuntimeProvenance.validateReport(dictionary)
            try BackupFS.validateDirectoryPath(app, rootIdentity)
            guard try BackupFS.identity(root) == rootIdentity,
                  ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: selfIdentity, expectedCode: fields.code),
                  ProxyRelayLiveCodeVerifier.matches(processID: selfIdentity.parentProcessID, expectedProcess: owner, expectedCode: ownerCode) else {
                throw DirectUpdateInstallSessionError.custody
            }
            let reply = try request.reply(cdHash: fields.cdHash, build: fields.build, runtimeSHA256: DirectUpdateRuntimePins.runtimeDigest)
            try writeExactly(reply)
            // Real EOF seals the reply. Neither output nor logging can append a
            // second frame while owner records ACK. Continue is private stdin.
            close(STDOUT_FILENO); close(STDERR_FILENO)
            guard try readExactly(36) == request.continuation, try readEOF() else { throw DirectUpdateInstallSessionError.handoff }
            #if DEBUG
            if qa { exit(0) } // QA never proceeds into any profile/credential store.
            #endif
            // Owner released fences after durable ACK. Ordinary admission below
            // still checks the actual installed pathname and pending journal.
        } catch { exit(EX_NOPERM) }
    }

    private static func ownApp() throws -> URL {
        var path = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0,
              let canonical = realpath(String(cString: path), nil) else { throw DirectUpdateInstallSessionError.identity }
        defer { free(canonical) }
        let executable = URL(fileURLWithPath: String(cString: canonical))
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", app.appendingPathComponent("Contents/MacOS/NeAntik") == executable else {
            throw DirectUpdateInstallSessionError.identity
        }
        return app
    }
    #if DEBUG
    private static func qaCode(_ app: URL) throws -> (code: ProxyRelayExpectedCode, cdHash: Data, build: UInt64) {
        let observation = try DirectUpdateEmptyEntitlementCode.inspect(app, identifier: "app.neantik.desktop.update-bootstrap-qa")
        guard let value = observation.build, let build = UInt64(value), build > 0 else {
            throw DirectUpdateInstallSessionError.identity
        }
        return (observation.pin, observation.cdHash, build)
    }
    #endif
    private static func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while result.count < count {
            guard ContinuousClock.now < deadline else { throw DirectUpdateInstallSessionError.timeout }
            var event = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let status = poll(&event, 1, 20)
            if status < 0, errno == EINTR { continue }
            guard status >= 0, event.revents & Int16(POLLNVAL) == 0 else { throw DirectUpdateInstallSessionError.io }
            if status == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let got = read(STDIN_FILENO, &bytes, bytes.count)
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { throw DirectUpdateInstallSessionError.io }
            result.append(contentsOf: bytes.prefix(got))
        }
        return result
    }
    private static func readEOF() throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            var event = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let status = poll(&event, 1, 20)
            if status < 0, errno == EINTR { continue }
            guard status >= 0 else { throw DirectUpdateInstallSessionError.io }
            if status == 0 { continue }
            var byte: UInt8 = 0
            let got = read(STDIN_FILENO, &byte, 1)
            if got < 0, errno == EINTR { continue }
            return got == 0
        }
        throw DirectUpdateInstallSessionError.timeout
    }
    private static func writeExactly(_ bytes: Data) throws {
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { throw DirectUpdateInstallSessionError.io }; offset += sent
        }
    }
}
