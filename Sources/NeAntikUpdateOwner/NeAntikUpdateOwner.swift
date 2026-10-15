import Darwin
import CryptoKit
import DirectInstallFilesystem
import DirectUpdateCore
import Foundation
import Security

/// Independent executable outside the two application slots. Installation is
/// deliberately unavailable until authenticated bootstrap/stopped authority
/// and premigration readiness have their real-process qualification.
@main enum NeAntikUpdateOwner {
    static func main() async {
        if CommandLine.arguments == [CommandLine.arguments[0], "--neantik-update-owner-v1"] {
            // Fixed production mode authenticates the actual live parent and
            // itself before reading any input. No DEBUG policy is accepted.
            do { try await DirectUpdateOwnerOperation.run(); exit(0) }
            catch { DirectUpdateOwnerDiagnostics.refused(error); exit(EX_NOPERM) }
        }
        #if DEBUG
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { exit(64) }
        if ["--qa-install", "--qa-install-refuse", "--qa-install-cancel", "--qa-install-before-ack", "--qa-install-after-ack", "--qa-install-after-finish"].contains(arguments[1]) {
            do { try authenticateQAOwner(); try await runQAInstallation(root: URL(fileURLWithPath: arguments[2]), mode: arguments[1]); exit(0) }
            catch {
                FileHandle.standardError.write(Data("Isolated installation refused.\n".utf8)); exit(1)
            }
        }
        if ["--qa-bootstrap", "--qa-bootstrap-refuse"].contains(arguments[1]) {
            do { try authenticateQAOwner(); try await runQABootstrap(root: URL(fileURLWithPath: arguments[2]), refuse: arguments[1] == "--qa-bootstrap-refuse"); exit(0) }
            catch { exit(1) }
        }
        guard ["--qa-inspect", "--qa-prepare"].contains(arguments[1]) else { exit(64) }
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
        // No QA policy, fixture key or caller-selected install path in Release.
        exit(64)
        #endif
    }

    #if DEBUG
    private static func authenticateQAOwner() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[0])
        let expected = try DirectUpdateEmptyEntitlementCode.inspect(url, identifier: "app.neantik.update-owner-qa").pin
        guard let identity = DirectProcessIdentityInspector.processIdentity(getpid()),
              ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: identity, expectedCode: expected)
        else { throw DirectAssessmentParentError.admission }
    }
    private static func runQAInstallation(root: URL, mode: String) async throws {
        let prefix = "neantik-update-transaction-"
        guard root.deletingLastPathComponent().path == "/private/tmp", root.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))),
              root.lastPathComponent == prefix + id.uuidString.lowercased() else { throw DirectUpdateInstallSessionError.request }
        let directory = try BackupFS.directory(root); defer { close(directory) }
        let identity = try BackupFS.identity(directory)
        guard identity.mode & 0o7777 == 0o700 else { throw DirectUpdateInstallSessionError.custody }
        let marker = openat(directory, "fixture.marker", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard marker >= 0 else { throw DirectUpdateInstallSessionError.request }; defer { close(marker) }
        let markerIdentity = try BackupFS.identity(marker); try markerIdentity.validateFile(device: identity.device)
        let expectedMarker = Data("isolated-real-update-transaction-qa\n".utf8)
        guard markerIdentity.mode & 0o777 == 0o600, markerIdentity.size == expectedMarker.count,
              try BackupFS.read(marker, at: 0, count: expectedMarker.count) == expectedMarker,
              try BackupFS.identity(marker) == markerIdentity, try BackupFS.entry(directory, "fixture.marker") == markerIdentity else {
            throw DirectUpdateInstallSessionError.custody
        }
        let source = root.appendingPathComponent("source"), sourceFD = try BackupFS.directory(source)
        defer { close(sourceFD) }
        let sourceIdentity = try BackupFS.identity(sourceFD), app = source.appendingPathComponent("NeAntik.app")
        let observed = try DirectUpdateEmptyEntitlementCode.inspect(app, identifier: "app.neantik.desktop.update-bootstrap-qa")
        guard let value = observed.build, let build = UInt64(value) else { throw DirectUpdateInstallSessionError.identity }
        func validateCandidate(_ candidate: URL) throws {
            let current = try DirectUpdateEmptyEntitlementCode.inspect(candidate, identifier: "app.neantik.desktop.update-bootstrap-qa")
            guard current.cdHash == observed.cdHash, current.build == observed.build else { throw DirectUpdateInstallSessionError.identity }
        }
        let lease = try InstallFilesystemLease(parentURL: root.appendingPathComponent("install"))
        // This receipt binds QA signed bytes only. It deliberately does not
        // pretend to be a signed shipping manifest/channel admission.
        let receipt = BackupFS.hex(SHA256.hash(data: observed.cdHash))
        let slot = try InstallPreparation.transfer(lease: lease, sourceParentURL: source, sourceParentDescriptor: sourceFD,
            candidateReceiptSHA256: receipt, validateSource: {
                try BackupFS.validateDirectoryPath(source, sourceIdentity); try validateCandidate(app)
            }, didTransfer: {})
        let injected: InstallFilesystemPoint? = switch mode {
            case "--qa-install-before-ack": .beforeAcknowledgementPublication
            case "--qa-install-after-ack": .acknowledgementPublishedBeforeSync
            case "--qa-install-after-finish": .finalizedBeforeSync
            default: nil
        }
        // transfer() has moved the app; read under the retained slot custody.
        let observedRuntime = try slot.withValidatedCandidate { candidate in
            try DirectUpdateRuntimeProvenance.inspectResources(candidate.appendingPathComponent("Contents/Resources"))
        }
        let cancellation = QAInstallCancellation()
        var lastFilesystemPoint = "none"
        var reachedReady = false
        let operation = Task { try await DirectUpdateInstallDriver.run(lease: lease, slot: slot, expectedCode: observed.pin,
            cdHash: observed.cdHash, build: build, runtimeSHA256: observedRuntime.runtimeSHA256,
            validateCandidate: validateCandidate, validateReady: { _ in
                reachedReady = true
                if mode == "--qa-install-refuse" { throw DirectUpdateInstallSessionError.admission }
                if mode == "--qa-install-cancel" { try cancellation.cancel() }
            }, fault: { point in
                lastFilesystemPoint = point.rawValue
                if point == injected { throw DirectUpdateInstallSessionError.io }
            }) }
        cancellation.set(operation)
        let outcome = try await operation.value
        let expectedCommit = !["--qa-install-refuse", "--qa-install-cancel", "--qa-install-before-ack"].contains(mode)
        let report: [String: Any] = ["schema": 1, "actualInstallation": true,
            "committed": outcome.decision.committed, "handedOff": outcome.handedOff,
            "transactionID": outcome.decision.transactionID.uuidString,
            "processID": outcome.processID.map(Int.init) ?? 0,
            "authenticatedReadiness": reachedReady,
            "lastFilesystemPoint": lastFilesystemPoint,
            "failurePhase": outcome.failurePhase ?? "none",
            "refusal": outcome.refusal.map { String(describing: $0) } ?? "none",
            "shippingChannelQualified": false, "productionKeychainUsed": false]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
        guard reachedReady, outcome.decision.committed == expectedCommit, outcome.handedOff == (mode == "--qa-install") else {
            throw DirectUpdateInstallSessionError.handoff
        }
    }
    private static func runQABootstrap(root: URL, refuse: Bool) async throws {
        let prefix = "neantik-update-bootstrap-"
        guard root.deletingLastPathComponent().path == "/private/tmp", root.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))),
              root.lastPathComponent == prefix + id.uuidString.lowercased() else { throw DirectUpdateInstallSessionError.request }
        let directory = try BackupFS.directory(root); defer { close(directory) }
        guard try BackupFS.identity(directory).mode & 0o7777 == 0o700 else { throw DirectUpdateInstallSessionError.custody }
        func read(_ name: String, maximum: Int) throws -> Data {
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw DirectUpdateInstallSessionError.io }; defer { close(fd) }
            let identity = try BackupFS.identity(fd); try identity.validateFile(device: nil)
            guard identity.mode & 0o777 == 0o600, identity.size > 0, identity.size <= maximum else { throw DirectUpdateInstallSessionError.request }
            let bytes = try BackupFS.read(fd, at: 0, count: Int(identity.size))
            guard bytes.count == identity.size, try BackupFS.identity(fd) == identity,
                  try BackupFS.entry(directory, name) == identity else { throw DirectUpdateInstallSessionError.custody }
            return bytes
        }
        guard try read("fixture.marker", maximum: 64) == Data("isolated-premigration-bootstrap-qa\n".utf8) else { throw DirectUpdateInstallSessionError.request }
        let receipt = try JSONDecoder().decode(InstallFilesystemReceipt.self, from: read("receipt.json", maximum: 2_048))
        let app = root.appendingPathComponent("NeAntik.app"), executable = app.appendingPathComponent("Contents/MacOS/NeAntik")
        let appFD = try BackupFS.directory(app); defer { close(appFD) }
        let identity = try BackupFS.identity(appFD)
        guard receipt.candidateDevice == identity.device, receipt.candidateInode == identity.inode else { throw DirectUpdateInstallSessionError.custody }
        var code: SecStaticCode?, dictionary: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data,
              let plist = info[kSecCodeInfoPList as String] as? [String: Any],
              let string = plist["CFBundleVersion"] as? String, let build = UInt64(string) else { throw DirectUpdateInstallSessionError.identity }
        let pin = try ProxyRelayExpectedCode.qualifiedPin(at: app, expectedIdentifier: "app.neantik.desktop.update-bootstrap-qa",
            expectedTeamIdentifier: DirectUpdateCodeSignature.team, expectedCDHash: hash)
        let observedRuntime = try DirectUpdateRuntimeProvenance.inspectResources(app.appendingPathComponent("Contents/Resources"))
        let request = try DirectUpdateBootstrapRequest(receipt: receipt, cdHash: hash, build: build, runtimeSHA256: observedRuntime.runtimeSHA256)
        var retainedReadiness: DirectUpdateCandidateReadiness?
        let pid = try await DirectUpdateInstallSession.run(candidate: executable, request: request, expectedCode: pin,
            validateCustody: {
                try BackupFS.validateDirectoryPath(app, identity)
                guard try BackupFS.identity(appFD) == identity else { throw DirectUpdateInstallSessionError.custody }
                _ = try ProxyRelayExpectedCode.qualifiedPin(at: app, expectedIdentifier: "app.neantik.desktop.update-bootstrap-qa",
                    expectedTeamIdentifier: DirectUpdateCodeSignature.team, expectedCDHash: hash)
            }, onReady: { readiness in
                try readiness.validate(receipt: receipt)
                var changedReceipt = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
                changedReceipt["transactionID"] = UUID().uuidString
                let different = try JSONDecoder().decode(InstallFilesystemReceipt.self, from: JSONSerialization.data(withJSONObject: changedReceipt))
                do { try readiness.validate(receipt: different); throw DirectUpdateInstallSessionError.reply }
                catch DirectUpdateInstallSessionError.admission { }
                retainedReadiness = readiness
                if refuse { throw DirectUpdateInstallSessionError.admission }
                // This QA callback does not commit a transaction. It tests live
                // blocked readiness/continue only; no installation is claimed.
            })
        guard pid > 0 else { throw DirectUpdateInstallSessionError.child }
        guard let retainedReadiness else { throw DirectUpdateInstallSessionError.child }
        do { try retainedReadiness.validate(receipt: receipt); throw DirectUpdateInstallSessionError.reply }
        catch DirectUpdateInstallSessionError.admission { }
        FileHandle.standardOutput.write(Data("{\"authenticatedReadiness\":true,\"handedOff\":true,\"installAuthorized\":false}\n".utf8))
    }
    #endif
}

#if DEBUG
private final class QAInstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Task<DirectUpdateInstallOutcome, Error>?
    func set(_ task: Task<DirectUpdateInstallOutcome, Error>) {
        lock.lock(); operation = task; lock.unlock()
    }
    func cancel() throws {
        lock.lock(); let task = operation; lock.unlock()
        guard let task else { throw DirectUpdateInstallSessionError.admission }
        task.cancel()
    }
}
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
