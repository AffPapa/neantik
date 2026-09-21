import Foundation

struct RuntimeProvenanceSnapshot: Equatable, Sendable {
    static let empty = Self(
        name: "Движок не выбран",
        version: "Неизвестна",
        source: "Не проверен",
        flavor: "Неизвестен",
        architecture: "Не проверена",
        signature: "Не проверена",
        executableDigest: "Не измерен",
        frameworkDigest: "Не измерен",
        preflight: "Проверка не завершена"
    )

    let name: String
    let version: String
    let source: String
    let flavor: String
    let architecture: String
    let signature: String
    let executableDigest: String
    let frameworkDigest: String
    let preflight: String

    static func inspect(
        runtime: BrowserRuntime?,
        preflight: BrowserRuntimePreflight?
    ) -> Self {
        guard let runtime else { return .empty }
        let inspection = runtime.inspection
        let architecture: String
        if inspection.architectures.contains("arm64") {
            architecture = "Apple Silicon"
        } else if !inspection.architectures.isEmpty {
            architecture = "Неподходящая архитектура"
        } else {
            architecture = "Не проверена"
        }
        let signature = switch inspection.codeSignatureValid {
        case .some(true): "Валидна"
        case .some(false): "Невалидна"
        case .none: "Не проверена"
        }
        return Self(
            name: runtime.name,
            version: inspection.version ?? "Неизвестна",
            source: runtime.source,
            flavor: runtime.flavor.title,
            architecture: architecture,
            signature: signature,
            executableDigest: inspection.executableSHA256 == nil
                ? "Не измерен"
                : "Измерен локально",
            frameworkDigest: inspection.frameworkSHA256 == nil
                ? "Не измерен"
                : "Измерен локально",
            preflight: preflight?.isReady == true
                ? "Готов к запуску"
                : (preflight == nil ? "Проверка не завершена" : "Требует внимания")
        )
    }
}
