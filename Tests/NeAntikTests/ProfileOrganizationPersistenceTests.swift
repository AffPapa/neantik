import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ProfileOrganizationPersistenceTests {
    @Test
    func missingSidecarKeepsLegacyProfilesByteCompatible() throws {
        let fixture = try OrganizationFixture()
        let profile = BrowserProfile(name: "Legacy")
        try fixture.store.upsert(profile)
        let profilesData = try Data(contentsOf: fixture.paths.profilesFile)

        #expect(
            try fixture.paths.privateFileEntryKind(
                fixture.paths.profileOrganizationFile
            ) == .missing
        )
        #expect(
            try fixture.paths.privateFileEntryKind(
                fixture.paths.profileOrganizationBackupFile
            ) == .missing
        )

        let reloaded = ProfileStore(paths: fixture.paths)

        #expect(reloaded.profiles.map(\.id) == [profile.id])
        #expect(reloaded.organization == .empty)
        #expect(reloaded.hasTrustedOrganization)
        #expect(try Data(contentsOf: fixture.paths.profilesFile) == profilesData)
        #expect(
            try fixture.paths.privateFileEntryKind(
                fixture.paths.profileOrganizationFile
            ) == .missing
        )
        let json = try JSONSerialization.jsonObject(with: profilesData)
        #expect(json is [[String: Any]])
    }

    @Test
    func firstMutationCreatesDeterministicPrivateCurrentAndPreviousFiles()
        throws
    {
        let fixture = try OrganizationFixture()
        _ = try fixture.store.createFolder(
            named: " Якорь ",
            at: Date(timeIntervalSince1970: 20)
        )
        _ = try fixture.store.createFolder(
            named: "Альфа",
            at: Date(timeIntervalSince1970: 10)
        )

        #expect(fixture.store.organization.folders.map(\.name) == [
            "Альфа",
            "Якорь"
        ])
        let currentData = try Data(
            contentsOf: fixture.paths.profileOrganizationFile
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            ProfileOrganizationDocument.self,
            from: currentData
        )
        #expect(
            document.schemaVersion ==
                ProfileOrganizationDocument.currentSchemaVersion
        )
        #expect(document.folders.map(\.name) == ["Альфа", "Якорь"])
        #expect(document.assignments.isEmpty)

        for url in [
            fixture.paths.profileOrganizationFile,
            fixture.paths.profileOrganizationBackupFile
        ] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            #expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue ==
                    0o600
            )
        }

        let reloaded = ProfileStore(paths: fixture.paths)
        #expect(reloaded.organization == fixture.store.organization)
        #expect(
            try Data(contentsOf: fixture.paths.profileOrganizationFile) ==
                currentData
        )
    }

    @Test
    func legacyZWJFolderReloadsAndSurvivesAssignmentUpdate() throws {
        let fixture = try OrganizationFixture()
        let profile = BrowserProfile(name: "Profile")
        try fixture.store.upsert(profile)
        let family = "👨‍👩‍👧‍👦"
        let folderName = String(
            repeating: family,
            count: ProfileFolder.maximumNameLength
        )
        let folder = ProfileFolder(
            name: folderName,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try fixture.paths.writePrivateFile(
            encoder.encode(ProfileOrganizationDocument(folders: [folder])),
            to: fixture.paths.profileOrganizationFile
        )

        let reloaded = ProfileStore(paths: fixture.paths)
        #expect(reloaded.hasTrustedOrganization)
        #expect(reloaded.organization.folders.first?.name == folderName)

        try reloaded.assignProfile(profile.id, toFolderID: folder.id)
        let updated = ProfileStore(paths: fixture.paths)

        #expect(updated.organization.folders.first?.name == folderName)
        #expect(updated.folderID(forProfileID: profile.id) == folder.id)
    }

    @Test
    func assignRenameAndDeleteNeverRewriteProfilesOrBrowserData() throws {
        let fixture = try OrganizationFixture()
        let active = BrowserProfile(name: "Active")
        let archived = BrowserProfile(name: "Archived", isArchived: true)
        try fixture.store.upsert(active)
        try fixture.store.upsert(archived)
        let profilesData = try Data(contentsOf: fixture.paths.profilesFile)
        let activeBrowserData = fixture.paths.browserDataDirectory(
            for: active.id
        )
        let archivedBrowserData = fixture.paths.browserDataDirectory(
            for: archived.id
        )

        let folder = try fixture.store.createFolder(
            named: "Работа",
            at: Date(timeIntervalSince1970: 10)
        )
        try fixture.store.assignProfiles(
            [active.id, archived.id],
            toFolderID: folder.id
        )
        let renamed = try fixture.store.renameFolder(
            withID: folder.id,
            to: "Клиенты",
            at: Date(timeIntervalSince1970: 20)
        )

        #expect(renamed.id == folder.id)
        #expect(
            fixture.store.folderID(forProfileID: active.id) == folder.id
        )
        #expect(
            fixture.store.folderID(forProfileID: archived.id) == folder.id
        )

        let affected = try fixture.store.deleteFolder(withID: folder.id)

        #expect(Set(affected) == Set([active.id, archived.id]))
        #expect(fixture.store.organization.folders.isEmpty)
        #expect(fixture.store.folderID(forProfileID: active.id) == nil)
        #expect(fixture.store.folderID(forProfileID: archived.id) == nil)
        #expect(try Data(contentsOf: fixture.paths.profilesFile) == profilesData)
        #expect(
            FileManager.default.fileExists(atPath: activeBrowserData.path)
        )
        #expect(
            FileManager.default.fileExists(atPath: archivedBrowserData.path)
        )

        let reloaded = ProfileStore(paths: fixture.paths)
        #expect(reloaded.profiles.count == 2)
        #expect(reloaded.organization == .empty)
    }

    @Test
    func invalidDuplicateAndStaleMutationsFailWithoutChangingSidecar() throws {
        let fixture = try OrganizationFixture()
        let profile = BrowserProfile(name: "Profile")
        try fixture.store.upsert(profile)
        _ = try fixture.store.createFolder(named: "Café")
        let originalData = try Data(
            contentsOf: fixture.paths.profileOrganizationFile
        )

        #expect(throws: ProfileOrganizationError.self) {
            try fixture.store.createFolder(named: "cafe")
        }
        #expect(throws: ProfileOrganizationError.self) {
            try fixture.store.createFolder(named: "bad\nname")
        }
        #expect(throws: ProfileOrganizationError.self) {
            try fixture.store.assignProfile(
                profile.id,
                toFolderID: UUID()
            )
        }
        #expect(throws: ProfileOrganizationError.self) {
            try fixture.store.assignProfile(
                UUID(),
                toFolderID: fixture.store.organization.folders.first?.id
            )
        }

        #expect(
            try Data(contentsOf: fixture.paths.profileOrganizationFile) ==
                originalData
        )
    }

    @Test
    func corruptCurrentRecoversPreviousWithoutTouchingProfiles() throws {
        let fixture = try OrganizationFixture()
        try fixture.store.upsert(BrowserProfile(name: "Persistent"))
        let profilesData = try Data(contentsOf: fixture.paths.profilesFile)
        _ = try fixture.store.createFolder(named: "Первая")
        _ = try fixture.store.createFolder(named: "Вторая")
        try fixture.paths.writePrivateFile(
            Data("{broken".utf8),
            to: fixture.paths.profileOrganizationFile
        )

        let recovered = ProfileStore(paths: fixture.paths)

        #expect(recovered.hasTrustedMetadata)
        #expect(recovered.hasTrustedOrganization)
        #expect(recovered.organization.folders.map(\.name) == ["Первая"])
        #expect(recovered.lastError?.contains("восстановил") == true)
        #expect(try Data(contentsOf: fixture.paths.profilesFile) == profilesData)
        let rejected = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.profilesRecoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(
                "profile-organization-rejected-"
            )
        }
        #expect(rejected.count == 1)
        #expect(try Data(contentsOf: rejected[0]) == Data("{broken".utf8))
    }

    @Test
    func unrecoverableFolderCorruptionDoesNotBlockProfileStorage() throws {
        let fixture = try OrganizationFixture()
        let first = BrowserProfile(name: "First")
        try fixture.store.upsert(first)
        _ = try fixture.store.createFolder(named: "Folder")
        try FileManager.default.removeItem(
            at: fixture.paths.profileOrganizationBackupFile
        )
        let corruptData = Data("{broken".utf8)
        try fixture.paths.writePrivateFile(
            corruptData,
            to: fixture.paths.profileOrganizationFile
        )

        let reloaded = ProfileStore(paths: fixture.paths)

        #expect(reloaded.hasTrustedMetadata)
        #expect(!reloaded.hasTrustedOrganization)
        #expect(reloaded.organization == .empty)
        #expect(throws: ProfileOrganizationError.self) {
            try reloaded.createFolder(named: "Blocked")
        }

        let second = BrowserProfile(name: "Second")
        try reloaded.upsert(second)
        #expect(Set(reloaded.profiles.map(\.id)) == Set([first.id, second.id]))
        #expect(
            try Data(contentsOf: fixture.paths.profileOrganizationFile) ==
                corruptData
        )
    }

    @Test
    func staleStoresMergeFolderMutationsUnderTheMetadataGuard() throws {
        let fixture = try OrganizationFixture()
        let staleStore = ProfileStore(paths: fixture.paths)

        _ = try fixture.store.createFolder(named: "Alpha")
        _ = try staleStore.createFolder(named: "Beta")

        let reloaded = ProfileStore(paths: fixture.paths)
        #expect(reloaded.organization.folders.map(\.name) == [
            "Alpha",
            "Beta"
        ])
    }

    @Test
    func symlinkedSidecarFailsClosedWithoutBlockingProfiles() throws {
        let fixture = try OrganizationFixture()
        let first = BrowserProfile(name: "First")
        try fixture.store.upsert(first)
        let target = fixture.root.appendingPathComponent("outside.json")
        let targetData = Data("outside-must-not-change".utf8)
        try targetData.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.profileOrganizationFile,
            withDestinationURL: target
        )

        let reloaded = ProfileStore(paths: fixture.paths)

        #expect(reloaded.hasTrustedMetadata)
        #expect(!reloaded.hasTrustedOrganization)
        #expect(throws: ProfileOrganizationError.self) {
            try reloaded.createFolder(named: "Blocked")
        }
        let second = BrowserProfile(name: "Second")
        try reloaded.upsert(second)
        #expect(Set(reloaded.profiles.map(\.id)) == Set([first.id, second.id]))
        #expect(try Data(contentsOf: target) == targetData)
        #expect(
            try fixture.paths.privateFileEntryKind(
                fixture.paths.profileOrganizationFile
            ) == .unsafe
        )
    }
}

@MainActor
private final class OrganizationFixture {
    let root: URL
    let paths: AppPaths
    let store: ProfileStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neantik-profile-organization-\(UUID().uuidString)",
            isDirectory: true
        )
        paths = AppPaths(rootDirectory: root)
        store = ProfileStore(paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
