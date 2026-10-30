import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ProfileConfigurationTransferFileCoordinator {
    static let maximumFileBytes = ProfileConfigurationTransferLimits.maximumFileBytes

    static func export(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String]
    ) async throws -> Int? {
        guard !profiles.isEmpty else {
            throw ProfileConfigurationTransferFileError.noStoppedProfiles
        }
        let data = try await ProfileConfigurationTransferFileImportService
            .prepareExport(
            profiles: profiles,
            folderNameByProfileID: folderNameByProfileID
        )
        try Task.checkCancellation()

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
        try await ProfileConfigurationTransferFileImportService
            .writeExport(data, to: url)
        return profiles.count
    }

    static func exportEncrypted(
        profiles: [BrowserProfile],
        folderNameByProfileID: [UUID: String],
        passphrase: String
    ) async throws -> Int? {
        guard !profiles.isEmpty else {
            throw ProfileConfigurationTransferFileError.noStoppedProfiles
        }
        let data = try await ProfileConfigurationTransferFileImportService
            .prepareEncryptedExport(
            profiles: profiles,
            folderNameByProfileID: folderNameByProfileID,
            passphrase: passphrase
        )
        try Task.checkCancellation()

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
        try await ProfileConfigurationTransferFileImportService
            .writeExport(data, to: url)
        return profiles.count
    }

    static func `import`() async throws -> ProfileConfigurationTransferDocument? {
        let panel = NSOpenPanel()
        panel.title = "Импорт конфигурации профилей"
        panel.message =
            "Будут созданы новые профили. Proxy-login входит в файл; пароли, cookies, BrowserData, заметки, identity и Keychain-секреты — нет."
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
            "Будут созданы новые профили. Proxy-login находится в зашифрованном файле; пароли, cookies, BrowserData, заметки, identity и Keychain-секреты не импортируются."
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

enum ProfileConfigurationTransferLimits {
    static let maximumFileBytes = 16 * 1_024 * 1_024
}

enum ProfileConfigurationTransferFileError: LocalizedError, Equatable, Sendable {
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
