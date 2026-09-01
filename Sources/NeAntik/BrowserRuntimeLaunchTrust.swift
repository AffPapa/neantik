import Foundation

enum BrowserRuntimeLaunchTrustPolicy {
    static func validatedRuntime(
        resolved runtime: BrowserRuntime
    ) throws -> BrowserRuntime {
        try validatedRuntime(
            resolved: runtime,
            freshInspection: BrowserRuntimeInspector.inspectForLaunch(
                executableURL: runtime.executableURL
            )
        )
    }

    static func validatedRuntime(
        resolved runtime: BrowserRuntime,
        freshInspection: BrowserRuntimeInspection
    ) throws -> BrowserRuntime {
        let refreshed = BrowserRuntime(
            name: runtime.name,
            executableURL: runtime.executableURL,
            source: runtime.source,
            flavor: runtime.flavor,
            capabilities: runtime.capabilities,
            inspection: freshInspection
        )
        let preflight = BrowserRuntimePreflightValidator.validate(refreshed)
        guard preflight.isReady else {
            throw NeAntikError.runtimeValidationFailed(
                preflight.errors.joined(separator: " ")
            )
        }

        guard runtime.inspection.version == freshInspection.version,
              runtime.inspection.architectures.sorted() ==
                freshInspection.architectures.sorted(),
              runtime.inspection.codeSignatureValid ==
                freshInspection.codeSignatureValid
        else {
            throw NeAntikError.runtimeValidationFailed(
                "Встроенный браузер изменился после проверки. " +
                    "Перезапусти NeAntik из официальной установки."
            )
        }

        if runtime.supportsFingerprintIdentity {
            guard let resolvedIdentity =
                    runtime.inspection.executableIdentity,
                  let freshIdentity = freshInspection.executableIdentity,
                  resolvedIdentity == freshIdentity
            else {
                throw NeAntikError.runtimeValidationFailed(
                    "Не удалось подтвердить неизменность встроенного " +
                        "браузера перед запуском."
                )
            }
        }
        return refreshed
    }
}
