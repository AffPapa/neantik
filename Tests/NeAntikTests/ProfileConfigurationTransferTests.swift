import Foundation
import Testing
@testable import NeAntik

struct ProfileConfigurationTransferTests {
    @Test
    func encryptedTransferRoundTripsWithoutPlaintextOrSecrets() throws {
        let profile = BrowserProfile(
            name: "Зашифрованный профиль",
            tags: ["Тест"],
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
            exportedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let passphrase = "correct horse battery staple"

        let encrypted = try ProfileConfigurationEncryption.seal(
            document: document,
            passphrase: passphrase
        )

        #expect(!encrypted.contains(Data("Зашифрованный профиль".utf8)))
        let opened = try ProfileConfigurationEncryption.open(
            encrypted,
            passphrase: passphrase
        )
        #expect(opened == document)
        #expect(try opened.makeProfiles().first?.note == "")
    }

    @Test
    func encryptedTransferRejectsWrongPasswordAndTampering() throws {
        let document = try ProfileConfigurationTransferDocument(
            profiles: [BrowserProfile(name: "Профиль")],
            exportedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let encrypted = try ProfileConfigurationEncryption.seal(
            document: document,
            passphrase: "correct horse battery staple"
        )

        #expect(throws: ProfileConfigurationEncryptionError.decryptionFailed) {
            try ProfileConfigurationEncryption.open(
                encrypted,
                passphrase: "wrong horse battery staple"
            )
        }

        let envelope = try JSONDecoder().decode(
            EncryptedProfileConfigurationEnvelope.self,
            from: encrypted
        )
        var ciphertext = try #require(
            Data(base64Encoded: envelope.ciphertext)
        )
        ciphertext[ciphertext.startIndex] ^= 1
        let tampered = try JSONEncoder().encode(
            EncryptedProfileConfigurationEnvelope(
                schemaVersion: envelope.schemaVersion,
                cipher: envelope.cipher,
                kdf: envelope.kdf,
                iterations: envelope.iterations,
                salt: envelope.salt,
                nonce: envelope.nonce,
                ciphertext: ciphertext.base64EncodedString()
            )
        )
        #expect(throws: ProfileConfigurationEncryptionError.decryptionFailed) {
            try ProfileConfigurationEncryption.open(
                tampered,
                passphrase: "correct horse battery staple"
            )
        }
    }

    @Test
    func encryptedTransferRejectsWeakPassphrasesAndUnsupportedEnvelope() throws {
        let document = try ProfileConfigurationTransferDocument(
            profiles: [BrowserProfile(name: "Профиль")]
        )

        #expect(throws: ProfileConfigurationEncryptionError.weakPassphrase) {
            try ProfileConfigurationEncryption.seal(
                document: document,
                passphrase: "short"
            )
        }

        #expect(throws: ProfileConfigurationEncryptionError.invalidEnvelope) {
            try ProfileConfigurationEncryption.open(
                Data("not-json".utf8),
                passphrase: "correct horse battery staple"
            )
        }
    }

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
    func backgroundExportPreservesMetadataOnlyContractForPlainAndEncryptedFiles() async throws {
        let profile = BrowserProfile(
            name: "Профиль экспорта",
            note: "private note must not be exported",
            startURL: "https://example.com",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: "proxy-user"
            ),
            identity: BrowserIdentity(seed: 17)
        )
        let folders = [profile.id: "Работа"]
        let plain = try await ProfileConfigurationTransferFileImportService
            .prepareExport(
                profiles: [profile],
                folderNameByProfileID: folders
            )
        let plainText = try #require(String(data: plain, encoding: .utf8))
        #expect(plainText.contains("proxy.example"))
        #expect(plainText.contains("proxy-user"))
        #expect(plainText.contains("Работа"))
        #expect(!plainText.contains("private note"))
        #expect(!plainText.contains("runtimeSeed"))

        let encrypted = try await ProfileConfigurationTransferFileImportService
            .prepareEncryptedExport(
                profiles: [profile],
                folderNameByProfileID: folders,
                passphrase: "correct horse battery staple"
            )
        #expect(!encrypted.contains(Data("Профиль экспорта".utf8)))
        #expect(!encrypted.contains(Data("proxy-user".utf8)))
        let opened = try ProfileConfigurationEncryption.open(
            encrypted,
            passphrase: "correct horse battery staple"
        )
        #expect(opened.folderName(at: 0) == "Работа")
        #expect(try opened.makeProfiles().first?.note == "")
        #expect(try opened.makeProfiles().first?.proxy?.username == "proxy-user")
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
