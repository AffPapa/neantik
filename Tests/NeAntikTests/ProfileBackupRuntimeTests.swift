import CryptoKit
import Foundation
import ObjectiveC
import Testing
@testable import NeAntik

struct ProfileBackupRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_BACKUP_RUNTIME_FIXTURE"] == "1"))
    @MainActor func actualClosedRuntimeExportAndPrivateRestoreStage() async throws {
        let environment = ProcessInfo.processInfo.environment
        let text = try #require(environment["NEANTIK_BACKUP_RUNTIME_ROOT"])
        guard text.hasPrefix("/private/tmp/neantik-cache-runtime-fixture-"),
              !text.dropFirst("/private/tmp/".count).contains("/") else { throw BrowserDataBackupStorageError.unsafeEntry }
        let imageName = try #require(class_getImageName(BackupRuntimeImageMarker.self))
        let image = URL(fileURLWithPath: String(cString: imageName))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard image.path.hasPrefix(repository.appendingPathComponent(".swiftpm-major-validation").path + "/") else { throw BrowserDataBackupStorageError.unsafeEntry }
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: text, isDirectory: true))
        let marker = paths.rootDirectory.appendingPathComponent("cache-runtime-fixture.json")
        try paths.validatePrivateFile(marker)
        let markerBytes = try Data(contentsOf: marker)
        guard markerBytes.count < 4096,
              let object = try JSONSerialization.jsonObject(with: markerBytes) as? [String: Any],
              object["syntheticOnly"] as? Bool == true, object["systemKeychainUsed"] as? Bool == false,
              let idString = object["profileID"] as? String, let id = UUID(uuidString: idString),
              object["browserData"] as? String == paths.browserDataDirectory(for: id).path else { throw BrowserDataBackupStorageError.unsafeEntry }
        let store = ProfileStore(paths: paths)
        let profile = try #require(store.profile(withID: id))
        let manager = BrowserProcessManager(paths: paths)
        let data = paths.browserDataDirectory(for: id)
        let metadataBefore = try Data(contentsOf: paths.profilesFile)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identityHash = Self.hash(try encoder.encode(profile.identity))
        let context = EncryptedBackupArchive.Manifest(profileID: id, identitySHA256: identityHash,
            runtimeExecutableSHA256: "c8c11b4d846dd09e16f3aa63c28971e71f6e252bd851bf414969cfdd960976ba",
            runtimeFrameworkSHA256: "6bf721015bea252f0d09ae8092642634ce16f929057a1ce757869f45cebdd616",
            runtimeVersion: "156.0.8078.12", compatibilityScopeSHA256: Self.hash(Data(text.utf8)), entries: [])
        let result = try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { _ in
            let archive = paths.rootDirectory.appendingPathComponent("owned-browserdata.nabackup")
            let password = UUID().uuidString + UUID().uuidString
            let manifest = try BrowserDataBackupStorage.export(browserData: data, context: context, destination: archive, password: password)
            var badPasswordRejected = false, corruptRejected = false
            do { _ = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: paths.rootDirectory, expectedContext: context, password: "different synthetic password") }
            catch EncryptedBackupError.authenticationFailed { badPasswordRejected = true }
            let corrupted = paths.rootDirectory.appendingPathComponent("owned-corrupt.nabackup")
            var bytes = try Data(contentsOf: archive); bytes[bytes.count - 1] ^= 1; try bytes.write(to: corrupted)
            do { _ = try BrowserDataBackupStorage.prepareRestore(archive: corrupted, parentURL: paths.rootDirectory, expectedContext: context, password: password) }
            catch EncryptedBackupError.authenticationFailed { corruptRejected = true }
            let stage = try BrowserDataBackupStorage.prepareRestore(archive: archive, parentURL: paths.rootDirectory, expectedContext: context, password: password)
            try stage.validatePreparedContents()
            guard badPasswordRejected, corruptRejected, stage.manifest == manifest else { throw BrowserDataBackupStorageError.changed }
            return BackupRuntimeResult(stageName: stage.url.lastPathComponent, entries: manifest.entries.count,
                                       fileBytes: manifest.entries.reduce(UInt64(0)) { $0 + $1.size },
                                       archiveSHA256: Self.hash(try Data(contentsOf: archive)),
                                       badPasswordRejected: badPasswordRejected, corruptRejected: corruptRejected)
        }
        #expect(try Data(contentsOf: paths.profilesFile) == metadataBefore)
        try paths.writePrivateFile(JSONSerialization.data(withJSONObject: [
            "stageName": result.stageName, "entries": result.entries, "fileBytes": result.fileBytes,
            "archiveSHA256": result.archiveSHA256, "badPasswordRejected": result.badPasswordRejected,
            "corruptRejected": result.corruptRejected, "metadataUnchanged": true,
            "heldStoppedAuthority": true, "privateStageOnly": true, "liveRestoreCommitted": false,
            "loadedTestImageSHA256": Self.hash(try Data(contentsOf: image)), "systemKeychainUsed": false
        ]), to: paths.rootDirectory.appendingPathComponent("backup-runtime-result.json"))
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private struct BackupRuntimeResult: Sendable {
    let stageName: String, entries: Int, fileBytes: UInt64, archiveSHA256: String
    let badPasswordRejected: Bool, corruptRejected: Bool
}
private final class BackupRuntimeImageMarker: NSObject {}
