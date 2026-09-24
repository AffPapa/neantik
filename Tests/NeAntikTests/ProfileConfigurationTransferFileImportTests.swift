import Foundation
import Testing
@testable import NeAntik

struct ProfileConfigurationTransferFileImportTests {
    @Test
    func readsAndValidatesConfigurationOnImportService() async throws {
        let document = try ProfileConfigurationTransferDocument(
            profiles: [BrowserProfile(name: "Импорт")]
        )
        let url = try temporaryFile(
            contents: JSONEncoder().encode(document)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try await ProfileConfigurationTransferFileImportService
            .readDocument(from: url, maximumBytes: 1_024)

        #expect(imported == document)
    }

    @Test
    func rejectsOversizedFilesBeforeUnboundedRead() async throws {
        let url = try temporaryFile(contents: Data(repeating: 0x41, count: 1_025))
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ProfileConfigurationTransferFileError.fileTooLarge) {
            try await ProfileConfigurationTransferFileImportService
                .readDocument(from: url, maximumBytes: 1_024)
        }
    }

    @Test
    func rejectsMalformedAndSymbolicLinkInputs() async throws {
        let malformedURL = try temporaryFile(contents: Data("{}".utf8))
        defer { try? FileManager.default.removeItem(at: malformedURL) }

        await #expect(throws: ProfileConfigurationTransferFileError.invalidFile) {
            try await ProfileConfigurationTransferFileImportService
                .readDocument(from: malformedURL, maximumBytes: 1_024)
        }

        let targetURL = try temporaryFile(contents: Data("{}".utf8))
        defer { try? FileManager.default.removeItem(at: targetURL) }
        let linkURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        defer { try? FileManager.default.removeItem(at: linkURL) }

        await #expect(throws: ProfileConfigurationTransferFileError.invalidFile) {
            try await ProfileConfigurationTransferFileImportService
                .readDocument(from: linkURL, maximumBytes: 1_024)
        }
    }

    @Test
    func decryptsEncryptedConfigurationFromFile() async throws {
        let document = try ProfileConfigurationTransferDocument(
            profiles: [BrowserProfile(name: "Зашифрованный импорт")]
        )
        let encrypted = try ProfileConfigurationEncryption.seal(
            document: document,
            passphrase: "correct horse battery staple"
        )
        let url = try temporaryFile(contents: encrypted)
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try await ProfileConfigurationTransferFileImportService
            .readEncryptedDocument(
                from: url,
                maximumBytes: ProfileConfigurationEncryption.maximumEnvelopeBytes,
                passphrase: "correct horse battery staple"
            )

        #expect(imported == document)
    }

    @Test
    func malformedVersionAndShapeCorpusAlwaysFailsClosed() async throws {
        var payloads = [
            Data("".utf8),
            Data("null".utf8),
            Data("[]".utf8),
            Data("{\"schemaVersion\":1,\"exportedAt\":0,\"profiles\":[]}".utf8),
            Data("{\"schemaVersion\":1,\"exportedAt\":\"NaN\",\"profiles\":[]}".utf8),
            Data("{\"schemaVersion\":1,\"exportedAt\":0,\"profiles\":[null]}".utf8),
        ]
        for version in -4...8 where version != 1 {
            payloads.append(
                Data(
                    "{\"schemaVersion\":\(version),\"exportedAt\":0,\"profiles\":[]}".utf8
                )
            )
        }

        for payload in payloads {
            let url = try temporaryFile(contents: payload)
            defer { try? FileManager.default.removeItem(at: url) }
            var wasAccepted = false
            do {
                _ = try await ProfileConfigurationTransferFileImportService
                    .readDocument(from: url, maximumBytes: 1_024)
                wasAccepted = true
            } catch {
                // Malformed input is rejected without mutating profile state.
            }
            #expect(!wasAccepted)
        }
    }

    private func temporaryFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-import-\(UUID().uuidString).json")
        try contents.write(to: url, options: [.atomic])
        return url
    }
}
