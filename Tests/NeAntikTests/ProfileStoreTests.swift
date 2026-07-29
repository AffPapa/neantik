import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ProfileStoreTests {
    @Test
    func rejectsUnsafeOrOversizedProfileNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(paths: AppPaths(rootDirectory: root))

        #expect(throws: NeAntikError.self) {
            try store.upsert(BrowserProfile(name: "строка\nвторая"))
        }
        #expect(throws: NeAntikError.self) {
            try store.upsert(
                BrowserProfile(
                    name: String(
                        repeating: "д",
                        count: BrowserProfile.maximumNameLength + 1
                    )
                )
            )
        }
    }

    @Test
    func persistsProfilesAndCreatesPrivateDataDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let profile = BrowserProfile(name: "Persistent")
        try store.upsert(profile)

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profiles.count == 1)
        #expect(reloaded.profiles.first?.id == profile.id)
        #expect(reloaded.profiles.first?.name == profile.name)
        #expect(reloaded.profiles.first?.identity == profile.identity)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.browserDataDirectory(for: profile.id).path
            )
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: paths.profilesFile.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: paths.browserDataDirectory(for: profile.id).path
        )
        #expect(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue ==
                0o600
        )
        #expect(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ==
                0o700
        )
    }

    @Test
    func migratesLegacyProfileToStableIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profile = BrowserProfile(name: "Legacy")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode([profile])
        guard var array = try JSONSerialization.jsonObject(with: encoded)
            as? [[String: Any]]
        else {
            Issue.record("Could not create legacy fixture")
            return
        }
        array[0].removeValue(forKey: "identity")
        let legacyData = try JSONSerialization.data(withJSONObject: array)
        try legacyData.write(to: paths.profilesFile)

        let firstLoad = ProfileStore(paths: paths)
        let secondLoad = ProfileStore(paths: paths)

        let expected = BrowserIdentity.migrated(profileID: profile.id)
        #expect(firstLoad.profiles.first?.identity == expected)
        #expect(secondLoad.profiles.first?.identity == expected)
    }

    @Test
    func rollsBackMemoryWhenProfilePersistenceFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        try FileManager.default.createDirectory(
            at: paths.profilesFile,
            withIntermediateDirectories: false
        )

        let profile = BrowserProfile(name: "Must not remain")
        #expect(throws: (any Error).self) {
            try store.upsert(profile)
        }
        #expect(store.profiles.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )
        )
    }

    @Test
    func rollsBackNewProfileWhenFollowupSaveFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let profile = BrowserProfile(name: "Credential failure")

        #expect(throws: (any Error).self) {
            try store.upsert(profile) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(store.profiles.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )
        )
        #expect(ProfileStore(paths: paths).profiles.isEmpty)
    }

    @Test
    func restoresExistingMetadataWithoutRemovingBrowserData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(
            BrowserProfile(name: "Original")
        )
        let marker = paths.browserDataDirectory(for: original.id)
            .appendingPathComponent("session-marker")
        try Data("keep".utf8).write(to: marker)

        var edited = original
        edited.name = "Edited"
        #expect(throws: (any Error).self) {
            try store.upsert(edited) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }

        #expect(store.profile(withID: original.id)?.name == "Original")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profile(withID: original.id)?.name == "Original")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func restoresProfileAndBrowserDataWhenDeleteFollowupFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let profile = try store.upsert(
            BrowserProfile(name: "Keep after credential failure")
        )
        let marker = paths.browserDataDirectory(for: profile.id)
            .appendingPathComponent("session-marker")
        try Data("keep".utf8).write(to: marker)

        #expect(throws: (any Error).self) {
            try store.delete(profile) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }

        #expect(store.profile(withID: profile.id) != nil)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profile(withID: profile.id) != nil)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func corruptMetadataFailsClosedWithoutOverwritingOrCreatingData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let corruptData = Data("{ definitely-not-json".utf8)
        try paths.writePrivateFile(corruptData, to: paths.profilesFile)

        let store = ProfileStore(paths: paths)
        #expect(store.profiles.isEmpty)
        #expect(store.lastError != nil)
        let attempted = BrowserProfile(name: "Must not overwrite")

        #expect(throws: (any Error).self) {
            try store.upsert(attempted)
        }
        #expect(try Data(contentsOf: paths.profilesFile) == corruptData)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: attempted.id).path
            )
        )
    }

    @Test
    func recoversPreviousRevisionWithoutTouchingBrowserData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(
            BrowserProfile(name: "Previous revision")
        )
        let marker = paths.browserDataDirectory(for: original.id)
            .appendingPathComponent("session-marker")
        try Data("keep".utf8).write(to: marker)

        var edited = original
        edited.name = "Newest revision"
        _ = try store.upsert(edited)
        let corruptData = Data("{ partial-write".utf8)
        try paths.writePrivateFile(corruptData, to: paths.profilesFile)

        let recovered = ProfileStore(paths: paths)

        #expect(
            recovered.profile(withID: original.id)?.name ==
                "Previous revision"
        )
        #expect(recovered.lastError?.contains("Recovery") == true)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: paths.profilesRecoveryDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(recoveryFiles.count == 1)
        #expect(try Data(contentsOf: recoveryFiles[0]) == corruptData)
        let backupMode = try FileManager.default.attributesOfItem(
            atPath: paths.profilesBackupFile.path
        )[.posixPermissions] as? NSNumber
        let rejectedMode = try FileManager.default.attributesOfItem(
            atPath: recoveryFiles[0].path
        )[.posixPermissions] as? NSNumber
        #expect(backupMode?.intValue == 0o600)
        #expect(rejectedMode?.intValue == 0o600)
    }

    @Test
    func symlinkedRecoverySnapshotBlocksProfileOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(BrowserProfile(name: "Original"))
        try FileManager.default.removeItem(at: paths.profilesBackupFile)
        let protectedData = Data("outside".utf8)
        try protectedData.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.profilesBackupFile,
            withDestinationURL: outside
        )

        var edited = original
        edited.name = "Must not persist"
        #expect(throws: (any Error).self) {
            try store.upsert(edited)
        }

        #expect(store.profile(withID: original.id)?.name == "Original")
        #expect(try Data(contentsOf: outside) == protectedData)
    }

    @Test
    func rejectsSymlinkedProfileDirectoryWithoutWritingOutsideRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let profileID = UUID()
        try FileManager.default.createSymbolicLink(
            at: paths.profileDirectory(for: profileID),
            withDestinationURL: outside
        )

        #expect(throws: (any Error).self) {
            try paths.prepareProfileDirectories(for: profileID)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: outside
                    .appendingPathComponent("BrowserData")
                    .path
            )
        )
    }

    @Test
    func symlinkedProfilesFileFailsClosedWithoutChangingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let protectedData = Data("outside".utf8)
        try protectedData.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.profilesFile,
            withDestinationURL: outside
        )

        let store = ProfileStore(paths: paths)
        #expect(store.lastError != nil)
        #expect(throws: (any Error).self) {
            try store.upsert(BrowserProfile(name: "Blocked"))
        }
        #expect(try Data(contentsOf: outside) == protectedData)
    }

    @Test
    func rejectsFingerprintSeedCollisionsOnUpsert() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        let first = try store.upsert(
            BrowserProfile(
                name: "First",
                identity: BrowserIdentity(seed: 42)
            )
        )
        let second = try store.upsert(
            BrowserProfile(
                name: "Second",
                identity: BrowserIdentity(seed: 42)
            )
        )

        #expect(first.identity.seed == 42)
        #expect(second.identity.seed == 43)
        #expect(
            Set(store.profiles.map(\.identity.seed)).count ==
                store.profiles.count
        )

        let reloaded = ProfileStore(paths: AppPaths(rootDirectory: root))
        #expect(
            Set(reloaded.profiles.map(\.identity.seed)).count ==
                reloaded.profiles.count
        )
        #expect(
            reloaded.profile(withID: second.id)?.identity.seed == 43
        )
    }

    @Test
    func repairsDuplicateIDsAndSeedsFromPersistedProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let sharedID = UUID()
        let profiles = [
            BrowserProfile(
                id: sharedID,
                name: "First",
                identity: BrowserIdentity(seed: 100)
            ),
            BrowserProfile(
                id: sharedID,
                name: "Second",
                identity: BrowserIdentity(seed: 100)
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(profiles),
            to: paths.profilesFile
        )

        let repaired = ProfileStore(paths: paths)
        #expect(repaired.lastError == nil)
        #expect(repaired.profiles.count == 2)
        #expect(Set(repaired.profiles.map(\.id)).count == 2)
        #expect(Set(repaired.profiles.map(\.identity.seed)).count == 2)

        let secondLoad = ProfileStore(paths: paths)
        #expect(secondLoad.lastError == nil)
        #expect(secondLoad.profiles == repaired.profiles)
    }

    @Test
    func migratesLegacyUnsignedSeedsWithoutRuntimeCollisions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profiles = [
            BrowserProfile(
                name: "Existing low seed",
                identity: BrowserIdentity(seed: 1)
            ),
            BrowserProfile(
                name: "Legacy high collision",
                identity: BrowserIdentity(seed: 2)
            ),
            BrowserProfile(
                name: "Legacy high maximum",
                identity: BrowserIdentity(seed: 3)
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        object[1]["identity"] = [
            "seed": UInt64(Int32.max) + 1
        ]
        object[2]["identity"] = [
            "seed": UInt64(UInt32.max)
        ]
        try paths.writePrivateFile(
            JSONSerialization.data(withJSONObject: object),
            to: paths.profilesFile
        )

        let repaired = ProfileStore(paths: paths)
        let seeds = repaired.profiles.map(\.identity.seed)
        #expect(repaired.lastError == nil)
        #expect(Set(seeds).count == profiles.count)
        #expect(
            seeds.allSatisfy {
                (1...BrowserIdentity.maximumRuntimeSeed).contains($0)
            }
        )

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.lastError == nil)
        #expect(reloaded.profiles == repaired.profiles)
    }

    @Test
    func migratesRealLegacyUnsignedSeedsSeenInCrashReport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profiles = [
            BrowserProfile(name: "Legacy 0.3.7 A"),
            BrowserProfile(name: "Legacy 0.3.7 B")
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        object[0]["identity"] = ["seed": 2_456_110_098]
        object[1]["identity"] = ["seed": 3_454_592_789]
        try paths.writePrivateFile(
            JSONSerialization.data(withJSONObject: object),
            to: paths.profilesFile
        )

        let repaired = ProfileStore(paths: paths)
        #expect(repaired.lastError == nil)
        #expect(
            repaired.profiles.map(\.identity.seed) == [
                308_626_450,
                1_307_109_141
            ]
        )
        #expect(
            repaired.profiles.allSatisfy {
                $0.identity.seed == $0.identity.runtimeSeed
            }
        )

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profiles == repaired.profiles)
    }
}
