import Foundation

struct BrowserRuntimePreflight: Equatable, Sendable {
    let errors: [String]
    let warnings: [String]

    var isReady: Bool {
        errors.isEmpty
    }

    var primaryMessage: String? {
        errors.first ?? warnings.first
    }
}

enum BrowserRuntimePreflightValidator {
    static func validate(_ runtime: BrowserRuntime) -> BrowserRuntimePreflight {
        var errors: [String] = []
        var warnings: [String] = []
        let path = runtime.executableURL.path

        if !FileManager.default.fileExists(atPath: path) {
            errors.append("Выбранный файл браузера больше не существует.")
        } else if !FileManager.default.isExecutableFile(atPath: path) {
            errors.append("Выбранный файл нельзя запустить.")
        }

        if runtime.inspection.architectures.isEmpty {
            errors.append("Выбранный файл не похож на macOS-браузер.")
        } else if !runtime.inspection.supportsAppleSilicon {
            errors.append("NeAntik нужен браузерный движок под Apple Silicon.")
        }

        switch runtime.inspection.codeSignatureValid {
        case .some(false):
            errors.append("Подпись браузера некорректна.")
        case .none:
            warnings.append("Подпись браузера не удалось проверить.")
        case .some(true):
            break
        }

        if runtime.supportsFingerprintIdentity,
           runtime.inspection.version == nil {
            warnings.append("Версия движка с разделением отпечатков неизвестна.")
        }
        if runtime.supportsFingerprintIdentity {
            warnings.append(
                "Движок с разделением отпечатков подключён. Для релиза нужна проверка."
            )
        }

        return BrowserRuntimePreflight(
            errors: errors,
            warnings: warnings
        )
    }
}
