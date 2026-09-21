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

    static func `import`() throws -> ProfileConfigurationTransferDocument? {
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
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize,
           fileSize > maximumFileBytes {
            throw ProfileConfigurationTransferFileError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumFileBytes else {
            throw ProfileConfigurationTransferFileError.fileTooLarge
        }
        do {
            return try JSONDecoder().decode(
                ProfileConfigurationTransferDocument.self,
                from: data
            )
        } catch let error as ProfileConfigurationTransferError {
            throw error
        } catch {
            throw ProfileConfigurationTransferFileError.invalidFile
        }
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
