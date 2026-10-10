import CryptoKit
import Foundation
import ObjectiveC
import Testing
@testable import NeAntik

struct ProfileBackupLiveRestoreRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_LIVE_RESTORE_FIXTURE"] == "1"))
    @MainActor func actualExportAndAtomicRestoreOfClosedHeadedProfile() async throws {
        let env = ProcessInfo.processInfo.environment
        let text = try #require(env["NEANTIK_LIVE_RESTORE_ROOT"]), phase = try #require(env["NEANTIK_LIVE_RESTORE_PHASE"])
        guard text.hasPrefix("/private/tmp/neantik-live-restore-fixture-"), !text.dropFirst("/private/tmp/".count).contains("/"),
              ["prepare", "export", "restore", "interrupt", "recover"].contains(phase) else { throw BrowserDataBackupStorageError.unsafeEntry }
        let imageName = try #require(class_getImageName(LiveRestoreRuntimeImageMarker.self))
        let image = URL(fileURLWithPath: String(cString: imageName))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard image.path.hasPrefix(repository.appendingPathComponent(".swiftpm-major-validation").path + "/") else { throw BrowserDataBackupStorageError.unsafeEntry }
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: text, isDirectory: true))
        let marker = paths.rootDirectory.appendingPathComponent("live-restore-fixture.json")
        if phase == "prepare" {
            try paths.prepareBaseDirectories()
            guard !FileManager.default.fileExists(atPath: marker.path) else { throw BrowserDataBackupStorageError.changed }
            let store = ProfileStore(paths: paths)
            let profile = try store.upsert(BrowserProfile(name: "Own live restore fixture"))
            try paths.writePrivateFile(JSONSerialization.data(withJSONObject: [
                "profileID": profile.id.uuidString, "browserData": paths.browserDataDirectory(for: profile.id).path,
                "seed": profile.identity.runtimeSeed, "syntheticOnly": true, "systemKeychainUsed": false,
                "loadedTestImageSHA256": Self.hash(try Data(contentsOf: image))
            ]), to: marker)
            return
        }
        try paths.validatePrivateFile(marker)
        let markerBytes = try Data(contentsOf: marker)
        guard markerBytes.count < 4096, let object = try JSONSerialization.jsonObject(with: markerBytes) as? [String: Any],
              object["syntheticOnly"] as? Bool == true, object["systemKeychainUsed"] as? Bool == false,
              let idText = object["profileID"] as? String, let id = UUID(uuidString: idText),
              object["browserData"] as? String == paths.browserDataDirectory(for: id).path,
              object["loadedTestImageSHA256"] as? String == Self.hash(try Data(contentsOf: image)) else { throw BrowserDataBackupStorageError.changed }
        let store = ProfileStore(paths: paths), manager = BrowserProcessManager(paths: paths)
        let executable = try #require(env["NEANTIK_LIVE_RESTORE_RUNTIME_EXE"])
        guard executable.hasPrefix(repository.deletingLastPathComponent().appendingPathComponent("artifacts/neantik/looper-goals/20261008-fury-major/m156-attempt9-developer-id-research-runtime").path + "/") else { throw BrowserDataBackupStorageError.unsafeEntry }
        let fault = LiveRestorePendingContextFault(paths: paths, enabled: phase == "interrupt")
        let service = ProfileBrowserDataBackupService(paths: paths, processes: manager,
            scope: BackupCompatibilityScopeStore(backend: LiveRestoreFixtureScopeBackend(paths: paths)), inspectRuntime: {
                let value = BrowserRuntimeInspector.inspect(executableURL: URL(fileURLWithPath: executable))
                guard value.executableSHA256 == "c8c11b4d846dd09e16f3aa63c28971e71f6e252bd851bf414969cfdd960976ba",
                      value.frameworkSHA256 == "6bf721015bea252f0d09ae8092642634ce16f929057a1ce757869f45cebdd616" else { throw BrowserDataBackupStorageError.changed }
                return value
            })
        if phase == "recover" {
            #expect(!store.hasTrustedMetadata)
            #expect(await service.pendingRecoveryRequired())
            let originalMetadata = paths.rootDirectory.appendingPathComponent("own-before-interruption.json")
            try paths.validatePrivateFile(originalMetadata)
            let result = try await service.recoverPending()
            #expect(!result.restored)
            #expect(try Data(contentsOf: paths.profilesFile) == Data(contentsOf: originalMetadata))
            try await store.refreshExternalMetadata(force: true)
            #expect(store.hasTrustedMetadata)
            try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
            try paths.writePrivateFile(JSONEncoder().encode([
                "loadedTestImageSHA256": Self.hash(try Data(contentsOf: image)),
                "productServiceUsed": "true", "freshProcessRecovered": "true",
                "rolledBackBeforeDecision": "true", "metadataRestored": "true",
                "systemKeychainUsed": "false"
            ]), to: paths.rootDirectory.appendingPathComponent("live-restore-recover-receipt.json"))
            return
        }
        let profile = try #require(store.profile(withID: id))
        let archive = paths.rootDirectory.appendingPathComponent("own.nabackup")
        let passwordFile = paths.rootDirectory.appendingPathComponent("own-ephemeral-backup-password")
        let result: [String: String]
        if phase == "interrupt" {
            try paths.validatePrivateFile(passwordFile)
            let password = try #require(String(data: Data(contentsOf: passwordFile), encoding: .utf8))
            try paths.writePrivateFile(Data(contentsOf: paths.profilesFile), to: paths.rootDirectory.appendingPathComponent("own-before-interruption.json"))
            let interrupted = ProfileBrowserDataBackupService(paths: paths, processes: manager,
                scope: BackupCompatibilityScopeStore(backend: LiveRestoreFixtureScopeBackend(paths: paths)), inspectRuntime: {
                    let value = BrowserRuntimeInspector.inspect(executableURL: URL(fileURLWithPath: executable))
                    try fault.check()
                    return value
                })
            do {
                _ = try await interrupted.restore(profileID: id, expectedRevision: profile.revision, archive: archive, password: password)
                Issue.record("Late context failure was ignored")
            } catch { #expect(error as? BrowserDataBackupStorageError == .incompatibleContext) }
            #expect(fault.triggered)
            #expect(await interrupted.pendingRecoveryRequired())
            let reopened = ProfileStore(paths: paths)
            #expect(!reopened.hasTrustedMetadata)
            result = ["faultAfterPendingPrevious": "true", "pendingFenceRetained": "true", "ordinaryStoreRefused": "true", "liveRestoreCommitted": "false"]
        } else if phase == "export" {
            let password = UUID().uuidString + UUID().uuidString
            let manifest = try await service.export(profileID: id, expectedRevision: profile.revision, destination: archive, password: password)
            try paths.writePrivateFile(Data(password.utf8), to: passwordFile)
            result = ["entries": String(manifest.entries.count), "archiveSHA256": Self.hash(try Data(contentsOf: archive)), "liveRestoreCommitted": "false"]
        } else {
            try paths.validatePrivateFile(passwordFile)
            let passwordBytes = try Data(contentsOf: passwordFile)
            guard passwordBytes.count < 256, let password = String(data: passwordBytes, encoding: .utf8) else { throw BrowserDataBackupStorageError.changed }
            let retainedBefore = try FileManager.default.contentsOfDirectory(atPath: paths.profileDirectory(for: id).path).filter { $0.hasPrefix(".neantik-backup-restore-") }.count
            let restored = try await service.restore(profileID: id, expectedRevision: profile.revision, archive: archive, password: password)
            let next = try Data(contentsOf: paths.profilesFile)
            guard restored.restored, try Data(contentsOf: paths.profilesBackupFile) == next else { throw BrowserDataBackupStorageError.changed }
            let decoded = try #require(ProfileStore.decodeProfiles(next).first { $0.id == id })
            guard decoded.identity == profile.identity, decoded.proxy == profile.proxy,
                  decoded.revision == profile.revision + 1 else { throw BrowserDataBackupStorageError.changed }
            let retained = try FileManager.default.contentsOfDirectory(atPath: paths.profileDirectory(for: id).path).filter { $0.hasPrefix(".neantik-backup-restore-") }
            guard retained.count == retainedBefore + 1 else { throw BrowserDataBackupStorageError.changed }
            result = ["archiveSHA256": Self.hash(try Data(contentsOf: archive)), "liveRestoreCommitted": "true",
                "metadataRevisionAdvanced": "true", "identityUnchanged": "true", "proxyUnchanged": "true",
                "mainAndPreviousMatch": "true", "oldTreeRetained": "true"]
        }
        var receipt = result
        receipt["loadedTestImageSHA256"] = Self.hash(try Data(contentsOf: image))
        receipt["heldStoppedAuthority"] = "true"; receipt["heldMetadataGuard"] = "true"
        receipt["productServiceUsed"] = "true"; receipt["freshRuntimeInspectionUsed"] = "true"
        receipt["scopeBackend"] = "owned-private-fixture-only"
        receipt["systemKeychainUsed"] = "false"
        try paths.writePrivateFile(JSONEncoder().encode(receipt), to: paths.rootDirectory.appendingPathComponent("live-restore-\(phase)-receipt.json"))
    }
    private static func hash(_ data: Data) -> String { BackupFS.hex(SHA256.hash(data: data)) }
}
private final class LiveRestoreRuntimeImageMarker: NSObject {}

/// Own-fixture context failure at a real durable publication boundary. No
/// production filesystem hook and no alteration of runtime/signature policy.
private final class LiveRestorePendingContextFault: @unchecked Sendable {
    private let paths: AppPaths
    private let enabled: Bool
    private let lock = NSLock()
    private var didTrigger = false
    init(paths: AppPaths, enabled: Bool) { self.paths = paths; self.enabled = enabled }
    var triggered: Bool { lock.lock(); defer { lock.unlock() }; return didTrigger }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !didTrigger,
              let bytes = try? Data(contentsOf: paths.profilesBackupFile),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["state"] as? String == "restorePending" else { return }
        didTrigger = true
        throw BrowserDataBackupStorageError.incompatibleContext
    }
}

// Explicit own-fixture backend, never a production Keychain operation. This
// proves service restart persistence; it does not qualify DP Keychain access.
private struct LiveRestoreFixtureScopeBackend: BackupCompatibilityScopeBackend {
    let paths: AppPaths
    private var file: URL { paths.rootDirectory.appendingPathComponent("own-ephemeral-backup-scope") }
    func read() throws -> Data? {
        switch try paths.privateFileEntryKind(file) {
        case .missing: return nil
        case .unsafe: throw BrowserDataBackupStorageError.unsafeEntry
        case .regular: try paths.validatePrivateFile(file); return try Data(contentsOf: file)
        }
    }
    func insertIfAbsent(_ bytes: Data) throws -> Bool {
        guard try read() == nil else { return false }
        try paths.writePrivateFile(bytes, to: file)
        return true
    }
}
