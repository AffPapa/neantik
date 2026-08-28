import Foundation

enum DiagnosticEvidenceState: String, Equatable, Sendable {
    case configured
    case derived
    case observed
    case unavailable
    case unverified

    var title: String {
        switch self {
        case .configured: "Настроено"
        case .derived: "Рассчитано"
        case .observed: "Измерено"
        case .unavailable: "Недоступно"
        case .unverified: "Не подтверждено"
        }
    }
}

/// The user-facing meaning of a diagnostic finding. This deliberately stays
/// separate from `DiagnosticEvidenceState`, which describes only where the
/// evidence came from (configured, derived, observed, and so on).
enum DiagnosticFindingSeverity: Int, Equatable, Hashable, Sendable {
    case neutral
    case success
    case attention
    case failure
    case blocking
}

enum DiagnosticResolutionKey: String, Equatable, Hashable, Sendable {
    case proxyContext
    case runtimeIntegrity
    case fingerprintAudit
}

enum DiagnosticResolutionMode: Equatable, Sendable {
    case automaticNow
    case fixOnNextLaunch
    case actionRequired
    case informational
    case notApplicable
}

enum DiagnosticAction: Equatable, Sendable {
    case testProxy
    case editProxy
    case runFingerprintAudit
}

struct DiagnosticResolution: Equatable, Sendable {
    let key: DiagnosticResolutionKey
    let mode: DiagnosticResolutionMode
    let action: DiagnosticAction?
}

struct EnvironmentDiagnosticField: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let value: String
    let state: DiagnosticEvidenceState
    let severity: DiagnosticFindingSeverity
    let resolution: DiagnosticResolution?
    let detail: String?
    let observedAt: Date?

    init(
        id: String,
        title: String,
        value: String,
        state: DiagnosticEvidenceState,
        severity: DiagnosticFindingSeverity = .neutral,
        resolution: DiagnosticResolution? = nil,
        detail: String? = nil,
        observedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.state = state
        self.severity = severity
        self.resolution = resolution
        self.detail = detail
        self.observedAt = observedAt
    }
}

struct EnvironmentDiagnosticSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let fields: [EnvironmentDiagnosticField]
}

struct ProfileEnvironmentSnapshot: Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let profileID: UUID
    let generatedAt: Date
    let sections: [EnvironmentDiagnosticSection]
    let limitations: [String]
}

enum FingerprintObservedRoute: Equatable, Sendable {
    case direct
    case proxied
}

enum WebRTCLoopbackObservation: Equatable, Sendable {
    case passed
    case failed
    case incomplete
}

/// A deliberately bounded input produced only after the caller has validated
/// a local fingerprint report against the selected profile and runtime. It
/// cannot carry raw surface values, candidate addresses, hashes or a seed.
struct ValidatedProfileFingerprintObservation: Equatable, Sendable {
    static let freshnessLifetime: TimeInterval = 24 * 60 * 60

    let profileID: UUID
    let observedAt: Date
    let route: FingerprintObservedRoute
    let verdict: FingerprintAuditVerdict
    let webRTCLoopback: WebRTCLoopbackObservation
    let configurationRevision: ProfileFingerprintConfigurationRevision?

    init(
        profileID: UUID,
        observedAt: Date,
        route: FingerprintObservedRoute,
        verdict: FingerprintAuditVerdict,
        webRTCLoopback: WebRTCLoopbackObservation,
        configurationRevision: ProfileFingerprintConfigurationRevision? = nil
    ) {
        self.profileID = profileID
        self.observedAt = observedAt
        self.route = route
        self.verdict = verdict
        self.webRTCLoopback = webRTCLoopback
        self.configurationRevision = configurationRevision
    }

    func bound(
        to profile: BrowserProfile,
        runtime: BrowserRuntime
    ) -> Self? {
        guard profile.id == profileID else { return nil }
        return Self(
            profileID: profileID,
            observedAt: observedAt,
            route: route,
            verdict: verdict,
            webRTCLoopback: webRTCLoopback,
            configurationRevision: ProfileFingerprintConfigurationRevision(
                profile: profile,
                runtime: runtime
            )
        )
    }

    func isUsable(
        for profile: BrowserProfile,
        runtime: BrowserRuntime?,
        now: Date
    ) -> Bool {
        guard profile.id == profileID,
              let runtime,
              configurationRevision == ProfileFingerprintConfigurationRevision(
                profile: profile,
                runtime: runtime
              )
        else {
            return false
        }
        let age = now.timeIntervalSince(observedAt)
        return observedAt.timeIntervalSinceReferenceDate.isFinite &&
            age >= -5 * 60 &&
            age <= Self.freshnessLifetime
    }
}

/// Exact, in-memory binding for evidence produced by a fingerprint audit.
/// It is intentionally not encoded or exported by the public workspace DTO.
struct ProfileFingerprintConfigurationRevision: Equatable, Sendable {
    let identity: BrowserIdentity
    let proxy: ProxyConfiguration?
    let runtime: BrowserRuntime

    init(profile: BrowserProfile, runtime: BrowserRuntime) {
        identity = profile.identity
        proxy = profile.proxy
        self.runtime = runtime
    }
}

enum ProfileEnvironmentInspector {
    static func snapshot(
        profile: BrowserProfile,
        runtime: BrowserRuntime?,
        proxyHealth: ProxyHealthState?,
        fingerprintObservation:
            ValidatedProfileFingerprintObservation? = nil,
        now: Date = Date()
    ) -> ProfileEnvironmentSnapshot {
        let capabilities = runtime?.capabilities ?? []
        let policy = BrowserLaunchPolicy.resolve(
            profile: profile,
            runtimeCapabilities: capabilities,
            now: now
        )
        let usableFingerprintObservation:
            ValidatedProfileFingerprintObservation?
        if let fingerprintObservation,
           fingerprintObservation.profileID == profile.id,
           fingerprintObservation.isUsable(
               for: profile,
               runtime: runtime,
               now: now
           ),
           fingerprintObservation.route == observedRoute(for: policy.route)
        {
            usableFingerprintObservation = fingerprintObservation
        } else {
            usableFingerprintObservation = nil
        }

        return ProfileEnvironmentSnapshot(
            schemaVersion: ProfileEnvironmentSnapshot.currentSchemaVersion,
            profileID: profile.id,
            generatedAt: now,
            sections: [
                routeSection(
                    policy: policy,
                    proxyHealth: proxyHealth
                ),
                fingerprintSection(
                    profile: profile,
                    runtime: runtime,
                    policy: policy,
                    observation: usableFingerprintObservation
                ),
                webRTCSection(
                    policy: policy,
                    observation: usableFingerprintObservation
                ),
                transportSection(policy: policy),
                geolocationSection(
                    profile: profile,
                    policy: policy,
                    proxyHealth: proxyHealth
                )
            ],
            limitations: [
                "Настройка сама по себе не доказывает " +
                    "фактический сетевой маршрут.",
                "Проверка прокси наблюдает запрос curl, а не " +
                    "маршрут запущенного Chromium.",
                "Фактические HTTP, DNS, QUIC и публичный " +
                    "WebRTC-маршруты не измеряются."
            ]
        )
    }

    private static func routeSection(
        policy: BrowserLaunchPolicy,
        proxyHealth: ProxyHealthState?
    ) -> EnvironmentDiagnosticSection {
        let routeValue: String
        switch policy.route {
        case .direct:
            routeValue = "Прямое подключение"
        case let .proxied(kind):
            routeValue = "Через \(kind.title)-прокси"
        }
        var fields = [
            EnvironmentDiagnosticField(
                id: "route.mode",
                title: "Режим",
                value: routeValue,
                state: .configured,
                severity: .success
            )
        ]
        if let attempt = proxyHealth?.latestAttempt {
            let routeContextIsComplete =
                proxyHealth?.hasCompleteRouteContext == true
            let probeSucceeded = attempt.outcome == .succeeded
            let probeSeverity: DiagnosticFindingSeverity =
                probeSucceeded && routeContextIsComplete
                ? .success
                : (probeSucceeded ? .attention : .failure)
            let probeAction: DiagnosticAction
            switch attempt.outcome {
            case .invalidConfiguration, .authenticationRejected:
                probeAction = .editProxy
            default:
                probeAction = .testProxy
            }
            let probeResolution =
                probeSucceeded && routeContextIsComplete
                ? nil
                : DiagnosticResolution(
                    key: .proxyContext,
                    mode: .actionRequired,
                    action: probeAction
                )
            fields.append(
                EnvironmentDiagnosticField(
                    id: "route.last-probe",
                    title: "Последняя проверка",
                    value: attempt.outcome == .succeeded
                        ? responseSummary(
                            milliseconds: attempt.responseTimeMilliseconds
                          )
                        : attempt.outcome.userSummary,
                    state: .observed,
                    severity: probeSeverity,
                    resolution: probeResolution,
                    detail:
                        "Результат относится только к моменту проверки.",
                    observedAt: attempt.checkedAt
                )
            )
        } else if case .proxied = policy.route {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "route.last-probe",
                    title: "Последняя проверка",
                    value: "Проверится автоматически перед запуском",
                    state: .unverified,
                    severity: .neutral,
                    resolution: DiagnosticResolution(
                        key: .proxyContext,
                        mode: .fixOnNextLaunch,
                        action: .testProxy
                    ),
                    detail:
                        "Если проверка не пройдёт, NeAntik остановит запуск."
                )
            )
        }
        fields.append(
            EnvironmentDiagnosticField(
                id: "route.chromium-http",
                title: "HTTP-маршрут Chromium",
                value: "Не измерялся",
                state: .unverified,
                severity: .neutral,
                detail:
                    "Проверка прокси выполняется curl и не " +
                    "подтверждает маршрут Chromium."
            )
        )
        return EnvironmentDiagnosticSection(
            id: "route",
            title: "Маршрут и прокси",
            fields: fields
        )
    }

    private static func fingerprintSection(
        profile: BrowserProfile,
        runtime: BrowserRuntime?,
        policy: BrowserLaunchPolicy,
        observation: ValidatedProfileFingerprintObservation?
    ) -> EnvironmentDiagnosticSection {
        var fields: [EnvironmentDiagnosticField] = []
        if let runtime {
            let version = safeText(runtime.inspection.version)
            let versionSuffix = version.map { " · \($0)" } ?? ""
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.runtime",
                    title: "Движок",
                    value: policy.fingerprintIdentityConfigured
                        ? "Chromium с разделением отпечатков" +
                            versionSuffix
                        : "Обычный Chromium" +
                            versionSuffix,
                    state: .configured,
                    severity: .success
                )
            )
            let signatureValue: String
            let signatureState: DiagnosticEvidenceState
            let signatureSeverity: DiagnosticFindingSeverity
            switch runtime.inspection.codeSignatureValid {
            case .some(true):
                signatureValue = "Подпись подтверждена локально"
                signatureState = .observed
                signatureSeverity = .success
            case .some(false):
                signatureValue = "Подпись не подтверждена"
                signatureState = .observed
                signatureSeverity = .failure
            case .none:
                signatureValue = "Подпись не удалось проверить"
                signatureState = .unverified
                signatureSeverity = .attention
            }
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.runtime-signature",
                    title: "Подпись движка",
                    value: signatureValue,
                    state: signatureState,
                    severity: signatureSeverity
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.runtime",
                    title: "Движок",
                    value: "Браузерный движок не найден",
                    state: .unavailable,
                    severity: .blocking
                )
            )
        }

        fields.append(
            EnvironmentDiagnosticField(
                id: "fingerprint.device-tuple",
                title: "Профиль устройства",
                value: deviceTupleTitle(profile.identity.deviceTupleID),
                state: .derived,
                severity: .neutral,
                detail: policy.fingerprintIdentityConfigured
                    ? "Рассчитан из стабильной конфигурации " +
                        "профиля."
                    : "Будет применён только совместимым движком."
            )
        )

        if policy.fingerprintIdentityConfigured {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.configuration",
                    title: "Стабильная конфигурация",
                    value: "Назначена этому профилю",
                    state: .configured,
                    severity: .success
                )
            )
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.webgpu",
                    title: "WebGPU",
                    value: policy.webGPUDisabled
                        ? "Отключён до поддержки согласованного " +
                            "профиля устройства"
                        : "NeAntik не меняет настройку",
                    state: .configured,
                    severity: .success
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.configuration",
                    title: "Разделение отпечатков",
                    value: "Доступна только изоляция данных",
                    state: .unavailable,
                    severity: .neutral
                )
            )
        }

        if let observation {
            let observationSeverity = fingerprintSeverity(
                for: observation.verdict
            )
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.observation",
                    title: "Проверка поверхностей",
                    value: observation.verdict.title,
                    state: .observed,
                    severity: observationSeverity,
                    resolution: observationSeverity == .success
                        ? nil
                        : DiagnosticResolution(
                            key: .fingerprintAudit,
                            mode: .actionRequired,
                            action: .runFingerprintAudit
                        ),
                    detail:
                        "Локальное сравнение A → B → A без " +
                        "внешнего сервиса проверки.",
                    observedAt: observation.observedAt
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.observation",
                    title: "Проверка поверхностей",
                    value: policy.fingerprintIdentityConfigured
                        ? "Дополнительная проверка не запускалась"
                        : "Текущий движок не поддерживает проверку",
                    state: policy.fingerprintIdentityConfigured
                        ? .unverified
                        : .unavailable,
                    severity: .neutral,
                    resolution: policy.fingerprintIdentityConfigured
                        ? DiagnosticResolution(
                            key: .fingerprintAudit,
                            mode: .informational,
                            action: nil
                        )
                        : nil,
                    detail: policy.fingerprintIdentityConfigured
                        ? "Необязательно для обычного запуска. " +
                            "Доступно в дополнительных проверках."
                        : nil
                )
            )
        }

        return EnvironmentDiagnosticSection(
            id: "fingerprint",
            title: "Fingerprint",
            fields: fields
        )
    }

    private static func webRTCSection(
        policy: BrowserLaunchPolicy,
        observation: ValidatedProfileFingerprintObservation?
    ) -> EnvironmentDiagnosticSection {
        let policyValue = switch policy.webRTC {
        case .publicInterfaceOnly:
            "Только публичный интерфейс"
        case .disableNonProxiedUDP:
            "Запрещён UDP вне прокси"
        }
        var fields = [
            EnvironmentDiagnosticField(
                id: "webrtc.policy",
                title: "Политика",
                value: policyValue,
                state: .configured,
                severity: .success
            )
        ]
        if let observation {
            let value = switch observation.webRTCLoopback {
            case .passed:
                "Локальный контроль пройден"
            case .failed:
                "Локальный контроль выявил проблему"
            case .incomplete:
                "Локальный контроль не завершён"
            }
            let severity: DiagnosticFindingSeverity =
                switch observation.webRTCLoopback {
                case .passed: .success
                case .failed: .failure
                case .incomplete: .attention
                }
            fields.append(
                EnvironmentDiagnosticField(
                    id: "webrtc.loopback",
                    title: "Локальный контроль",
                    value: value,
                    state: .observed,
                    severity: severity,
                    resolution: severity == .success
                        ? nil
                        : DiagnosticResolution(
                            key: .fingerprintAudit,
                            mode: .actionRequired,
                            action: .runFingerprintAudit
                        ),
                    detail:
                        "Loopback STUN; адреса и строки " +
                        "кандидатов не сохраняются.",
                    observedAt: observation.observedAt
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "webrtc.loopback",
                    title: "Локальный контроль",
                    value: "Дополнительная проверка не запускалась",
                    state: .unverified,
                    severity: .neutral,
                    resolution: DiagnosticResolution(
                        key: .fingerprintAudit,
                        mode: .informational,
                        action: nil
                    ),
                    detail: "Необязательно для обычного запуска."
                )
            )
        }
        fields.append(
            EnvironmentDiagnosticField(
                id: "webrtc.public-route",
                title: "Публичный WebRTC-маршрут",
                value: "Не измерялся",
                state: .unverified,
                severity: .neutral,
                detail:
                    "Локальный контроль не доказывает " +
                    "отсутствие всех сетевых утечек."
            )
        )
        return EnvironmentDiagnosticSection(
            id: "webrtc",
            title: "WebRTC",
            fields: fields
        )
    }

    private static func transportSection(
        policy: BrowserLaunchPolicy
    ) -> EnvironmentDiagnosticSection {
        let quicValue = switch policy.quic {
        case .disabledByNeAntik:
            "Отключён настройками запуска"
        case .notDisabledByNeAntik:
            "NeAntik не отключает QUIC"
        }
        let dnsValue = switch policy.dns {
        case .ordinaryChromium:
            "Обычная политика Chromium и macOS"
        case .proxyResolverFailClosed:
            "Прямое разрешение сайтов ограничено"
        }
        return EnvironmentDiagnosticSection(
            id: "transport",
            title: "QUIC и DNS",
            fields: [
                EnvironmentDiagnosticField(
                    id: "transport.quic-policy",
                    title: "QUIC",
                    value: quicValue,
                    state: .configured,
                    severity: .success
                ),
                EnvironmentDiagnosticField(
                    id: "transport.dns-policy",
                    title: "DNS",
                    value: dnsValue,
                    state: policy.dns == .ordinaryChromium
                        ? .derived
                        : .configured,
                    severity: policy.dns == .ordinaryChromium
                        ? .neutral
                        : .success
                ),
                EnvironmentDiagnosticField(
                    id: "transport.quic-observed",
                    title: "Фактический QUIC / HTTP/3",
                    value: "Не измерялся",
                    state: .unverified,
                    severity: .neutral
                ),
                EnvironmentDiagnosticField(
                    id: "transport.dns-observed",
                    title: "Фактический DNS-маршрут",
                    value: "Не измерялся",
                    state: .unverified,
                    severity: .neutral
                )
            ]
        )
    }

    private static func geolocationSection(
        profile: BrowserProfile,
        policy: BrowserLaunchPolicy,
        proxyHealth: ProxyHealthState?
    ) -> EnvironmentDiagnosticSection {
        guard case .proxied = policy.route else {
            return EnvironmentDiagnosticSection(
                id: "geolocation",
                title: "Геолокация",
                fields: [
                    EnvironmentDiagnosticField(
                        id: "geolocation.proxy",
                        title: "Контекст прокси",
                        value: "Для прямого профиля не применяется",
                        state: .unavailable,
                        severity: .neutral
                    ),
                    browserGeolocationField
                ]
            )
        }

        var fields: [EnvironmentDiagnosticField] = []
        if let success = proxyHealth?.lastSuccess {
            let routeContextIsComplete =
                proxyHealth?.hasCompleteRouteContext == true
            let contextResolution = routeContextIsComplete
                ? nil
                : DiagnosticResolution(
                    key: .proxyContext,
                    mode: .actionRequired,
                    action: .testProxy
                )
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.source",
                    title: "Источник",
                    value: "ipapi.co через проверку прокси",
                    state: .observed,
                    severity: routeContextIsComplete
                        ? .success
                        : .attention,
                    resolution: contextResolution,
                    observedAt: success.observedAt
                )
            )
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.location",
                    title: "Примерная локация",
                    value: safeLocationSummary(success),
                    state: .observed,
                    severity: routeContextIsComplete
                        ? .success
                        : .attention,
                    resolution: contextResolution,
                    detail:
                        "Определена по выходному IP прокси; " +
                        "точный IP здесь не хранится.",
                    observedAt: success.observedAt
                )
            )
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.context",
                    title: "Часовой пояс и язык",
                    value: contextSummary(success),
                    state: .observed,
                    severity: routeContextIsComplete
                        ? .success
                        : .attention,
                    resolution: contextResolution,
                    observedAt: success.observedAt
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.source",
                    title: "Контекст прокси",
                    value: "Обновится автоматически перед запуском",
                    state: .unverified,
                    severity: .neutral,
                    resolution: DiagnosticResolution(
                        key: .proxyContext,
                        mode: .fixOnNextLaunch,
                        action: .testProxy
                    )
                )
            )
        }

        let appliedValues = [
            policy.appliedTimezoneIdentifier,
            policy.appliedLocaleIdentifier
        ].compactMap { $0 }
        if !policy.fingerprintSeedConfigured {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.launch",
                    title: "При запуске",
                    value: "Движок не принимает контекст профиля",
                    state: .unavailable,
                    severity: .attention
                )
            )
        } else if policy.proxyContextIsFresh, appliedValues.count == 2 {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.launch",
                    title: "При запуске",
                    value: appliedValues.joined(separator: " · "),
                    state: .derived,
                    severity: .success,
                    detail:
                        "Будут применены только к этому запуску профиля."
                )
            )
        } else {
            let hasStoredContext =
                profile.identity.timezoneIdentifier != nil ||
                profile.identity.localeIdentifier != nil
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.launch",
                    title: "При запуске",
                    value: hasStoredContext
                        ? "Устаревший контекст обновится перед запуском"
                        : "Контекст определится перед запуском",
                    state: .unverified,
                    severity: .neutral,
                    resolution: DiagnosticResolution(
                        key: .proxyContext,
                        mode: .fixOnNextLaunch,
                        action: .testProxy
                    ),
                    detail:
                        "Если прокси или контекст не подтвердятся, " +
                        "NeAntik остановит запуск."
                )
            )
        }
        fields.append(browserGeolocationField)
        return EnvironmentDiagnosticSection(
            id: "geolocation",
            title: "Геолокация",
            fields: fields
        )
    }

    private static var browserGeolocationField: EnvironmentDiagnosticField {
        EnvironmentDiagnosticField(
            id: "geolocation.browser-api",
            title: "Geolocation API браузера",
            value: "Не измеряется",
            state: .unavailable,
            severity: .neutral,
            detail:
                "IP-геолокация не является GPS или " +
                "navigator.geolocation."
        )
    }

    private static func fingerprintSeverity(
        for verdict: FingerprintAuditVerdict
    ) -> DiagnosticFindingSeverity {
        switch verdict {
        case .verified: .success
        case .partial: .attention
        case .unchanged, .unstable: .failure
        }
    }

    private static func observedRoute(
        for route: BrowserRoutePolicy
    ) -> FingerprintObservedRoute {
        switch route {
        case .direct: .direct
        case .proxied: .proxied
        }
    }

    private static func responseSummary(milliseconds: Int?) -> String {
        guard let milliseconds else {
            return "Успешно"
        }
        return "Успешно · отклик \(milliseconds) мс"
    }

    private static func safeLocationSummary(
        _ success: ProxyHealthSuccess
    ) -> String {
        let values = [
            safeText(success.city),
            safeText(success.countryName),
            safeText(success.countryCode)
        ].compactMap { $0 }
        return values.isEmpty ? "IP подтверждён" : values.joined(separator: ", ")
    }

    private static func contextSummary(
        _ success: ProxyHealthSuccess
    ) -> String {
        let values = [
            safeText(success.timezoneIdentifier),
            safeText(success.localeIdentifier)
        ].compactMap { $0 }
        return values.isEmpty ? "Не определены" : values.joined(separator: " · ")
    }

    private static func safeText(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean.utf8.count <= 128,
              clean.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return clean
    }

    private static func deviceTupleTitle(_ tupleID: String) -> String {
        switch tupleID {
        case "macbook-air-m1": "MacBook Air M1"
        case "macbook-pro-m1-pro": "MacBook Pro M1 Pro"
        case "macbook-air-m2": "MacBook Air M2"
        case "macbook-pro-m2-max": "MacBook Pro M2 Max"
        case "macbook-pro-m2-pro": "MacBook Pro M2 Pro"
        case "macbook-air-m3": "MacBook Air M3"
        case "macbook-pro-m3-max": "MacBook Pro M3 Max"
        case "macbook-pro-m3-pro": "MacBook Pro M3 Pro"
        case "macbook-air-m4": "MacBook Air M4"
        case "macbook-pro-m4-max": "MacBook Pro M4 Max"
        case "macbook-pro-m4-pro": "MacBook Pro M4 Pro"
        default: "Профиль устройства из каталога NeAntik"
        }
    }
}
