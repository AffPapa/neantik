import Foundation
import Testing
@testable import NeAntik

struct ProfileConfigurationTransferTests {
    @Test
    func exportIsMetadataOnlyAndImportCreatesFreshIdentity() throws {
        let profile = BrowserProfile(
            name: "Рабочий профиль",
            tags: ["Клиент"],
            note: "локальная заметка",
            isPinned: true,
            startURL: "https://example.com",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: "proxy-user"
            ),
            identity: BrowserIdentity(seed: 12345)
        )
        let document = try ProfileConfigurationTransferDocument(
            profiles: [profile],
            folderNameByProfileID: [profile.id: "Клиенты"],
            exportedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains("proxy.example"))
        #expect(text.contains("proxy-user"))
        #expect(text.contains("Клиенты"))
        #expect(!text.contains("локальная заметка"))
        #expect(!text.contains("12345"))
        #expect(!text.contains("identity"))
        #expect(!text.localizedCaseInsensitiveContains("password"))
        #expect(!text.localizedCaseInsensitiveContains("browserdata"))
        #expect(!text.localizedCaseInsensitiveContains("cookie"))
        #expect(!text.localizedCaseInsensitiveContains("keychain"))

        let decoded = try JSONDecoder().decode(
            ProfileConfigurationTransferDocument.self,
            from: data
        )
        let imported = try decoded.makeProfiles(
            now: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let importedProfile = try #require(imported.first)
        #expect(importedProfile.id != profile.id)
        #expect(importedProfile.identity.runtimeSeed != profile.identity.runtimeSeed)
        #expect(importedProfile.note.isEmpty)
        #expect(importedProfile.revision == 0)
        #expect(importedProfile.lastLaunchedAt == nil)
        #expect(decoded.folderName(at: 0) == "Клиенты")
    }

    @Test
    func decoderAcceptsSharedFoldersAndRejectsUnsupportedSchema() throws {
        let first = ProfileConfigurationTransferEntry(
            name: "Первый",
            colorHex: "#FF3B4D",
            symbolName: "globe",
            tags: [],
            isPinned: false,
            isArchived: false,
            startURL: "https://example.com",
            proxy: nil,
            folderName: "Работа"
        )
        let second = ProfileConfigurationTransferEntry(
            name: "Второй",
            colorHex: "#30D158",
            symbolName: "globe",
            tags: [],
            isPinned: false,
            isArchived: false,
            startURL: "https://example.org",
            proxy: nil,
            folderName: "работа"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        struct Fixture: Codable {
            let schemaVersion: Int
            let exportedAt: Date
            let profiles: [ProfileConfigurationTransferEntry]
        }

        let duplicateData = try encoder.encode(
            Fixture(
                schemaVersion: 1,
                exportedAt: Date(timeIntervalSince1970: 1_800_000_100),
                profiles: [first, second]
            )
        )
        let decoded = try JSONDecoder().decode(
            ProfileConfigurationTransferDocument.self,
            from: duplicateData
        )
        #expect(decoded.profiles.count == 2)

        let unsupportedData = try encoder.encode(
            Fixture(
                schemaVersion: 99,
                exportedAt: Date(timeIntervalSince1970: 1_800_000_100),
                profiles: []
            )
        )
        #expect(throws: ProfileConfigurationTransferError.unsupportedSchema) {
            _ = try JSONDecoder().decode(
                ProfileConfigurationTransferDocument.self,
                from: unsupportedData
            )
        }
    }
}
