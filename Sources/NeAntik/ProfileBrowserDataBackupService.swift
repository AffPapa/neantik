import CryptoKit
import Darwin
import Foundation

/// Runtime inspection and scope providers are injected so tests use no real
/// Keychain. Production operations require the signed capability selected by
/// BackupApplicationComposition; filesystem code alone grants no authority.
@MainActor final class ProfileBrowserDataBackupService {
    private let paths: AppPaths
    private let processes: BrowserProcessManager
    private let scope: BackupCompatibilityScopeStore
    private let restoreFault: (@Sendable (BrowserDataRestorePoint) throws -> Void)?
    private let inspectRuntime: @Sendable () throws -> BrowserRuntimeInspection
    init(paths: AppPaths, processes: BrowserProcessManager, scope: BackupCompatibilityScopeStore,
         inspectRuntime: @escaping @Sendable () throws -> BrowserRuntimeInspection,
         restoreFault: (@Sendable (BrowserDataRestorePoint) throws -> Void)? = nil) {
        self.paths = paths; self.processes = processes; self.scope = scope; self.inspectRuntime = inspectRuntime; self.restoreFault = restoreFault
    }

    func export(profileID: UUID, expectedRevision: UInt64, destination: URL, password: String) async throws -> EncryptedBackupArchive.Manifest {
        let activity = try ApplicationUpdateAdmission.shared.beginActivity()
        defer { ApplicationUpdateAdmission.shared.finishActivity(activity) }
        let paths = paths, scope = scope, inspect = inspectRuntime
        let retained = paths.profileDirectory(for: profileID).appendingPathComponent(".neantik-backup-restore-" + UUID().uuidString.lowercased())
        return try await processes.withVerifiedStoppedProfileRestore(profileID: profileID, retainedTree: retained) { authority in
            // Hold metadata admission across export: an identity edit must not
            // invalidate the archive while its bytes are being published.
            return try paths.withProfilesMetadataGuardForRestore(authority: authority) {
                try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
                let profile = try Self.snapshot(paths, profileID, expectedRevision).profile
                // Unsupported/stale targets must not inspect another engine or
                // create a device-local backup key before refusing the action.
                try Self.requireSupportedEngine(profile)
                let runtime = try Self.validRuntime(inspect())
                let localScope = try scope.digest(createForExport: true)
                let context = try Self.context(profile, runtime, localScope)
                return try BrowserDataBackupStorage.export(browserData: paths.browserDataDirectory(for: profileID), context: context,
                    destination: destination, password: password, fault: { point in
                        if case .beforePublish = point {
                            try authority.validate(paths: paths, profileID: profileID, retainedTree: retained)
                            guard try Self.validRuntime(inspect()) == runtime,
                                  try scope.digest(createForExport: false) == localScope else { throw BrowserDataBackupStorageError.incompatibleContext }
                        }
                    })
            }
        }
    }

    func restore(profileID: UUID, expectedRevision: UInt64, archive: URL, password: String) async throws -> BrowserDataRestoreTransaction.Result {
        let activity = try ApplicationUpdateAdmission.shared.beginActivity()
        defer { ApplicationUpdateAdmission.shared.finishActivity(activity) }
        let paths = paths, scope = scope, inspect = inspectRuntime, restoreFault = restoreFault
        let retained = paths.profileDirectory(for: profileID).appendingPathComponent(".neantik-backup-restore-" + UUID().uuidString.lowercased())
        return try await processes.withVerifiedStoppedProfileRestore(profileID: profileID, retainedTree: retained) { authority in
            let initial = try paths.withProfilesMetadataGuardForRestore(authority: authority) {
                try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
                let snapshot = try Self.snapshot(paths, profileID, expectedRevision)
                try Self.requireSupportedEngine(snapshot.profile)
                return snapshot
            }
            let runtime = try Self.validRuntime(inspect())
            let localScope = try scope.digest(createForExport: false)
            let context = try Self.context(initial.profile, runtime, localScope)
            let stage = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: paths.profileDirectory(for: profileID),
                expectedContext: context, password: password, stageName: retained.lastPathComponent)
            // Once the journal owns the stage, discard is deliberately inert.
            do {
            guard try Self.validRuntime(inspect()) == runtime,
                  try scope.digest(createForExport: false) == localScope else { throw BrowserDataBackupStorageError.incompatibleContext }
            let result = try paths.withProfilesMetadataGuardForRestore(authority: authority) {
                try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
                let latest = try Self.snapshot(paths, profileID, expectedRevision)
                guard latest.profile.identity == initial.profile.identity, latest.profile.proxy == initial.profile.proxy else {
                    throw BrowserProfileRevisionConflictError(profileID: profileID)
                }
                var profiles = latest.profiles
                let index = try Self.index(profiles, profileID, expectedRevision)
                guard profiles[index].revision < UInt64.max else { throw BrowserDataBackupStorageError.limitExceeded }
                profiles[index].revision += 1; profiles[index].updatedAt = Date()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
                return try BrowserDataRestoreTransaction.commit(paths: paths, stage: stage, expectedMain: latest.bytes,
                    nextDocument: ProfileStore.encodeProfiles(profiles, encoder: encoder), authority: authority, validateContext: {
                        guard try Self.validRuntime(inspect()) == runtime,
                              try scope.digest(createForExport: false) == localScope else { throw BrowserDataBackupStorageError.incompatibleContext }
                    }, fault: restoreFault)
            }
            try stage.discard()
            return result
            } catch {
                do { try stage.discard() } catch { throw BrowserDataBackupStorageError.changed }
                throw error
            }
        }
    }

    /// Cheap conservative UI admission: corrupt/foreign pending intent must
    /// not be mistaken for a cancelled transaction with unchanged live data.
    func pendingRecoveryRequired() async -> Bool {
        guard let activity = try? ApplicationUpdateAdmission.shared.beginActivity() else { return true }
        defer { ApplicationUpdateAdmission.shared.finishActivity(activity) }
        let paths = paths
        return await Task.detached(priority: .utility) {
            do { try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory); return false }
            catch { return true }
        }.value
    }

    func inspectPendingRecovery() async throws -> BrowserDataRestoreTransaction.RecoveryPreview {
        let activity = try ApplicationUpdateAdmission.shared.beginActivity()
        defer { ApplicationUpdateAdmission.shared.finishActivity(activity) }
        let paths = paths
        return try await Task.detached(priority: .utility) { try BrowserDataRestoreTransaction.inspectPending(paths: paths) }.value
    }

    func recoverPending(expected: BrowserDataRestoreTransaction.RecoveryPreview? = nil) async throws -> BrowserDataRestoreTransaction.Result {
        let activity = try ApplicationUpdateAdmission.shared.beginActivity()
        defer { ApplicationUpdateAdmission.shared.finishActivity(activity) }
        let paths = paths, scope = scope, inspect = inspectRuntime
        let preview = try await inspectPendingRecovery()
        // The GUI confirms one pending profile/transaction. A newer journal
        // must not silently replace that choice between preview and action.
        if let expected {
            guard expected.context == preview.context, expected.retainedTree == preview.retainedTree else {
                throw BrowserDataBackupStorageError.incompatibleContext
            }
        }
        return try await processes.withVerifiedStoppedProfileRestore(profileID: preview.context.profileID, retainedTree: preview.retainedTree) { authority in
            let runtime = try Self.validRuntime(inspect())
            let localScope = try scope.digest(createForExport: false)
            guard Self.matches(preview.context, runtime, localScope) else { throw BrowserDataBackupStorageError.incompatibleContext }
            return try paths.withProfilesMetadataGuardForRestore(authority: authority) {
                try BrowserDataRestoreTransaction.recover(paths: paths, expectedContext: preview.context, authority: authority, validateContext: {
                    guard Self.matches(preview.context, try Self.validRuntime(inspect()), try scope.digest(createForExport: false)) else {
                        throw BrowserDataBackupStorageError.incompatibleContext
                    }
                })
            }
        }
    }

    private nonisolated static func snapshot(_ paths: AppPaths, _ id: UUID, _ revision: UInt64) throws -> (bytes: Data, profiles: [BrowserProfile], profile: BrowserProfile) {
        let directory = try BackupFS.directory(paths.rootDirectory); defer { Darwin.close(directory) }
        guard let bytes = try readMetadata(directory, paths.profilesFile.lastPathComponent) else {
            throw BrowserDataBackupStorageError.changed
        }
        let profiles = try ProfileStore.decodeProfiles(bytes)
        return (bytes, profiles, profiles[try index(profiles, id, revision)])
    }
    private nonisolated static func readMetadata(_ root: Int32, _ name: String) throws -> Data? {
        let fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw BackupFS.posix() }
        defer { Darwin.close(fd) }
        let identity = try BackupFS.identity(fd)
        try identity.validateFile(device: nil)
        guard identity.size <= BrowserDataRestoreTransaction.maximumDocumentBytes else { throw BrowserDataBackupStorageError.limitExceeded }
        let bytes = try BackupFS.read(fd, at: 0, count: Int(identity.size))
        guard bytes.count == identity.size, try BackupFS.identity(fd) == identity, try BackupFS.entry(root, name) == identity else {
            throw BrowserDataBackupStorageError.changed
        }
        return bytes
    }
    private nonisolated static func index(_ profiles: [BrowserProfile], _ id: UUID, _ revision: UInt64) throws -> Int {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles[index].revision == revision else {
            throw BrowserProfileRevisionConflictError(profileID: id)
        }
        return index
    }
    private nonisolated static func validRuntime(_ value: BrowserRuntimeInspection) throws -> BrowserRuntimeInspection {
        guard value.codeSignatureValid == true, value.supportsAppleSilicon, let version = value.version,
              let exe = value.executableSHA256, let framework = value.frameworkSHA256 else { throw BrowserDataBackupStorageError.incompatibleContext }
        // Reuse manifest validation for exact version/hash syntax.
        try EncryptedBackupArchive.validate(.init(profileID: UUID(), identitySHA256: exe, runtimeExecutableSHA256: exe,
            runtimeFrameworkSHA256: framework, runtimeVersion: version, compatibilityScopeSHA256: exe, entries: []))
        return value
    }
    private nonisolated static func requireSupportedEngine(_ profile: BrowserProfile) throws {
        // A disposable session must not be made persistent by an export or
        // receive restored state outside its exclusive issuance lifecycle.
        guard profile.engine == .chromium, profile.privacyPolicy.retention == .persistent else {
            throw BrowserDataBackupStorageError.incompatibleContext
        }
    }
    private nonisolated static func context(_ profile: BrowserProfile, _ runtime: BrowserRuntimeInspection, _ scope: String) throws -> EncryptedBackupArchive.Manifest {
        try requireSupportedEngine(profile)
        // Match the transaction's canonical hash of disk-decoded identity,
        // including proxy-context timestamps rounded during ISO8601 storage.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = SHA256.hash(data: try encoder.encode(profile.identity)).map { String(format: "%02x", $0) }.joined()
        return .init(profileID: profile.id, identitySHA256: identity, runtimeExecutableSHA256: runtime.executableSHA256!,
            runtimeFrameworkSHA256: runtime.frameworkSHA256!, runtimeVersion: runtime.version!, compatibilityScopeSHA256: scope, entries: [])
    }
    private nonisolated static func matches(_ manifest: EncryptedBackupArchive.Manifest, _ runtime: BrowserRuntimeInspection, _ scope: String) -> Bool {
        manifest.runtimeExecutableSHA256 == runtime.executableSHA256 && manifest.runtimeFrameworkSHA256 == runtime.frameworkSHA256 &&
            manifest.runtimeVersion == runtime.version && manifest.compatibilityScopeSHA256 == scope
    }
}
