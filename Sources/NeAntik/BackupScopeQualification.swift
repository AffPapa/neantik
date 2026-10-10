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
    static let bundleIdentifier = "app.neantik.desktop.backup-qa"
    enum Phase: String, Codable {
        case create, read, removeOwnedItem, assertMissing
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

    static func validate(_ request: Request, bundleID: String?) throws {
        guard bundleID == bundleIdentifier else { throw Failure.invalidIdentity }
        switch request.phase {
        case .create, .assertMissing, .prepareData:
            guard request.expectedDigest == nil else { throw Failure.invalidRequest }
        case .read, .removeOwnedItem, .exportData, .restoreData, .wrongPassword, .corruptArchive, .missingScopeData, .interruptBeforeDecision, .interruptAfterDecision, .recoverData:
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
                catch let error as KeychainError { result = .init(passed: false, status: error.status, digest: nil) }
                catch {
                    let category: String
                    if let error = error as? BrowserDataBackupStorageError { category = "Storage." + String(describing: error) }
                    else if let error = error as? BrowserDataRestoreError { category = "Restore." + String(describing: error) }
                    else if let error = error as? Failure { category = "Qualification." + String(describing: error) }
                    else { category = String(reflecting: Swift.type(of: error)) }
                    result = .init(passed: false, status: nil, digest: nil, failureCategory: category)
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

    private static func perform(_ request: Request) throws -> Result {
        let service = bundleIdentifier + ".browser-data-backup-scope." + request.runID.uuidString.lowercased()
        let backend = SecurityBackupCompatibilityScopeBackend(service: service)
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
                kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
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
            service: bundleIdentifier + ".browser-data-backup-scope." + request.runID.uuidString.lowercased()))
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
                let backend = SecurityBackupCompatibilityScopeBackend(service: bundleIdentifier + ".browser-data-backup-scope." + request.runID.uuidString.lowercased())
                let missing = try backend.read() == nil
                try BrowserDataRestoreTransaction.requireNoPending(rootURL: root)
                result.passed = contents == after.entries && before == metadataAfter && missing
            }
        }
        return result
    }
}
#endif
