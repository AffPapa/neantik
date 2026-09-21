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
        preflight: "Проверка не завершена",
        publicReleaseStatus: "Не определён"
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
    let publicReleaseStatus: String

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
        let publicReleaseStatus: String
        if runtime.flavor != .fingerprintChromium {
            publicReleaseStatus = "Не применяется к обычному движку"
        } else if let version = inspection.version,
                  Self.meetsPublicChromiumBaseline(version)
        {
            publicReleaseStatus = "Соответствует baseline"
        } else if inspection.version == nil {
            publicReleaseStatus =
                "Версия не проверена — Direct-релиз заблокирован"
        } else {
            publicReleaseStatus =
                "Ниже baseline 153.0.8010.52 — Direct-релиз заблокирован"
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
                : (preflight == nil ? "Проверка не завершена" : "Требует внимания"),
            publicReleaseStatus: publicReleaseStatus
        )
    }

    private static func meetsPublicChromiumBaseline(
        _ value: String
    ) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({
                  !$0.isEmpty &&
                      $0.allSatisfy(\.isNumber) &&
                      ($0.count == 1 || $0.first != "0")
              }),
              parts.compactMap({ Int($0) }).count == 4
        else {
            return false
        }
        let components = parts.compactMap { Int($0) }
        return components.lexicographicallyPrecedes(
            [153, 0, 8010, 52]
        ) == false
    }
}
