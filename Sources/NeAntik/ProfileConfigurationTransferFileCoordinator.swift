import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ProfileConfigurationTransferFileCoordinator {
    static let maximumFileBytes = 16 * 1_024 * 1_024

    static func export(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String]
    ) throws -> Int? {
        guard !profiles.isEmpty else {
            throw ProfileConfigurationTransferFileError.noStoppedProfiles
        }
        let document = try ProfileConfigurationTransferDocument(
            profiles: profiles,
            folderNameByProfileID: folderNameByProfileID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumFileBytes else {
            throw ProfileConfigurationTransferFileError.fileTooLarge
        }

        let panel = NSSavePanel()
        panel.title = "Экспорт конфигурации профилей"
        panel.message =
            "Экспортируются только настройки. Cookies, BrowserData, заметки, identity и Keychain не включаются."
        panel.nameFieldStringValue = "neantik-profile-config.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        try data.write(to: url, options: [.atomic])
        return profiles.count
    }

    static func exportEncrypted(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String],
        passphrase: String
    ) throws -> Int? {
        guard !profiles.isEmpty else {
            throw ProfileConfigurationTransferFileError.noStoppedProfiles
        }
        let document = try ProfileConfigurationTransferDocument(
            profiles: profiles,
            folderNameByProfileID: folderNameByProfileID
        )
        let data = try ProfileConfigurationEncryption.seal(
            document: document,
            passphrase: passphrase
        )

        let panel = NSSavePanel()
        panel.title = "Зашифрованный экспорт профилей"
        panel.message =
            "Сохраняются только настройки профилей. Пароль не записывается в файл и не сохраняется в Keychain."
        panel.nameFieldStringValue =
            "neantik-profile-config.encrypted.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        try data.write(to: url, options: [.atomic])
        return profiles.count
    }

    static func `import`() async throws -> ProfileConfigurationTransferDocument? {
        let panel = NSOpenPanel()
        panel.title = "Импорт конфигурации профилей"
        panel.message =
            "Будут созданы новые профили без cookies, BrowserData, заметок, identity и Keychain-секретов."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await ProfileConfigurationTransferFileImportService
            .readDocument(from: url, maximumBytes: maximumFileBytes)
    }

    static func importEncrypted(
        passphrase: String
    ) async throws -> ProfileConfigurationTransferDocument? {
        let panel = NSOpenPanel()
        panel.title = "Импорт зашифрованной конфигурации"
        panel.message =
            "Будут созданы новые профили. Cookies, BrowserData и Keychain-секреты не импортируются."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await ProfileConfigurationTransferFileImportService
            .readEncryptedDocument(
                from: url,
                maximumBytes: ProfileConfigurationEncryption.maximumEnvelopeBytes,
                passphrase: passphrase
            )
    }
}

enum ProfileConfigurationTransferFileError: LocalizedError, Equatable {
    case noStoppedProfiles
    case fileTooLarge
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .noStoppedProfiles:
            "Нет остановленных профилей для экспорта."
        case .fileTooLarge:
            "Файл конфигурации слишком большой."
        case .invalidFile:
            "Не удалось прочитать конфигурацию профилей. Выбери JSON-файл NeAntik."
        }
    }
}
