import CryptoKit
import Darwin
import Foundation
import Security

/// Runs before lifecycle admission, ProfileStore, backup composition and
/// credential services. This mode is a bounded owner handshake, never MCP input
/// or a shortcut around ordinary startup fences.
enum DirectUpdateCandidateBootstrap {
    static let argument = "--neantik-update-bootstrap-v1"
    static func runIfRequested() -> DirectUpdateAuditIsolation? {
        guard CommandLine.arguments.contains(where: { $0.hasPrefix("--neantik-update-bootstrap") }) else { return nil }
        var phase = "request"
        do {
            guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == argument else {
                throw DirectUpdateInstallSessionError.request
            }
            let app = try ownApp()
            phase = "fixture"
            #if DEBUG
            let qa = Bundle(url: app)?.bundleIdentifier == "app.neantik.desktop.update-bootstrap-qa"
            let qaContinues = qa ? try disposableContinuation(app) : false
            #else
            let qa = false
            #endif
            let request = try DirectUpdateBootstrapRequest.parse(readExactly(DirectUpdateBootstrapRequest.byteCount))
            phase = "root"
            let root = try BackupFS.directory(app); defer { close(root) }
            let rootIdentity = try BackupFS.identity(root)
            var rootStatus = stat()
            guard fstat(root, &rootStatus) == 0, rootStatus.st_flags == 0 else { throw DirectUpdateInstallSessionError.custody }
            guard rootIdentity.uid == geteuid(), rootIdentity.device >= 0, UInt64(rootIdentity.device) == request.candidateDevice,
                  UInt64(rootIdentity.inode) == request.candidateInode else { throw DirectUpdateInstallSessionError.custody }
            try BackupFS.validateDirectoryPath(app, rootIdentity)
            let fields: (code: ProxyRelayExpectedCode, cdHash: Data, build: UInt64)
            phase = "code"
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
            phase = "live-code"
            guard let selfIdentity = DirectProcessIdentityInspector.processIdentity(getpid()),
                  selfIdentity.parentProcessID > 1,
                  ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: selfIdentity, expectedCode: fields.code),
                  let owner = DirectProcessIdentityInspector.processIdentity(selfIdentity.parentProcessID), owner.userID == geteuid() else {
                throw DirectUpdateInstallSessionError.identity
            }
            // The only parent pin comes from this signed candidate's protected
            // helper payload. A supplied path, same team or argv cannot replace it.
            let ownerURL = app.appendingPathComponent("Contents/Helpers/NeAntikUpdateOwner")
            phase = "owner"
            let ownerCode = try DirectUpdateEmptyEntitlementCode.inspect(ownerURL, identifier: qa ? "app.neantik.update-owner-qa" : "app.neantik.update-owner").pin
            guard ProxyRelayLiveCodeVerifier.matches(processID: selfIdentity.parentProcessID, expectedProcess: owner, expectedCode: ownerCode) else {
                throw DirectUpdateInstallSessionError.identity
            }
            phase = "audit-isolation"
            let auditDirectory: URL?
            if qa { auditDirectory = nil }
            else {
                var ownerPath = [CChar](repeating: 0, count: 4_096)
                guard proc_pidpath(selfIdentity.parentProcessID, &ownerPath, UInt32(ownerPath.count)) > 0 else {
                    throw DirectUpdateInstallSessionError.identity
                }
                auditDirectory = try DirectUpdateAuditRecord.directory(authenticatedOwnerExecutable: URL(fileURLWithPath: String(cString: ownerPath)))
            }
            let audit = try auditDirectory.flatMap { try DirectUpdateAuditRecord.load(directory: $0, request: request) }
            try audit?.0.validate()
            let resources = app.appendingPathComponent("Contents/Resources")
            phase = "runtime"
            let runtimeURL = resources.appendingPathComponent("NeAntik Browser.app")
            _ = try DirectUpdateCodeSignature.inspect(runtimeURL, role: .runtime)
            _ = try DirectUpdateCodeSignature.inspect(runtimeURL.appendingPathComponent("Contents/Frameworks/NeAntik Browser Framework.framework"), role: .framework)
            let runtime = try DirectRuntimeClosure.measure(runtimeURL, scope: "runtime",
                maximumEntries: DirectUpdateRuntimePins.runtimeEntries, maximumBytes: DirectUpdateRuntimePins.runtimeBytes)
            let evidence = try DirectUpdateRuntimeProvenance.measureEvidence(resources.appendingPathComponent("NeAntikRuntimeEvidence"))
            try DirectUpdateRuntimeProvenance.validateMeasurements(runtime, evidence)
            phase = "report"
            guard let report = evidence.capturedReport, BackupFS.hex(SHA256.hash(data: report)) == DirectUpdateRuntimePins.reportDigest,
                  let dictionary = try JSONSerialization.jsonObject(with: report) as? [String: Any] else { throw DirectUpdateInstallSessionError.custody }
            try DirectUpdateRuntimeProvenance.validateReport(dictionary)
            try BackupFS.validateDirectoryPath(app, rootIdentity)
            phase = "reply-root"
            var freshRootStatus = stat()
            guard try BackupFS.identity(root).sameBundleRoot(rootIdentity),
                  fstat(root, &freshRootStatus) == 0, freshRootStatus.st_flags == rootStatus.st_flags else {
                throw DirectUpdateInstallSessionError.custody
            }
            phase = "reply-self"
            guard ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: selfIdentity, expectedCode: fields.code) else {
                throw DirectUpdateInstallSessionError.custody
            }
            phase = "reply-owner"
            guard ProxyRelayLiveCodeVerifier.matches(processID: selfIdentity.parentProcessID, expectedProcess: owner, expectedCode: ownerCode) else {
                throw DirectUpdateInstallSessionError.custody
            }
            phase = "reply-frame"
            let reply = try request.reply(cdHash: fields.cdHash, build: fields.build, runtimeSHA256: DirectUpdateRuntimePins.runtimeDigest, auditRecordDigest: audit?.1)
            try writeExactly(reply)
            // Real EOF seals the reply. Neither output nor logging can append a
            // second frame while owner records ACK. Continue is private stdin.
            close(STDOUT_FILENO); close(STDERR_FILENO)
            phase = "continue"
            guard try readExactly(36) == request.continuation, try readEOF() else { throw DirectUpdateInstallSessionError.handoff }
            if let auditDirectory {
                let fresh = try DirectUpdateAuditRecord.load(directory: auditDirectory, request: request)
                guard fresh?.1 == audit?.1 else { throw DirectUpdateInstallSessionError.custody }
            }
            try audit?.0.validate()
            #if DEBUG
            if qa && !qaContinues { exit(0) }
            #endif
            // Owner released fences after durable ACK. Ordinary admission below
            // still checks the actual installed pathname and pending journal.
            return audit?.0
        } catch {
            #if DEBUG
            recordQualificationRefusal(phase)
            #else
            _ = phase
            #endif
            exit(EX_NOPERM)
        }
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
    /// Enum-stage diagnostic in an explicitly marked private transaction QA
    /// root only. No user paths, errors, values or profile data are serialized.
    static func recordQualificationRefusal(_ phase: String) {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.update-bootstrap-qa", let app = try? ownApp() else { return }
        let url = app.deletingLastPathComponent().deletingLastPathComponent(), prefix = "neantik-update-transaction-"
        guard url.deletingLastPathComponent().path == "/private/tmp", url.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))),
              url.lastPathComponent == prefix + id.uuidString.lowercased(), let fd = try? BackupFS.directory(url) else { return }
        defer { close(fd) }
        guard let identity = try? BackupFS.identity(fd), identity.mode & 0o7777 == 0o700 else { return }
        let marker = openat(fd, "fixture.marker", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard marker >= 0 else { return }; defer { close(marker) }
        let expected = Data("isolated-real-update-transaction-qa\n".utf8)
        guard let file = try? BackupFS.identity(marker), (try? file.validateFile(device: identity.device)) != nil,
              file.mode & 0o777 == 0o600, file.size == expected.count,
              (try? BackupFS.read(marker, at: 0, count: expected.count)) == expected else { return }
        let output = openat(fd, "bootstrap.refusal", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return }; defer { close(output) }
        try? BackupFS.write(output, Data((phase + "\n").utf8), at: 0)
    }
    /// Explicit signed fixture only. Ordinary QA startup uses the existing
    /// development memory-only credential backend, never system Keychain.
    private static func disposableContinuation(_ app: URL) throws -> Bool {
        guard let path = Bundle(url: app)?.object(forInfoDictionaryKey: "NeAntikDevelopmentFixtureRoot") as? String else { return false }
        let url = URL(fileURLWithPath: path), prefix = "neantik-dev-fixture."
        guard url.deletingLastPathComponent().path == "/private/tmp", url.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))),
              url.lastPathComponent == prefix + id.uuidString.lowercased(),
              Bundle(url: app)?.object(forInfoDictionaryKey: "NeAntikBrowserDataBackupEnabled") as? Bool != true else {
            throw DirectUpdateInstallSessionError.custody
        }
        let fd = try BackupFS.directory(url); defer { close(fd) }
        let identity = try BackupFS.identity(fd)
        guard identity.mode & 0o7777 == 0o700 else { throw DirectUpdateInstallSessionError.custody }
        let marker = openat(fd, "update-continuation.marker", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard marker >= 0 else { throw DirectUpdateInstallSessionError.custody }; defer { close(marker) }
        let file = try BackupFS.identity(marker); try file.validateFile(device: identity.device)
        let expected = Data("isolated-update-gui-continuation\n".utf8)
        guard file.mode & 0o777 == 0o600, file.size == expected.count,
              try BackupFS.read(marker, at: 0, count: expected.count) == expected,
              try BackupFS.identity(marker) == file, try BackupFS.entry(fd, "update-continuation.marker") == file else {
            throw DirectUpdateInstallSessionError.custody
        }
        try BackupFS.validateDirectoryPath(url, identity)
        return true
    }
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
