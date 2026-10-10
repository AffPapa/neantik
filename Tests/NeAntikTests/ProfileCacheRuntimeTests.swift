import CryptoKit
import Foundation
import ObjectiveC
import Testing
@testable import NeAntik

struct ProfileCacheRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_CACHE_RUNTIME_FIXTURE"] == "1"))
    @MainActor func actualClosedRuntimeCacheOperation() async throws {
        let environment = ProcessInfo.processInfo.environment
        let text = try #require(environment["NEANTIK_CACHE_RUNTIME_ROOT"])
        guard text.hasPrefix("/private/tmp/neantik-cache-runtime-fixture-"),
              !text.dropFirst("/private/tmp/".count).contains("/"),
              let phase = environment["NEANTIK_CACHE_RUNTIME_PHASE"], ["prepare", "clear", "clear-recovery"].contains(phase)
        else { throw ProfileCacheError.unsafeEntry }
        let imageName = try #require(class_getImageName(CacheRuntimeImageMarker.self))
        let executable = URL(fileURLWithPath: String(cString: imageName))
        let sourceRepository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard executable.path.hasPrefix(sourceRepository.appendingPathComponent(".swiftpm-major-validation").path + "/") else { throw ProfileCacheError.unsafeEntry }
        let executingTestSHA256 = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: text, isDirectory: true))
        try paths.prepareBaseDirectories()
        let marker = paths.rootDirectory.appendingPathComponent("cache-runtime-fixture.json")
        if phase == "prepare" {
            guard !FileManager.default.fileExists(atPath: marker.path) else { throw ProfileCacheError.changed }
            let store = ProfileStore(paths: paths)
            let profile = try store.upsert(BrowserProfile(name: "Owned cache runtime fixture"))
            try paths.writePrivateFile(JSONSerialization.data(withJSONObject: [
                "profileID": profile.id.uuidString, "browserData": paths.browserDataDirectory(for: profile.id).path,
                "syntheticOnly": true, "systemKeychainUsed": false
            ]), to: marker)
        } else {
            try paths.validatePrivateFile(marker)
            let markerBytes = try Data(contentsOf: marker)
            guard markerBytes.count < 4_096,
                  let record = try JSONSerialization.jsonObject(with: markerBytes) as? [String: Any],
                  record["syntheticOnly"] as? Bool == true,
                  let idText = record["profileID"] as? String, let id = UUID(uuidString: idText),
                  record["browserData"] as? String == paths.browserDataDirectory(for: id).path
            else { throw ProfileCacheError.unsafeEntry }
            let store = ProfileStore(paths: paths)
            let profile = try #require(store.profile(withID: id))
            let manager = BrowserProcessManager(paths: paths)
            let data = paths.browserDataDirectory(for: id)
            let operation = ProfileCacheMaintenance(browserData: data)
            let protectedBefore = try protectedFiles(in: data)
            let metadataBefore = try Data(contentsOf: paths.profilesFile)
            let result = try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
                var operation = operation
                operation.authority = authority
                let before = try operation.estimate()
                if phase == "clear-recovery" {
                    var interrupted = operation
                    interrupted.fault = { if case .removingRoot(1) = $0 { throw CocoaError(.fileWriteOutOfSpace) } }
                    #expect(throws: ProfileCacheError.partiallyRemoved) { try interrupted.clear() }
                    #expect(throws: ProfileCacheError.rollbackRequired) { try operation.estimate() }
                    let recovery = try operation.recover()
                    #expect(recovery.restoredRoots == 1 && recovery.cacheMayAlreadyBeRemoved)
                    let remaining = try operation.estimate()
                    #expect(remaining.files > 0 && remaining.files < before.files)
                    #expect(try protectedFiles(in: data) == protectedBefore)
                    let removed = try operation.clear()
                    #expect(removed == remaining)
                    return (before, true)
                }
                return (try operation.clear(), false)
            }
            #expect(result.0.files > 0 && result.0.bytes > 0)
            #expect(try operation.estimate().files == 0)
            #expect(try protectedFiles(in: data) == protectedBefore)
            #expect(try Data(contentsOf: paths.profilesFile) == metadataBefore)
            try paths.writePrivateFile(JSONSerialization.data(withJSONObject: [
                "filesRemoved": result.0.files, "bytesRemoved": result.0.bytes,
                "journalRecoveryVerified": result.1,
                "loadedTestImageSHA256": executingTestSHA256,
                "testImageBinding": "class_getImageName of owned fixture marker",
                "partialRemovalInjected": phase == "clear-recovery",
                "protectedFilesUnchanged": protectedBefore.count,
                "metadataUnchanged": true, "heldStoppedAuthority": true,
                "systemKeychainUsed": false
            ]), to: paths.rootDirectory.appendingPathComponent("cache-runtime-result.json"))
        }
    }

    private func protectedFiles(in browserData: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in ["Cookies", "Network", "Local Storage", "IndexedDB", "Service Worker", "Extensions", "Sessions"] {
            let directory = browserData.appendingPathComponent("Default").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            let rootValues = try directory.resourceValues(forKeys: keys)
            let entries: [URL]
            if rootValues.isRegularFile == true { entries = [directory] }
            else {
                guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
                      let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { throw ProfileCacheError.unsafeEntry }
                entries = enumerator.allObjects.compactMap { $0 as? URL }
            }
            for file in entries {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { throw ProfileCacheError.unsafeEntry }
                if values.isRegularFile == true {
                    let key = String(file.path.dropFirst(browserData.path.count))
                    result[key] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        return result
    }
}

private final class CacheRuntimeImageMarker: NSObject {}
