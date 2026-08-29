import Foundation
import Testing
@testable import NeAntik

struct BulkProxyImportTests {
    @Test func parsesOneProxyPerNonEmptyLine() throws {
        let drafts = try BulkProxyImportParser.parse(
            """
            user:secret@proxy-one.example:443

            proxy-two.example:8080@other:password
            """,
            kind: .https,
            order: .automatic
        )

        #expect(drafts.count == 2)
        #expect(drafts[0].configuration.host == "proxy-one.example")
        #expect(drafts[0].configuration.username == "user")
        #expect(drafts[0].password == "secret")
        #expect(drafts[1].configuration.host == "proxy-two.example")
        #expect(drafts[1].configuration.username == "other")
        #expect(drafts[1].password == "password")
    }

    @Test func invalidLineReportsOnlyItsNumber() {
        let secret = "never-print-this-secret"
        do {
            _ = try BulkProxyImportParser.parse(
                "proxy.example:443\nuser:\(secret)@invalid host:443",
                kind: .http,
                order: .automatic
            )
            Issue.record("Ожидалась ошибка второй строки")
        } catch {
            #expect(error as? BulkProxyImportError == .invalidLine(2))
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test func previewRetainsValidRowsAndReportsEveryInvalidLine() throws {
        let secret = "never-show-this-password"
        let preview = try BulkProxyImportParser.preview(
            """
            one.example:8080
            user:\(secret)@invalid host:443
            two.example:8443
            broken
            """,
            kind: .https,
            order: .automatic
        )

        #expect(preview.rows.map(\.lineNumber) == [1, 2, 3, 4])
        #expect(preview.drafts.count == 2)
        #expect(preview.issueLineNumbers == [2, 4])
        #expect(preview.hasIssues)
        #expect(!preview.isReady)
        #expect(
            preview.rows.compactMap(\.safeSummary).allSatisfy {
                !$0.contains(secret) && !$0.contains("user")
            }
        )
    }

    @Test func previewExplainsAmbiguousRowsWithoutEchoingInput() throws {
        let preview = try BulkProxyImportParser.preview(
            "1:2:3:4",
            kind: .http,
            order: .automatic
        )
        let row = try #require(preview.rows.first)
        let issue = try #require(row.issue)

        #expect(row.draft == nil)
        #expect(issue == .ambiguous)
        #expect(issue.message.contains("порядок полей"))
        #expect(!issue.message.contains("1:2:3:4"))
    }

    @Test func allValidPreviewIsReadyAndIgnoresBlankLines() throws {
        let preview = try BulkProxyImportParser.preview(
            "one.example:8080\n\n two.example:8081 ",
            kind: .http,
            order: .automatic
        )

        #expect(preview.rows.map(\.lineNumber) == [1, 3])
        #expect(preview.drafts.count == 2)
        #expect(preview.issueLineNumbers.isEmpty)
        #expect(preview.isReady)
    }

    @Test func entryLimitIsFailClosed() {
        let input = (1 ... BulkProxyImportParser.maximumEntries + 1)
            .map { "proxy-\($0).example:8080" }
            .joined(separator: "\n")

        #expect(throws: BulkProxyImportError.tooMany) {
            try BulkProxyImportParser.parse(
                input,
                kind: .http,
                order: .automatic
            )
        }
    }

    @Test func byteLimitIsFailClosed() {
        let input = String(
            repeating: "x",
            count: BulkProxyImportParser.maximumInputBytes + 1
        )
        #expect(throws: BulkProxyImportError.tooLarge) {
            try BulkProxyImportParser.parse(
                input,
                kind: .http,
                order: .automatic
            )
        }
    }

    @Test func emptyInputIsRejected() {
        #expect(throws: BulkProxyImportError.empty) {
            try BulkProxyImportParser.parse(
                "  \n\n  ",
                kind: .http,
                order: .automatic
            )
        }
    }

    @Test func generatedNamesStayValidAndBounded() throws {
        let base = String(
            repeating: "П",
            count: BrowserProfile.maximumNameLength
        )
        let name = try #require(
            BulkProxyImportParser.profileName(base: base, index: 100)
        )

        #expect(name.count <= BrowserProfile.maximumNameLength)
        #expect(name.hasSuffix(" 100"))
        #expect(BrowserProfile.isValidName(name))
        #expect(
            BulkProxyImportParser.profileName(base: "   ", index: 1)
                == nil
        )
    }

    @MainActor
    @Test func importerPersistsProfilesAndKeychainSecrets() async throws {
        let fixture = try BulkImportFixture()
        let drafts = try BulkProxyImportParser.parse(
            "user:first@one.example:443\nother:second@two.example:8443",
            kind: .https,
            order: .automatic
        )

        let profiles = try await BulkProfileImporter.create(
            drafts: drafts,
            baseName: "Работа",
            store: fixture.store,
            keychain: fixture.keychain
        )

        #expect(profiles.map(\.name) == ["Работа 1", "Работа 2"])
        #expect(profiles.allSatisfy { $0.note.isEmpty })
        #expect(
            profiles.allSatisfy {
                !$0.note.contains("first") && !$0.note.contains("second")
            }
        )
        #expect(
            profiles.allSatisfy {
                $0.startURL == BrowserProfile.defaultStartURL
            }
        )
        #expect(fixture.store.profiles.count == 2)
        #expect(
            try fixture.keychain.proxyPassword(profileID: profiles[0].id)
                == "first"
        )
        #expect(
            try fixture.keychain.proxyPassword(profileID: profiles[1].id)
                == "second"
        )
    }

    @MainActor
    @Test func keychainStagingDoesNotBlockMainActor() async throws {
        let backend = BlockingBulkImportKeychainBackend()
        let fixture = try BulkImportFixture(backend: backend)
        let drafts = try BulkProxyImportParser.parse(
            "user:secret@one.example:443",
            kind: .https,
            order: .automatic
        )
        DispatchQueue.global(qos: .utility).asyncAfter(
            // Full-suite AppKit render tests can legitimately occupy the
            // shared MainActor for roughly eight seconds. Keep this watchdog
            // above that independent test load while still failing a real
            // synchronous Keychain hop in bounded time.
            deadline: .now() + 20
        ) { [backend] in
            backend.resumeUpsertFromWatchdog()
        }
        let importTask = Task { @MainActor in
            try await BulkProfileImporter.create(
                drafts: drafts,
                baseName: "Фоновый импорт",
                store: fixture.store,
                keychain: fixture.keychain
            )
        }

        await backend.waitUntilUpsertStarts()
        backend.resumeUpsert()

        let profiles = try await importTask.value
        #expect(!backend.wasReleasedByWatchdog)
        #expect(profiles.count == 1)
        #expect(fixture.store.profiles.count == 1)
    }

    @MainActor
    @Test func cancelledKeychainStagingRollsBackBeforePersistence()
        async throws
    {
        let backend = BlockingBulkImportKeychainBackend()
        let fixture = try BulkImportFixture(backend: backend)
        let drafts = try BulkProxyImportParser.parse(
            "user:secret@one.example:443",
            kind: .https,
            order: .automatic
        )
        let importTask = Task { @MainActor in
            try await BulkProfileImporter.create(
                drafts: drafts,
                baseName: "Отменённый импорт",
                store: fixture.store,
                keychain: fixture.keychain
            )
        }

        await backend.waitUntilUpsertStarts()
        importTask.cancel()
        backend.resumeUpsert()

        await #expect(throws: CancellationError.self) {
            try await importTask.value
        }
        #expect(fixture.store.profiles.isEmpty)
        #expect(backend.storedValueCount == 0)
        #expect(try fixture.paths.pendingCredentialStagingProfileIDs().isEmpty)
    }

    @MainActor
    @Test func importerRollsBackEverythingAfterKeychainFailure() async throws {
        let backend = BulkImportKeychainBackend(failOnUpsert: 2)
        let fixture = try BulkImportFixture(backend: backend)
        let drafts = try BulkProxyImportParser.parse(
            "user:first@one.example:443\nother:second@two.example:8443",
            kind: .https,
            order: .automatic
        )

        await #expect(throws: BulkImportFixtureError.self) {
            try await BulkProfileImporter.create(
                drafts: drafts,
                baseName: "Работа",
                store: fixture.store,
                keychain: fixture.keychain
            )
        }
        #expect(fixture.store.profiles.isEmpty)
        #expect(backend.storedValueCount == 0)
    }

    @MainActor
    @Test func importerRejectsProductCapacityBeforeWritingKeychain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-bulk-capacity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let profiles = (0..<ProfileStorageLimits.maximumProfileCount).map {
            index in
            BrowserProfile(
                name: String(format: "Profile %05d", index),
                identity: BrowserIdentity(seed: UInt32(index + 1))
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(profiles),
            to: paths.profilesFile
        )
        let store = ProfileStore(paths: paths)
        let backend = BulkImportKeychainBackend()
        let keychain = KeychainStore(
            backend: backend,
            service: "bulk.capacity.test",
            legacyService: nil
        )
        let drafts = try BulkProxyImportParser.parse(
            "user:secret@proxy.example:443",
            kind: .https,
            order: .automatic
        )

        await #expect(throws: NeAntikError.self) {
            try await BulkProfileImporter.create(
                drafts: drafts,
                baseName: "Overflow",
                store: store,
                keychain: keychain
            )
        }

        #expect(store.profiles.count == ProfileStorageLimits.maximumProfileCount)
        #expect(backend.upsertAttemptCount == 0)
        #expect(backend.storedValueCount == 0)
        #expect(try paths.pendingCredentialStagingProfileIDs().isEmpty)
    }

    @MainActor
    @Test func importerQueuesOrphanedSecretForSafeNextLaunchCleanup() async throws {
        let backend = BulkImportKeychainBackend(
            failOnUpsert: 2,
            // The failed second upsert restores its own empty value first;
            // cleanup then clears that attempted ID. Fail deletion of the
            // first saved secret so its durable staging marker must survive.
            failOnDelete: 3
        )
        let fixture = try BulkImportFixture(backend: backend)
        let drafts = try BulkProxyImportParser.parse(
            "user:first@one.example:443\nother:second@two.example:8443",
            kind: .https,
            order: .automatic
        )

        await #expect(throws: BulkProxyImportError.self) {
            try await BulkProfileImporter.create(
                drafts: drafts,
                baseName: "Работа",
                store: fixture.store,
                keychain: fixture.keychain
            )
        }
        #expect(fixture.store.profiles.isEmpty)
        #expect(backend.storedValueCount == 1)

        let pending = try fixture.paths.pendingCredentialStagingProfileIDs()
        #expect(pending.count == 1)
        let cleanup = DeletedProfileCredentialCleanup(
            paths: fixture.paths,
            keychain: fixture.keychain
        )
        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: []
        )

        #expect(summary.attemptedCount == 1)
        #expect(summary.clearedCount == 1)
        #expect(summary.failedCount == 0)
        #expect(backend.storedValueCount == 0)
        #expect(try fixture.paths.pendingCredentialStagingProfileIDs().isEmpty)
    }

    @MainActor
    @Test func startupKeepsCommittedStagedCredentialAndClearsJournal() async throws {
        let fixture = try BulkImportFixture()
        let profileID = UUID()
        try fixture.paths.createPrivateFileExclusively(
            Data("bulk-keychain-stage-v1".utf8),
            at: fixture.paths.profileCredentialStagingMarker(for: profileID)
        )
        try fixture.keychain.saveProxyPassword(
            "committed-secret",
            profileID: profileID
        )
        let cleanup = DeletedProfileCredentialCleanup(
            paths: fixture.paths,
            keychain: fixture.keychain
        )

        let summary = await cleanup.runOnce(
            metadataIsTrusted: true,
            excluding: [profileID]
        )

        #expect(summary.attemptedCount == 0)
        #expect(summary.skippedActiveCount == 1)
        #expect(
            try fixture.keychain.proxyPassword(profileID: profileID)
                == "committed-secret"
        )
        #expect(
            try fixture.paths.privateFileEntryKind(
                fixture.paths.profileCredentialStagingMarker(for: profileID)
            ) == .missing
        )
    }
}

@MainActor
private final class BulkImportFixture {
    let root: URL
    let paths: AppPaths
    let store: ProfileStore
    let keychain: KeychainStore

    init(
        backend: any KeychainBackend = BulkImportKeychainBackend()
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-bulk-import-\(UUID().uuidString)",
            isDirectory: true
        )
        root = rootURL
        paths = AppPaths(rootDirectory: rootURL)
        let trashRoot = rootURL.appendingPathComponent(
            "Trash",
            isDirectory: true
        )
        store = ProfileStore(
            paths: paths,
            trashDirectory: { source in
                try FileManager.default.createDirectory(
                    at: trashRoot,
                    withIntermediateDirectories: true
                )
                let destination = trashRoot.appendingPathComponent(
                    source.lastPathComponent + "-" + UUID().uuidString,
                    isDirectory: true
                )
                try FileManager.default.moveItem(
                    at: source,
                    to: destination
                )
                return destination
            },
            restoreTrashedDirectory: { trashed, destination in
                try FileManager.default.moveItem(
                    at: trashed,
                    to: destination
                )
            }
        )
        keychain = KeychainStore(
            backend: backend,
            service: "bulk.import.test",
            legacyService: nil
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class BlockingBulkImportKeychainBackend:
    KeychainBackend,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var upsertStarted = false
    private var mayFinishUpsert = false
    private var releasedByWatchdog = false
    private var values: [String: Data] = [:]

    func data(service: String, profileID: UUID) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return values["\(service)|\(profileID.uuidString)"]
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        condition.lock()
        upsertStarted = true
        condition.broadcast()
        while !mayFinishUpsert {
            condition.wait()
        }
        values["\(service)|\(profileID.uuidString)"] = data
        condition.unlock()
    }

    func delete(service: String, profileID: UUID) throws {
        condition.lock()
        values["\(service)|\(profileID.uuidString)"] = nil
        condition.unlock()
    }

    func waitUntilUpsertStarts() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                condition.lock()
                while !upsertStarted {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func resumeUpsert() {
        condition.lock()
        mayFinishUpsert = true
        condition.broadcast()
        condition.unlock()
    }

    func resumeUpsertFromWatchdog() {
        condition.lock()
        if !mayFinishUpsert {
            releasedByWatchdog = true
            mayFinishUpsert = true
            condition.broadcast()
        }
        condition.unlock()
    }

    var wasReleasedByWatchdog: Bool {
        condition.lock()
        defer { condition.unlock() }
        return releasedByWatchdog
    }

    var storedValueCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return values.count
    }
}

private enum BulkImportFixtureError: Error {
    case forcedFailure
}

private final class BulkImportKeychainBackend:
    KeychainBackend,
    @unchecked Sendable
{
    private var values: [String: Data] = [:]
    private let failOnUpsert: Int?
    private let failOnDelete: Int?
    private var upsertCount = 0
    private var deleteCount = 0

    init(failOnUpsert: Int? = nil, failOnDelete: Int? = nil) {
        self.failOnUpsert = failOnUpsert
        self.failOnDelete = failOnDelete
    }

    var storedValueCount: Int { values.count }
    var upsertAttemptCount: Int { upsertCount }

    func data(service: String, profileID: UUID) throws -> Data? {
        values[key(service: service, profileID: profileID)]
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        upsertCount += 1
        if upsertCount == failOnUpsert {
            throw BulkImportFixtureError.forcedFailure
        }
        values[key(service: service, profileID: profileID)] = data
    }

    func delete(service: String, profileID: UUID) throws {
        deleteCount += 1
        if deleteCount == failOnDelete {
            throw BulkImportFixtureError.forcedFailure
        }
        values.removeValue(forKey: key(service: service, profileID: profileID))
    }

    private func key(service: String, profileID: UUID) -> String {
        "\(service)|\(profileID.uuidString)"
    }
}
