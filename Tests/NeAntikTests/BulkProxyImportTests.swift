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
    @Test func importerPersistsProfilesAndKeychainSecrets() throws {
        let fixture = try BulkImportFixture()
        let drafts = try BulkProxyImportParser.parse(
            "user:first@one.example:443\nother:second@two.example:8443",
            kind: .https,
            order: .automatic
        )

        let profiles = try BulkProfileImporter.create(
            drafts: drafts,
            baseName: "Работа",
            store: fixture.store,
            keychain: fixture.keychain
        )

        #expect(profiles.map(\.name) == ["Работа 1", "Работа 2"])
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
    @Test func importerRollsBackEverythingAfterKeychainFailure() throws {
        let backend = BulkImportKeychainBackend(failOnUpsert: 2)
        let fixture = try BulkImportFixture(backend: backend)
        let drafts = try BulkProxyImportParser.parse(
            "user:first@one.example:443\nother:second@two.example:8443",
            kind: .https,
            order: .automatic
        )

        #expect(throws: BulkImportFixtureError.self) {
            try BulkProfileImporter.create(
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
    @Test func importerQueuesOrphanedSecretForSafeNextLaunchCleanup() async throws {
        let backend = BulkImportKeychainBackend(
            failOnUpsert: 2,
            // The failed second upsert first restores its own empty value.
            // Fail the following delete, which rolls back the first secret.
            failOnDelete: 2
        )
        let fixture = try BulkImportFixture(backend: backend)
        let drafts = try BulkProxyImportParser.parse(
            "user:first@one.example:443\nother:second@two.example:8443",
            kind: .https,
            order: .automatic
        )

        #expect(throws: BulkProxyImportError.self) {
            try BulkProfileImporter.create(
                drafts: drafts,
                baseName: "Работа",
                store: fixture.store,
                keychain: fixture.keychain
            )
        }
        #expect(fixture.store.profiles.isEmpty)
        #expect(backend.storedValueCount == 1)

        let pending = try fixture.paths.pendingCredentialCleanupProfileIDs()
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
        #expect(try fixture.paths.pendingCredentialCleanupProfileIDs().isEmpty)
    }
}

@MainActor
private final class BulkImportFixture {
    let root: URL
    let paths: AppPaths
    let store: ProfileStore
    let keychain: KeychainStore

    init(
        backend: BulkImportKeychainBackend = BulkImportKeychainBackend()
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
