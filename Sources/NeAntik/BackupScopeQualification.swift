#if DEBUG
import Darwin
import CryptoKit
import Foundation
import Security

/// Separate signed QA identity and UUID namespace. This runner never opens
/// production storage or Keychain services. Data phases use only the bound
/// synthetic root and the actual backup service. It has no file fallback.
enum BackupScopeQualification {
    static let argument = "--neantik-qualify-backup-scope-v1"
    static let bundleIdentifier = BackupGUIQualificationContext.bundleIdentifier
    static let accessGroup = BackupGUIQualificationContext.accessGroup
    static func scopeService(_ runID: UUID) -> String {
        bundleIdentifier + ".browser-data-backup-scope." + runID.uuidString.lowercased()
    }
    enum Phase: String, Codable {
        case create, read, removeOwnedItem, assertMissing
        case createProxyFixture, readProxyFixture, removeProxyFixture, assertProxyFixtureMissing
        case prepareData, exportData, restoreData, wrongPassword, corruptArchive, missingScopeData, interruptBeforeDecision, interruptAfterDecision, recoverData
    }
    struct Request: Codable {
        let runID: UUID
        let phase: Phase
        var expectedDigest: String? = nil
        var root: String? = nil
        var password: String? = nil
    }
    struct Result: Codable {
        var passed: Bool
        let status: OSStatus?
        // Only a private pipe receipt; never archive the device-scope digest.
        let digest: String?
        var profileID: UUID? = nil
        var entries: Int? = nil
        var runtimeExecutableSHA256: String? = nil
        var runtimeFrameworkSHA256: String? = nil
        var runtimeVersion: String? = nil
        var failureCategory: String? = nil
    }
    enum Failure: Error { case invalidIdentity, invalidRequest, unexpectedItem }

    /// Bounded QA operation labels locate native failures without returning
    /// service names, account identifiers, credentials or localized messages.
    struct ProxyFixtureFailure: Error {
        let stage: String
        let status: OSStatus
    }
    private struct ProxyFixtureBackend: KeychainBackend {
        let raw = SecurityKeychainBackend()
        func label(_ service: String) -> String {
            if service.hasSuffix(".current-a") { return "currentA" }
            if service.hasSuffix(".current-b") { return "currentB" }
            return "legacyB"
        }
        func data(service: String, profileID: UUID) throws -> Data? {
            do { return try raw.data(service: service, profileID: profileID) }
            catch let error as KeychainError {
                throw ProxyFixtureFailure(stage: "read." + label(service), status: error.status)
            }
        }
        func upsert(_ data: Data, service: String, profileID: UUID) throws {
            do { try raw.upsert(data, service: service, profileID: profileID) }
            catch let error as KeychainError {
                throw ProxyFixtureFailure(stage: "upsert." + label(service), status: error.status)
            }
        }
        func delete(service: String, profileID: UUID) throws {
            do { try raw.delete(service: service, profileID: profileID) }
            catch let error as KeychainError {
                throw ProxyFixtureFailure(stage: "delete." + label(service), status: error.status)
            }
        }
    }

    static func validate(_ request: Request, bundleID: String?) throws {
        guard bundleID == bundleIdentifier else { throw Failure.invalidIdentity }
        switch request.phase {
        case .create, .assertMissing, .prepareData, .createProxyFixture, .assertProxyFixtureMissing:
            guard request.expectedDigest == nil else { throw Failure.invalidRequest }
        case .read, .removeOwnedItem, .exportData, .restoreData, .wrongPassword, .corruptArchive, .missingScopeData, .interruptBeforeDecision, .interruptAfterDecision, .recoverData, .readProxyFixture, .removeProxyFixture:
            guard let digest = request.expectedDigest, digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw Failure.invalidRequest }
        }
        if isDataPhase(request.phase) {
            guard request.root == dataRoot(request.runID).path else { throw Failure.invalidRequest }
            if request.phase == .prepareData {
                guard request.password == nil else { throw Failure.invalidRequest }
            } else {
                guard let password = request.password, (16...256).contains(password.utf8.count) else { throw Failure.invalidRequest }
            }
        } else {
            guard request.root == nil, request.password == nil else { throw Failure.invalidRequest }
        }
    }

    static func runAndExit() -> Never {
        Task.detached {
            do {
                try ProxyRelayPrivatePipe.prepare(STDIN_FILENO, writable: false)
                try ProxyRelayPrivatePipe.prepare(STDOUT_FILENO, writable: true)
                let request = try JSONDecoder().decode(Request.self, from: ProxyRelayPrivatePipe.readFrame(STDIN_FILENO, timeout: 5))
                try validate(request, bundleID: Bundle.main.bundleIdentifier)
                let result: Result
                do {
                    result = isDataPhase(request.phase) ? try await performData(request) : try perform(request)
                }
                catch let error as ProxyFixtureFailure {
                    result = .init(passed: false, status: error.status, digest: nil, failureCategory: "ProxyFixture." + error.stage)
                }
                catch let error as KeychainError { result = .init(passed: false, status: error.status, digest: nil) }
                catch {
                    result = .init(passed: false, status: nil, digest: nil, failureCategory: redactedFailureCategory(error))
                }
                try ProxyRelayPrivatePipe.writeFrame(STDOUT_FILENO, data: JSONEncoder().encode(result), timeout: 2)
                Darwin.exit(EX_OK)
            } catch {
                FileHandle.standardError.write(Data("backup_scope_qualification_failed\n".utf8))
                Darwin.exit(EX_NOPERM)
            }
        }
        dispatchMain()
    }

    /// Static failure categories only: no localized paths, private requests,
    /// scope digests or arbitrary NSError userInfo enter a qualification report.
    static func redactedFailureCategory(_ error: Error) -> String {
        if let error = error as? BrowserProfileDeletionBlockedError { return "Admission." + String(describing: error.reason) }
        if let error = error as? BrowserDataBackupStorageError { return "Storage." + String(describing: error) }
        if let error = error as? BrowserDataRestoreError { return "Restore." + String(describing: error) }
        if let error = error as? Failure { return "Qualification." + String(describing: error) }
        return String(reflecting: Swift.type(of: error))
    }

    private static func perform(_ request: Request) throws -> Result {
        if [.createProxyFixture, .readProxyFixture, .removeProxyFixture, .assertProxyFixtureMissing].contains(request.phase) {
            return try performProxyFixture(request)
        }
        let service = scopeService(request.runID)
        let backend = SecurityBackupCompatibilityScopeBackend(service: service, accessGroup: accessGroup)
        let store = BackupCompatibilityScopeStore(backend: backend)
        switch request.phase {
        case .create:
            guard try backend.read() == nil else { throw Failure.unexpectedItem }
            let digest = try store.digest(createForExport: true)
            guard try store.digest(createForExport: false) == digest else { throw Failure.unexpectedItem }
            return .init(passed: true, status: nil, digest: digest)
        case .read:
            return .init(passed: try store.digest(createForExport: false) == request.expectedDigest, status: nil, digest: nil)
        case .removeOwnedItem:
            guard try store.digest(createForExport: false) == request.expectedDigest else { throw Failure.unexpectedItem }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "browser-data-backup-scope-v1",
                kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
                kSecAttrAccessGroup as String: accessGroup]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            return .init(passed: try backend.read() == nil, status: nil, digest: nil)
        case .assertMissing:
            guard try backend.read() == nil else { throw Failure.unexpectedItem }
            do { _ = try store.digest(createForExport: false); return .init(passed: false, status: nil, digest: nil) }
            catch BackupCompatibilityScopeError.unavailable {
                return .init(passed: try backend.read() == nil, status: nil, digest: nil)
            }
        default: throw Failure.invalidRequest
        }
    }

    /// Actual legacy file-Keychain backend, only UUID-scoped QA services. It
    /// proves existing ACL access/migration across signatures without touching
    /// production services, groups, credentials or the DP backup scope.
    private static func performProxyFixture(_ request: Request) throws -> Result {
        let backend = ProxyFixtureBackend(), id = request.runID
        let prefix = bundleIdentifier + ".proxy-upgrade." + id.uuidString.lowercased()
        let currentA = prefix + ".current-a", currentB = prefix + ".current-b", legacyB = prefix + ".legacy-b"
        let services = [currentA, currentB, legacyB]
        func digest(_ a: Data, _ b: Data) -> String {
            SHA256.hash(data: a + Data([0]) + b).map { String(format: "%02x", $0) }.joined()
        }
        func existingPair() throws -> (Data, Data) {
            guard let a = try backend.data(service: currentA, profileID: id),
                  let b = try backend.data(service: currentB, profileID: id) ?? backend.data(service: legacyB, profileID: id)
            else { throw Failure.unexpectedItem }
            return (a, b)
        }
        switch request.phase {
        case .createProxyFixture:
            for service in services {
                guard try backend.data(service: service, profileID: id) == nil else { throw Failure.unexpectedItem }
            }
            let a = Data(UUID().uuidString.utf8), b = Data(UUID().uuidString.utf8)
            do {
                try backend.upsert(a, service: currentA, profileID: id)
                try backend.upsert(b, service: legacyB, profileID: id)
                let pair = try existingPair()
                guard pair.0 == a, pair.1 == b else { throw Failure.unexpectedItem }
                return .init(passed: true, status: nil, digest: digest(a, b))
            } catch {
                for service in services { try? backend.delete(service: service, profileID: id) }
                throw error
            }
        case .readProxyFixture:
            let pair = try existingPair()
            guard digest(pair.0, pair.1) == request.expectedDigest else { throw Failure.unexpectedItem }
            let first = try KeychainStore(backend: backend, service: currentA, legacyService: nil).proxyPassword(profileID: id)
            let second = try KeychainStore(backend: backend, service: currentB, legacyService: legacyB).proxyPassword(profileID: id)
            guard first.map({ Data($0.utf8) }) == pair.0, second.map({ Data($0.utf8) }) == pair.1,
                  try backend.data(service: currentA, profileID: id) == pair.0,
                  try backend.data(service: currentB, profileID: id) == pair.1,
                  try backend.data(service: legacyB, profileID: id) == nil else { throw Failure.unexpectedItem }
            return .init(passed: true, status: nil, digest: nil)
        case .removeProxyFixture:
            let pair = try existingPair()
            guard digest(pair.0, pair.1) == request.expectedDigest else { throw Failure.unexpectedItem }
            for service in services { try backend.delete(service: service, profileID: id) }
            fallthrough
        case .assertProxyFixtureMissing:
            for service in services {
                guard try backend.data(service: service, profileID: id) == nil else { throw Failure.unexpectedItem }
            }
            return .init(passed: true, status: nil, digest: nil)
        default: throw Failure.invalidRequest
        }
    }

    static func dataRoot(_ runID: UUID) -> URL {
        URL(fileURLWithPath: "/private/tmp/neantik-backup-service-qa-" + runID.uuidString.lowercased(), isDirectory: true)
    }
    private static func isDataPhase(_ phase: Phase) -> Bool {
        [.prepareData, .exportData, .restoreData, .wrongPassword, .corruptArchive, .missingScopeData, .interruptBeforeDecision, .interruptAfterDecision, .recoverData].contains(phase)
    }

    /// Calls the actual storage service in a separately signed process. The
    /// harness owns the browser lifecycle; normal process inspection remains
    /// enabled and refuses live or unknown browser owners.
    @MainActor private static func performData(_ request: Request) async throws -> Result {
        let root = dataRoot(request.runID)
        let directory = try BackupFS.directory(root)
        defer { Darwin.close(directory) }
        let paths = AppPaths(rootDirectory: root)
        let marker = root.appendingPathComponent("qa-profile-id")
        if request.phase == .prepareData {
            guard try BackupFS.names(directory).isEmpty else { throw Failure.unexpectedItem }
            let store = ProfileStore(paths: paths)
            let profile = try store.upsert(BrowserProfile(name: "Synthetic signed backup QA"))
            try paths.writePrivateFile(Data(profile.id.uuidString.utf8), to: marker)
            return .init(passed: true, status: nil, digest: nil, profileID: profile.id)
        }
        try paths.validatePrivateFile(marker)
        let bytes = try Data(contentsOf: marker)
        guard bytes.count == 36, let text = String(data: bytes, encoding: .utf8), let id = UUID(uuidString: text),
              let resources = Bundle.main.resourceURL,
              let browser = Bundle(url: resources.appendingPathComponent("NeAntik Browser.app"))?.executableURL
        else { throw Failure.invalidRequest }
        let store = ProfileStore(paths: paths)
        guard let password = request.password else { throw Failure.unexpectedItem }
        let profile = store.profile(withID: id)
        guard request.phase == .recoverData || (store.hasTrustedMetadata && profile != nil) else { throw Failure.unexpectedItem }
        let scope = BackupCompatibilityScopeStore(backend: SecurityBackupCompatibilityScopeBackend(
            service: scopeService(request.runID), accessGroup: accessGroup))
        if request.phase != .missingScopeData {
            guard try scope.digest(createForExport: false) == request.expectedDigest else { throw Failure.unexpectedItem }
        }
        let runtime = await Task.detached { BrowserRuntimeInspector.inspect(executableURL: browser) }.value
        let service = ProfileBrowserDataBackupService(paths: paths, processes: BrowserProcessManager(paths: paths), scope: scope,
            inspectRuntime: { BrowserRuntimeInspector.inspect(executableURL: browser) }, restoreFault: { point in
                if (request.phase == .interruptBeforeDecision && point == .swapped) ||
                   (request.phase == .interruptAfterDecision && point == .rollForwardRequired) {
                    // Terminate the real signed service process after fsync,
                    // without unwinding cleanup. Only the validated QA mode.
                    Darwin._exit(86)
                }
            })
        let archive = root.appendingPathComponent("qa.nabackup")
        var result = Result(passed: false, status: nil, digest: nil, profileID: id,
            runtimeExecutableSHA256: runtime.executableSHA256, runtimeFrameworkSHA256: runtime.frameworkSHA256, runtimeVersion: runtime.version)
        if request.phase == .recoverData {
            let preview = try await service.inspectPendingRecovery()
            guard preview.context.profileID == id else { throw Failure.unexpectedItem }
            let recovered = try await service.recoverPending()
            try BrowserDataRestoreTransaction.requireNoPending(rootURL: root)
            result.passed = recovered.profileID == id
            result.entries = recovered.restored ? 1 : 0
        } else if request.phase == .exportData {
            let manifest = try await service.export(profileID: id, expectedRevision: profile!.revision, destination: archive, password: password)
            result.entries = manifest.entries.count
            result.passed = !manifest.entries.isEmpty
        } else if request.phase == .restoreData || request.phase == .interruptBeforeDecision || request.phase == .interruptAfterDecision {
            let restored = try await service.restore(profileID: id, expectedRevision: profile!.revision, archive: archive, password: password)
            let next = try ProfileStore.decodeProfiles(Data(contentsOf: paths.profilesFile))
            let main = try Data(contentsOf: paths.profilesFile)
            let previous = try Data(contentsOf: paths.profilesBackupFile)
            result.passed = restored.restored && next.first(where: { $0.id == id })?.identity == profile!.identity &&
                next.first(where: { $0.id == id })?.revision == profile!.revision + 1 &&
                main == previous
        } else {
            let before = try Data(contentsOf: paths.profilesFile)
            let tree = try BackupTree.capture(paths.browserDataDirectory(for: id)); defer { tree.close() }
            let contents = tree.entries
            let input = request.phase == .corruptArchive ? root.appendingPathComponent("qa-tampered.nabackup") : archive
            do {
                _ = try await service.restore(profileID: id, expectedRevision: profile!.revision, archive: input,
                    password: request.phase == .wrongPassword ? password + "-incorrect" : password)
            } catch EncryptedBackupError.authenticationFailed {
                let after = try BackupTree.capture(paths.browserDataDirectory(for: id)); defer { after.close() }
                try BrowserDataRestoreTransaction.requireNoPending(rootURL: root)
                let metadataAfter = try Data(contentsOf: paths.profilesFile)
                result.passed = contents == after.entries && before == metadataAfter
            } catch BackupCompatibilityScopeError.unavailable {
                guard request.phase == .missingScopeData else { throw BackupCompatibilityScopeError.unavailable }
                let after = try BackupTree.capture(paths.browserDataDirectory(for: id)); defer { after.close() }
                let metadataAfter = try Data(contentsOf: paths.profilesFile)
                let backend = SecurityBackupCompatibilityScopeBackend(service: scopeService(request.runID), accessGroup: accessGroup)
                let missing = try backend.read() == nil
                try BrowserDataRestoreTransaction.requireNoPending(rootURL: root)
                result.passed = contents == after.entries && before == metadataAfter && missing
            }
        }
        return result
    }
}
#endif
