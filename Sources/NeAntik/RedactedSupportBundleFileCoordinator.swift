import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum RedactedSupportBundleFileCoordinator {
    static let maximumFileBytes = 64 * 1_024

    static func export(
        bundle: RedactedSupportBundle
    ) throws -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        guard data.count <= maximumFileBytes else {
            throw RedactedSupportBundleError.fileTooLarge
        }

        let panel = NSSavePanel()
        panel.title = "Экспорт безопасной диагностики"
        panel.message =
            "Файл содержит только агрегированные статусы и версии. Имена профилей, пути, cookies, proxy и raw fingerprint не включаются."
        panel.nameFieldStringValue = "neantik-support-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        try data.write(to: url, options: [.atomic])
        return url
    }
}
