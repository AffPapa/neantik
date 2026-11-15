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
        panel.title = NSLocalizedString("userDialog.001", tableName: "Errors", bundle: .main, value: "Экспорт конфигурации профилей", comment: "")
        panel.message =
            NSLocalizedString("userDialog.002", tableName: "Errors", bundle: .main, value: "Экспортируются только настройки. Cookies, BrowserData, заметки, identity и Keychain не включаются.", comment: "")
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
        panel.title = NSLocalizedString("userDialog.003", tableName: "Errors", bundle: .main, value: "Зашифрованный экспорт профилей", comment: "")
        panel.message =
            NSLocalizedString("userDialog.004", tableName: "Errors", bundle: .main, value: "Сохраняются только настройки профилей. Пароль не записывается в файл и не сохраняется в Keychain.", comment: "")
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
        panel.title = NSLocalizedString("userDialog.005", tableName: "Errors", bundle: .main, value: "Импорт конфигурации профилей", comment: "")
        panel.message =
            NSLocalizedString("userDialog.006", tableName: "Errors", bundle: .main, value: "Будут созданы новые профили. Proxy-login входит в файл; пароли, cookies, BrowserData, заметки, identity и Keychain-секреты — нет.", comment: "")
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
        panel.title = NSLocalizedString("userDialog.007", tableName: "Errors", bundle: .main, value: "Импорт зашифрованной конфигурации", comment: "")
        panel.message =
            NSLocalizedString("userDialog.008", tableName: "Errors", bundle: .main, value: "Будут созданы новые профили. Proxy-login находится в зашифрованном файле; пароли, cookies, BrowserData, заметки, identity и Keychain-секреты не импортируются.", comment: "")
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
            NSLocalizedString("userError.100", tableName: "Errors", bundle: .main, value: "Нет остановленных профилей для экспорта.", comment: "")
        case .fileTooLarge:
            NSLocalizedString("userError.101", tableName: "Errors", bundle: .main, value: "Файл конфигурации слишком большой.", comment: "")
        case .invalidFile:
            NSLocalizedString("userError.102", tableName: "Errors", bundle: .main, value: "Не удалось прочитать конфигурацию профилей. Выбери JSON-файл NeAntik.", comment: "")
        }
    }
}
