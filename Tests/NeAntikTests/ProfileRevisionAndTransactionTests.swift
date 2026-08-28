import Foundation
import Testing

@testable import NeAntik

@MainActor
struct ProfileRevisionAndTransactionTests {
    @Test
    func bulkRequestRetainsFolderCapturedAtPresentation() {
        let folderID = UUID()
        var selectedFolderID: UUID? = folderID
        let request = BulkProxyImportRequest(
            targetFolderID: selectedFolderID
        )

        selectedFolderID = nil

        #expect(request.targetFolderID == folderID)
        #expect(selectedFolderID == nil)
    }

    @Test
    func legacyProfileWithoutRevisionDecodesAtRevisionZero() throws {
        let profile = BrowserProfile(name: "Legacy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "revision")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            BrowserProfile.self,
            from: legacyData
        )

        #expect(decoded.revision == 0)
    }

    @Test
    func staleWholeProfileUpsertCannotOverwriteNewerRevision() throws {
        let fixture = try TransactionFixture()
        let original = try fixture.store.upsert(
            BrowserProfile(
                name: "Original",
                tags: ["Initial"],
                note: "Initial note"
            )
        )
        var newer = original
        newer.name = "Newer"
        newer.tags = ["Current"]
        newer.note = "Current note"
        let current = try fixture.store.upsert(newer)
        var stale = original
        stale.name = "Stale editor"
        stale.tags = ["Obsolete"]
        stale.note = "Obsolete note"

        #expect(throws: BrowserProfileRevisionConflictError.self) {
            try fixture.store.upsert(stale)
        }

        let persisted = try #require(
            fixture.store.profile(withID: original.id)
        )
        #expect(persisted.name == "Newer")
        #expect(persisted.tags == ["Current"])
        #expect(persisted.note == "Current note")
        #expect(persisted.revision == current.revision)
    }

    @Test
    func narrowPinMutationPreservesNewerFields() throws {
        let fixture = try TransactionFixture()
        let original = try fixture.store.upsert(
            BrowserProfile(
                name: "Original",
                tags: ["Initial"],
                note: "Initial note"
            )
        )
        var newer = original
        newer.name = "Edited elsewhere"
        newer.tags = ["Current"]
        newer.note = "Current note"
        newer.startURL = "https://example.com/current"
        let current = try fixture.store.upsert(newer)

        let pinned = try fixture.store.mutateProfile(
            withID: original.id
        ) { profile in
            profile.isPinned = true
        }

        #expect(pinned.isPinned)
        #expect(pinned.name == "Edited elsewhere")
        #expect(pinned.tags == ["Current"])
        #expect(pinned.note == "Current note")
        #expect(pinned.startURL == "https://example.com/current")
        #expect(pinned.revision == current.revision + 1)
    }

    @Test
    func deletedFolderRejectsCreateBeforeAnyProfileIsPersisted() throws {
        let fixture = try TransactionFixture()
        let folder = try fixture.store.createFolder(named: "Deleted")
        _ = try fixture.store.deleteFolder(withID: folder.id)
        let draft = BrowserProfile(name: "Must remain a draft")

        for _ in 0..<2 {
            #expect(throws: ProfileOrganizationError.self) {
                try fixture.store.upsert(
                    draft,
                    toFolderID: folder.id
                )
            }
        }

        #expect(fixture.store.profiles.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.paths.profileDirectory(for: draft.id).path
            )
        )
    }

    @Test
    func unavailableOrganizationRejectsCompoundSaveWithoutPartialProfile()
        throws
    {
        let root = TransactionFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let seedStore = ProfileStore(paths: paths)
        _ = try seedStore.createFolder(named: "Seed")
        try paths.writePrivateFile(
            Data("{broken".utf8),
            to: paths.profileOrganizationFile
        )
        try paths.writePrivateFile(
            Data("{broken-backup".utf8),
            to: paths.profileOrganizationBackupFile
        )
        let unavailableStore = ProfileStore(paths: paths)
        let draft = BrowserProfile(name: "No partial save")

        #expect(!unavailableStore.hasTrustedOrganization)
        #expect(throws: ProfileOrganizationError.self) {
            try unavailableStore.upsert(draft, toFolderID: nil)
        }
        #expect(unavailableStore.profiles.isEmpty)
        #expect(ProfileStore(paths: paths).profiles.isEmpty)
    }

    @Test
    func folderPersistenceFailureRollsBackNewProfileAndAssignment() throws {
        let root = TransactionFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let seedStore = ProfileStore(paths: paths)
        let folder = try seedStore.createFolder(named: "Target")
        let gate = OneShotOrganizationFailure()
        let store = ProfileStore(
            paths: paths,
            beforeOrganizationPersist: {
                try gate.failFirstCall()
            }
        )
        let draft = BrowserProfile(name: "Rollback")

        #expect(throws: TransactionTestError.self) {
            try store.upsert(draft, toFolderID: folder.id)
        }

        #expect(store.profiles.isEmpty)
        #expect(store.folderID(forProfileID: draft.id) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: draft.id).path
            )
        )
        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.profiles.isEmpty)
        #expect(reloaded.folder(withID: folder.id) != nil)
    }

    @Test
    func dependentFailureRestoresExistingProfileAndFolder() throws {
        let fixture = try TransactionFixture()
        let firstFolder = try fixture.store.createFolder(named: "First")
        let secondFolder = try fixture.store.createFolder(named: "Second")
        let original = try fixture.store.upsert(
            BrowserProfile(name: "Original"),
            toFolderID: firstFolder.id
        )
        let durableOriginal = try #require(
            ProfileStore(paths: fixture.paths).profile(withID: original.id)
        )
        var edited = durableOriginal
        edited.name = "Must roll back"

        #expect(throws: TransactionTestError.self) {
            try fixture.store.upsert(
                edited,
                toFolderID: secondFolder.id
            ) { _ in
                throw TransactionTestError.forced
            }
        }

        let restored = try #require(
            fixture.store.profile(withID: original.id)
        )
        #expect(restored == durableOriginal)
        #expect(
            fixture.store.folderID(forProfileID: original.id) ==
                firstFolder.id
        )
        let reloaded = ProfileStore(paths: fixture.paths)
        #expect(reloaded.profile(withID: original.id) == durableOriginal)
        #expect(
            reloaded.folderID(forProfileID: original.id) == firstFolder.id
        )
    }

    @Test
    func editorCredentialPartialFailureRestoresProfileFolderAndSecrets()
        throws
    {
        let fixture = try TransactionFixture()
        let firstFolder = try fixture.store.createFolder(named: "First")
        let secondFolder = try fixture.store.createFolder(named: "Second")
        let original = try fixture.store.upsert(
            BrowserProfile(name: "Original"),
            toFolderID: firstFolder.id
        )
        let durableOriginal = try #require(
            ProfileStore(paths: fixture.paths).profile(withID: original.id)
        )
        let currentService = "profile-edit.current"
        let legacyService = "profile-edit.legacy"
        let backend = TransactionKeychainBackend()
        backend.set(
            "current-secret",
            service: currentService,
            profileID: original.id
        )
        backend.set(
            "legacy-secret",
            service: legacyService,
            profileID: original.id
        )
        backend.deleteFailureService = legacyService
        let keychain = KeychainStore(
            backend: backend,
            service: currentService,
            legacyService: legacyService
        )
        var edited = durableOriginal
        edited.name = "Must roll back"

        #expect(throws: TransactionTestError.self) {
            try fixture.store.upsert(
                edited,
                toFolderID: secondFolder.id
            ) { saved in
                try keychain.updateProxyPasswordForProfileEdit(
                    nil,
                    profileID: saved.id
                )
            }
        }

        let restored = try #require(
            fixture.store.profile(withID: original.id)
        )
        #expect(restored == durableOriginal)
        #expect(
            fixture.store.folderID(forProfileID: original.id) ==
                firstFolder.id
        )
        #expect(
            backend.string(
                service: currentService,
                profileID: original.id
            ) == "current-secret"
        )
        #expect(
            backend.string(
                service: legacyService,
                profileID: original.id
            ) == "legacy-secret"
        )
    }

    @Test
    func bulkDeletedFolderFailureIsRetrySafeAndWritesNoSecrets() async throws {
        let fixture = try TransactionFixture()
        let folder = try fixture.store.createFolder(named: "Deleted")
        _ = try fixture.store.deleteFolder(withID: folder.id)
        let backend = TransactionKeychainBackend()
        let keychain = KeychainStore(
            backend: backend,
            service: "profile-transaction.test",
            legacyService: nil
        )
        let drafts = try BulkProxyImportParser.parse(
            "user:first@one.example:443\nother:second@two.example:8443",
            kind: .https,
            order: .automatic
        )

        for _ in 0..<2 {
            await #expect(throws: ProfileOrganizationError.self) {
                try await BulkProfileImporter.create(
                    drafts: drafts,
                    baseName: "Batch",
                    store: fixture.store,
                    keychain: keychain,
                    targetFolderID: folder.id
                )
            }
        }

        #expect(fixture.store.profiles.isEmpty)
        #expect(backend.storedValueCount == 0)
    }

    @Test
    func bulkImportCommitsFolderAndCredentialsTogether() async throws {
        let fixture = try TransactionFixture()
        let folder = try fixture.store.createFolder(named: "Target")
        let backend = TransactionKeychainBackend()
        let keychain = KeychainStore(
            backend: backend,
            service: "profile-transaction-success.test",
            legacyService: nil
        )
        let drafts = try BulkProxyImportParser.parse(
            "user:first@one.example:443\nother:second@two.example:8443",
            kind: .https,
            order: .automatic
        )

        let profiles = try await BulkProfileImporter.create(
            drafts: drafts,
            baseName: "Batch",
            store: fixture.store,
            keychain: keychain,
            targetFolderID: folder.id
        )

        #expect(profiles.allSatisfy { $0.revision == 1 })
        #expect(
            profiles.allSatisfy {
                fixture.store.folderID(forProfileID: $0.id) == folder.id
            }
        )
        #expect(backend.storedValueCount == 2)
    }
}

@MainActor
private final class TransactionFixture {
    let root: URL
    let paths: AppPaths
    let store: ProfileStore

    init() throws {
        root = Self.makeRoot()
        paths = AppPaths(rootDirectory: root)
        store = ProfileStore(paths: paths)
    }

    static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-profile-transaction-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class OneShotOrganizationFailure {
    private var callCount = 0

    func failFirstCall() throws {
        callCount += 1
        if callCount == 1 {
            throw TransactionTestError.forced
        }
    }
}

private enum TransactionTestError: Error {
    case forced
}

private final class TransactionKeychainBackend:
    KeychainBackend,
    @unchecked Sendable
{
    private var values: [String: Data] = [:]
    var deleteFailureService: String?

    var storedValueCount: Int { values.count }

    func data(service: String, profileID: UUID) throws -> Data? {
        values[key(service: service, profileID: profileID)]
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        values[key(service: service, profileID: profileID)] = data
    }

    func delete(service: String, profileID: UUID) throws {
        if deleteFailureService == service {
            deleteFailureService = nil
            throw TransactionTestError.forced
        }
        values.removeValue(forKey: key(service: service, profileID: profileID))
    }

    func set(_ value: String, service: String, profileID: UUID) {
        values[key(service: service, profileID: profileID)] = Data(value.utf8)
    }

    func string(service: String, profileID: UUID) -> String? {
        values[key(service: service, profileID: profileID)].flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    private func key(service: String, profileID: UUID) -> String {
        "\(service)|\(profileID.uuidString)"
    }
}
