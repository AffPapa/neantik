import Foundation

enum DiagnosticEvidenceState: String, Equatable, Sendable {
    case configured
    case derived
    case observed
    case unavailable
    case unverified

    var title: String {
        switch self {
        case .configured: NSLocalizedString("page.400", tableName: "Pages", bundle: .main, value: "Настроено", comment: "")
        case .derived: NSLocalizedString("page.401", tableName: "Pages", bundle: .main, value: "Рассчитано", comment: "")
        case .observed: NSLocalizedString("page.402", tableName: "Pages", bundle: .main, value: "Измерено", comment: "")
        case .unavailable: NSLocalizedString("page.403", tableName: "Pages", bundle: .main, value: "Недоступно", comment: "")
        case .unverified: NSLocalizedString("page.404", tableName: "Pages", bundle: .main, value: "Не подтверждено", comment: "")
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
    var siteCompatibility: SiteCompatibilityAssessment? = nil
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
    let fontPolicy: BrowserFontPolicy
    let privacyPolicy: BrowserPrivacyPolicy

    init(profile: BrowserProfile, runtime: BrowserRuntime) {
        identity = profile.identity
        proxy = profile.proxy
        fontPolicy = profile.fontPolicy
        privacyPolicy = profile.privacyPolicy
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
        siteCompatibility: SiteCompatibilityAssessment? = nil,
        privacyParametersSent: Bool = false,
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
                protectionSection(profile: profile, runtime: runtime, parametersSent: privacyParametersSent),
                siteProtectionSection(profile: profile),
                routeSection(
                    policy: policy,
                    proxyHealth: proxyHealth,
                    now: now
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
                    proxyHealth: proxyHealth,
                    now: now
                )
            ],
            limitations: [
                NSLocalizedString("page.405", tableName: "Pages", bundle: .main, value: "Настройка сама по себе не доказывает ", comment: "") +
                    NSLocalizedString("page.406", tableName: "Pages", bundle: .main, value: "фактический сетевой маршрут.", comment: ""),
                NSLocalizedString("page.407", tableName: "Pages", bundle: .main, value: "Проверка прокси наблюдает запрос curl, а не ", comment: "") +
                    NSLocalizedString("page.408", tableName: "Pages", bundle: .main, value: "маршрут запущенного Chromium.", comment: ""),
                NSLocalizedString("page.409", tableName: "Pages", bundle: .main, value: "Фактические HTTP, DNS, QUIC и публичный ", comment: "") +
                    NSLocalizedString("page.410", tableName: "Pages", bundle: .main, value: "WebRTC-маршруты не измеряются.", comment: "")
            ],
            siteCompatibility: siteCompatibility?.isUsable(
                for: profile, runtime: runtime, now: now
            ) == true ? siteCompatibility : nil
        )
    }

    private static func protectionSection(
        profile: BrowserProfile, runtime: BrowserRuntime?, parametersSent: Bool
    ) -> EnvironmentDiagnosticSection {
        let compatible = runtime?.supportsProfilePrivacy == true
        let localStart = BrowserStartURL.validate(profile.startURL)?.absoluteString == "about:blank"
        let restoresSession = BrowserLaunchBuilder.restoresSession(profile: profile)
        return EnvironmentDiagnosticSection(
            id: "protection",
            title: NSLocalizedString("page.411", tableName: "Pages", bundle: .main, value: "Паспорт защиты", comment: ""),
            fields: (profile.privacyPolicy == .legacy ? [] : [
                EnvironmentDiagnosticField(
                    id: "protection.policy",
                    title: NSLocalizedString("page.412", tableName: "Pages", bundle: .main, value: "Сохранённый режим защиты", comment: ""),
                    value: profile.privacyPolicy.presetName,
                    state: .configured,
                    detail: NSLocalizedString("page.413", tableName: "Pages", bundle: .main, value: "Это настройки профиля. Изменение режима не считается измерением защиты.", comment: "")
                ),
                EnvironmentDiagnosticField(
                    id: "protection.runtime", title: NSLocalizedString("page.414", tableName: "Pages", bundle: .main, value: "Поддержка движка", comment: ""),
                    value: compatible ? NSLocalizedString("page.415", tableName: "Pages", bundle: .main, value: "Точный подписанный движок распознан", comment: "") : NSLocalizedString("page.416", tableName: "Pages", bundle: .main, value: "Нужен совместимый движок", comment: ""),
                    state: compatible ? .observed : .unavailable,
                    severity: compatible ? .neutral : .blocking,
                    detail: NSLocalizedString("page.417", tableName: "Pages", bundle: .main, value: "Сверяются подпись и полный набор файлов. Синтетический тест на этом Mac проверил RTC-off, LAN, графику и изоляцию хранилищ; он не доказывает отсутствие всех утечек.", comment: "")
                ),
                EnvironmentDiagnosticField(
                    id: "protection.applied", title: NSLocalizedString("page.418", tableName: "Pages", bundle: .main, value: "Текущий сеанс", comment: ""),
                    value: parametersSent ? NSLocalizedString("page.419", tableName: "Pages", bundle: .main, value: "Параметры переданы запущенному процессу", comment: "") : NSLocalizedString("page.420", tableName: "Pages", bundle: .main, value: "Применение к текущему сеансу не подтверждено", comment: ""),
                    state: parametersSent ? .configured : .unverified,
                    detail: NSLocalizedString("page.421", tableName: "Pages", bundle: .main, value: "Передача параметров не является измерением API страницы. Эффективные правила сайтов и сторонних cookies показаны в расширении «Защита сайтов».", comment: "")
                ),
                EnvironmentDiagnosticField(
                    id: "protection.controls", title: NSLocalizedString("page.422", tableName: "Pages", bundle: .main, value: "Ограничения", comment: ""),
                    value: String(format: NSLocalizedString("page.423", tableName: "Pages", bundle: .main, value: "RTC: %@ · LAN: %@ · разрешения: %@", comment: ""), String(describing: profile.privacyPolicy.rtc.rawValue), String(describing: profile.privacyPolicy.localNetwork.rawValue), String(describing: profile.privacyPolicy.media.rawValue)),
                    state: .configured,
                    detail: NSLocalizedString("page.424", tableName: "Pages", bundle: .main, value: "При RTC proxyOnly без прокси WebRTC выключен. С прокси политика ограничивает прямой UDP; работа TURN зависит от сайта и не подтверждена проверкой маршрута. Строгий режим запрещает создание RTCPeerConnection.", comment: "")
                ),
                EnvironmentDiagnosticField(
                    id: "protection.extensions", title: NSLocalizedString("page.425", tableName: "Pages", bundle: .main, value: "Расширения, Sync и autofill", comment: ""),
                    value: profile.proxy != nil || profile.privacyPolicy.restrictsUserExtensions ? NSLocalizedString("page.426", tableName: "Pages", bundle: .main, value: "Настроено отключение обычных расширений", comment: "") : NSLocalizedString("page.427", tableName: "Pages", bundle: .main, value: "Допускаются отдельные расширения профиля", comment: ""),
                    state: .configured,
                    detail: (profile.proxy != nil || profile.privacyPolicy.restrictsUserExtensions
                        ? NSLocalizedString("page.428", tableName: "Pages", bundle: .main, value: "При запуске совместимого движка передаётся ограничение обычных расширений. ", comment: "")
                        : NSLocalizedString("page.429", tableName: "Pages", bundle: .main, value: "Отдельные расширения профиля разрешены. ", comment: "")) +
                        NSLocalizedString("page.430", tableName: "Pages", bundle: .main, value: "Компоненты браузера и системные интеграции могут сохраняться. ", comment: "") +
                        (profile.proxy != nil ? NSLocalizedString("page.431", tableName: "Pages", bundle: .main, value: "В совместимом движке обязательный прокси закреплён независимо от их настроек. ", comment: "") : "") +
                        NSLocalizedString("page.432", tableName: "Pages", bundle: .main, value: "Данные расширений не удаляются. ", comment: "") +
                        (profile.privacyPolicy.disableSyncAndAutofill
                            ? NSLocalizedString("page.433", tableName: "Pages", bundle: .main, value: "Политика запрещает Sync, autofill и сохранение паролей.", comment: "")
                            : NSLocalizedString("page.434", tableName: "Pages", bundle: .main, value: "Политика не запрещает Sync, autofill и сохранение паролей.", comment: ""))
                ),
                EnvironmentDiagnosticField(
                    id: "protection.retention", title: NSLocalizedString("page.435", tableName: "Pages", bundle: .main, value: "Данные сайтов", comment: ""),
                    value: profile.privacyPolicy.retention == .ephemeral ? NSLocalizedString("page.436", tableName: "Pages", bundle: .main, value: "Очистка после закрытия сеанса", comment: "") : NSLocalizedString("page.437", tableName: "Pages", bundle: .main, value: "Постоянное хранение", comment: ""),
                    state: .configured,
                    detail: NSLocalizedString("page.438", tableName: "Pages", bundle: .main, value: "Для выбранного открытого профиля: расширение «Защита сайтов» → «Очистить данные этого профиля…» или ⌘⇧⌫. Очистка не меняет настройки личности; скачанные файлы сохраняются.", comment: "")
                )
            ]) + [
                EnvironmentDiagnosticField(
                    id: "protection.start-page",
                    title: NSLocalizedString("page.439", tableName: "Pages", bundle: .main, value: "При запуске", comment: ""),
                    value: restoresSession ? NSLocalizedString("page.440", tableName: "Pages", bundle: .main, value: "Сохранённые вкладки", comment: "") :
                        (localStart ? NSLocalizedString("page.441", tableName: "Pages", bundle: .main, value: "Локальная пустая страница", comment: "") : NSLocalizedString("page.442", tableName: "Pages", bundle: .main, value: "Выбранная веб-страница", comment: "")),
                    state: .configured,
                    detail: restoresSession
                        ? NSLocalizedString("page.443", tableName: "Pages", bundle: .main, value: "Восстановленные сайты могут обращаться в сеть. Стартовый адрес используется при первом запуске.", comment: "")
                        : (localStart
                            ? NSLocalizedString("page.444", tableName: "Pages", bundle: .main, value: "Пустая страница не отправляет запросы внешнему чекеру. Это не проверка всего фонового трафика браузера.", comment: "")
                            : NSLocalizedString("page.445", tableName: "Pages", bundle: .main, value: "Открытие выбранного сайта передаёт ему обычные данные соединения. Полный адрес здесь не раскрывается.", comment: ""))
                ),
                EnvironmentDiagnosticField(
                    id: "protection.malware",
                    title: NSLocalizedString("page.446", tableName: "Pages", bundle: .main, value: "Проверка вредоносных сайтов NeAntik", comment: ""),
                    value: profile.privacyPolicy.siteProtection ? NSLocalizedString("page.447", tableName: "Pages", bundle: .main, value: "CERT Polska и HaGeZi настроены", comment: "") : NSLocalizedString("page.448", tableName: "Pages", bundle: .main, value: "Выключена в настройках", comment: ""),
                    state: .configured,
                    severity: .attention,
                    detail: NSLocalizedString("page.449", tableName: "Pages", bundle: .main, value: "Дополнительные списки известных доменов; не полная защита от phishing/malware и не проверка файлов. Safe Browsing выключен. Свежесть CERT и дата снимка HaGeZi показаны в расширении. Проверка отпечатка для новых режимов пока недоступна.", comment: "")
                ),
                EnvironmentDiagnosticField(
                    id: "protection.linkability",
                    title: NSLocalizedString("page.450", tableName: "Pages", bundle: .main, value: "Связывание профилей", comment: ""),
                    value: NSLocalizedString("page.451", tableName: "Pages", bundle: .main, value: "Полная несопоставимость не подтверждена", comment: ""),
                    state: .unverified,
                    detail: NSLocalizedString("page.452", tableName: "Pages", bundle: .main, value: "Общий внешний IP, одинаковые аккаунты, файлы и поведение могут связывать посещения даже при разных настройках среды.", comment: "")
                )
            ]
        )
    }

    private static func siteProtectionSection(
        profile: BrowserProfile
    ) -> EnvironmentDiagnosticSection {
        let isChromium = profile.engine == .chromium
        return EnvironmentDiagnosticSection(
            id: "site-protection",
            title: NSLocalizedString("page.453", tableName: "Pages", bundle: .main, value: "Защита сайтов", comment: ""),
            fields: [
                EnvironmentDiagnosticField(
                    id: "site-protection.phishing-malware",
                    title: NSLocalizedString("page.454", tableName: "Pages", bundle: .main, value: "Фишинг и вредоносные загрузки", comment: ""),
                    value: isChromium
                        ? NSLocalizedString("page.455", tableName: "Pages", bundle: .main, value: "Не включена", comment: "")
                        : NSLocalizedString("page.456", tableName: "Pages", bundle: .main, value: "Не проверено NeAntik", comment: ""),
                    state: isChromium ? .unavailable : .unverified,
                    severity: .attention,
                    detail: isChromium
                        ? NSLocalizedString("page.457", tableName: "Pages", bundle: .main, value: "Текущий Chromium runtime не проверяет адреса по списку угроз и не показывает предупреждения о таких сайтах. Не считай этот профиль защищённым от фишинга или вредоносных загрузок.", comment: "")
                        : NSLocalizedString("page.458", tableName: "Pages", bundle: .main, value: "NeAntik не проверяет защиту системного WebKit от таких сайтов. ", comment: "") +
                            NSLocalizedString("page.459", tableName: "Pages", bundle: .main, value: "Возможности macOS не квалифицированы; не считай их подтверждёнными NeAntik.", comment: "")
                )
            ]
        )
    }

    private static func routeSection(
        policy: BrowserLaunchPolicy,
        proxyHealth: ProxyHealthState?,
        now: Date
    ) -> EnvironmentDiagnosticSection {
        let routeValue: String
        switch policy.route {
        case .direct:
            routeValue = NSLocalizedString("page.460", tableName: "Pages", bundle: .main, value: "Прямое подключение", comment: "")
        case let .proxied(kind):
            routeValue = String(format: NSLocalizedString("page.461", tableName: "Pages", bundle: .main, value: "Через %@-прокси", comment: ""), String(describing: kind.title))
        }
        var fields = [
            EnvironmentDiagnosticField(
                id: "route.mode",
                title: NSLocalizedString("page.462", tableName: "Pages", bundle: .main, value: "Режим", comment: ""),
                value: routeValue,
                state: .configured,
                severity: .success
            )
        ]
        if let attempt = proxyHealth?.latestAttempt {
            let routeContextIsComplete = proxyHealth.map {
                ProxyCheckSummary.status(for: $0, now: now) == .currentSuccess
            } == true
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
                    title: NSLocalizedString("page.463", tableName: "Pages", bundle: .main, value: "Последняя проверка", comment: ""),
                    value: attempt.outcome == .succeeded
                        ? (routeContextIsComplete
                            ? responseSummary(milliseconds: attempt.responseTimeMilliseconds)
                            : NSLocalizedString("page.464", tableName: "Pages", bundle: .main, value: "Результат устарел или его время не подтверждено", comment: ""))
                        : attempt.outcome.userSummary,
                    state: .observed,
                    severity: probeSeverity,
                    resolution: probeResolution,
                    detail:
                        NSLocalizedString("page.465", tableName: "Pages", bundle: .main, value: "Результат относится только к моменту проверки.", comment: ""),
                    observedAt: attempt.checkedAt
                )
            )
        } else if case .proxied = policy.route {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "route.last-probe",
                    title: NSLocalizedString("page.463", tableName: "Pages", bundle: .main, value: "Последняя проверка", comment: ""),
                    value: NSLocalizedString("page.466", tableName: "Pages", bundle: .main, value: "Проверится автоматически перед запуском", comment: ""),
                    state: .unverified,
                    severity: .neutral,
                    resolution: DiagnosticResolution(
                        key: .proxyContext,
                        mode: .fixOnNextLaunch,
                        action: .testProxy
                    ),
                    detail:
                        NSLocalizedString("page.467", tableName: "Pages", bundle: .main, value: "Если проверка не пройдёт, NeAntik остановит запуск.", comment: "")
                )
            )
        }
        fields.append(
            EnvironmentDiagnosticField(
                id: "route.chromium-http",
                title: NSLocalizedString("page.468", tableName: "Pages", bundle: .main, value: "HTTP-маршрут Chromium", comment: ""),
                value: NSLocalizedString("page.469", tableName: "Pages", bundle: .main, value: "Не измерялся", comment: ""),
                state: .unverified,
                severity: .neutral,
                detail:
                    NSLocalizedString("page.470", tableName: "Pages", bundle: .main, value: "Проверка прокси выполняется curl и не ", comment: "") +
                    NSLocalizedString("page.471", tableName: "Pages", bundle: .main, value: "подтверждает маршрут Chromium.", comment: "")
            )
        )
        return EnvironmentDiagnosticSection(
            id: "route",
            title: NSLocalizedString("page.472", tableName: "Pages", bundle: .main, value: "Маршрут и прокси", comment: ""),
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
                    title: NSLocalizedString("page.473", tableName: "Pages", bundle: .main, value: "Движок", comment: ""),
                    value: policy.fingerprintIdentityConfigured
                        ? NSLocalizedString("page.474", tableName: "Pages", bundle: .main, value: "Chromium с разделением отпечатков", comment: "") +
                            versionSuffix
                        : NSLocalizedString("page.475", tableName: "Pages", bundle: .main, value: "Обычный Chromium", comment: "") +
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
                signatureValue = NSLocalizedString("page.476", tableName: "Pages", bundle: .main, value: "Подпись подтверждена локально", comment: "")
                signatureState = .observed
                signatureSeverity = .success
            case .some(false):
                signatureValue = NSLocalizedString("page.477", tableName: "Pages", bundle: .main, value: "Подпись не подтверждена", comment: "")
                signatureState = .observed
                signatureSeverity = .failure
            case .none:
                signatureValue = NSLocalizedString("page.478", tableName: "Pages", bundle: .main, value: "Подпись не удалось проверить", comment: "")
                signatureState = .unverified
                signatureSeverity = .attention
            }
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.runtime-signature",
                    title: NSLocalizedString("page.479", tableName: "Pages", bundle: .main, value: "Подпись движка", comment: ""),
                    value: signatureValue,
                    state: signatureState,
                    severity: signatureSeverity
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.runtime",
                    title: NSLocalizedString("page.473", tableName: "Pages", bundle: .main, value: "Движок", comment: ""),
                    value: NSLocalizedString("page.480", tableName: "Pages", bundle: .main, value: "Браузерный движок не найден", comment: ""),
                    state: .unavailable,
                    severity: .blocking
                )
            )
        }

        fields.append(
            EnvironmentDiagnosticField(
                id: "fingerprint.device-tuple",
                title: NSLocalizedString("page.481", tableName: "Pages", bundle: .main, value: "Профиль устройства", comment: ""),
                value: deviceTupleTitle(profile.identity.deviceTupleID),
                state: .derived,
                severity: .neutral,
                detail: policy.fingerprintIdentityConfigured
                    ? NSLocalizedString("page.482", tableName: "Pages", bundle: .main, value: "Рассчитан из стабильной конфигурации ", comment: "") +
                        NSLocalizedString("page.483", tableName: "Pages", bundle: .main, value: "профиля.", comment: "")
                    : NSLocalizedString("page.484", tableName: "Pages", bundle: .main, value: "Будет применён только совместимым движком.", comment: "")
            )
        )

        if policy.fingerprintIdentityConfigured {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.configuration",
                    title: NSLocalizedString("page.485", tableName: "Pages", bundle: .main, value: "Стабильная конфигурация", comment: ""),
                    value: NSLocalizedString("page.486", tableName: "Pages", bundle: .main, value: "Назначена этому профилю", comment: ""),
                    state: .configured,
                    severity: .success
                )
            )
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.webgpu",
                    title: "WebGPU",
                    value: policy.webGPUDisabled
                        ? NSLocalizedString("page.487", tableName: "Pages", bundle: .main, value: "Отключён до поддержки согласованного ", comment: "") +
                            NSLocalizedString("page.488", tableName: "Pages", bundle: .main, value: "профиля устройства", comment: "")
                        : NSLocalizedString("page.489", tableName: "Pages", bundle: .main, value: "NeAntik не меняет настройку", comment: ""),
                    state: .configured,
                    severity: .success
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.configuration",
                    title: NSLocalizedString("page.490", tableName: "Pages", bundle: .main, value: "Разделение отпечатков", comment: ""),
                    value: NSLocalizedString("page.491", tableName: "Pages", bundle: .main, value: "Доступна только изоляция данных", comment: ""),
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
                    title: NSLocalizedString("page.492", tableName: "Pages", bundle: .main, value: "Проверка поверхностей", comment: ""),
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
                        NSLocalizedString("page.493", tableName: "Pages", bundle: .main, value: "Локальное сравнение A → B → A без ", comment: "") +
                        NSLocalizedString("page.494", tableName: "Pages", bundle: .main, value: "внешнего сервиса проверки.", comment: ""),
                    observedAt: observation.observedAt
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "fingerprint.observation",
                    title: NSLocalizedString("page.492", tableName: "Pages", bundle: .main, value: "Проверка поверхностей", comment: ""),
                    value: policy.fingerprintIdentityConfigured
                        ? NSLocalizedString("page.495", tableName: "Pages", bundle: .main, value: "Дополнительная проверка не запускалась", comment: "")
                        : NSLocalizedString("page.496", tableName: "Pages", bundle: .main, value: "Текущий движок не поддерживает проверку", comment: ""),
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
                        ? NSLocalizedString("page.497", tableName: "Pages", bundle: .main, value: "Необязательно для обычного запуска. ", comment: "") +
                            NSLocalizedString("page.498", tableName: "Pages", bundle: .main, value: "Доступно в дополнительных проверках.", comment: "")
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
        case .disabledByProfile:
            NSLocalizedString("page.499", tableName: "Pages", bundle: .main, value: "WebRTC выключен политикой профиля", comment: "")
        case .publicInterfaceOnly:
            NSLocalizedString("page.500", tableName: "Pages", bundle: .main, value: "Только публичный интерфейс", comment: "")
        case .disableNonProxiedUDP:
            NSLocalizedString("page.501", tableName: "Pages", bundle: .main, value: "Ограничен прямой UDP для WebRTC", comment: "")
        }
        var fields = [
            EnvironmentDiagnosticField(
                id: "webrtc.policy",
                title: NSLocalizedString("page.502", tableName: "Pages", bundle: .main, value: "Политика", comment: ""),
                value: policyValue,
                state: .configured,
                severity: .success
            )
        ]
        if let observation {
            let value = switch observation.webRTCLoopback {
            case .passed:
                NSLocalizedString("page.503", tableName: "Pages", bundle: .main, value: "Локальный контроль пройден", comment: "")
            case .failed:
                NSLocalizedString("page.504", tableName: "Pages", bundle: .main, value: "Локальный контроль выявил проблему", comment: "")
            case .incomplete:
                NSLocalizedString("page.505", tableName: "Pages", bundle: .main, value: "Локальный контроль не завершён", comment: "")
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
                    title: NSLocalizedString("page.506", tableName: "Pages", bundle: .main, value: "Локальный контроль", comment: ""),
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
                        NSLocalizedString("page.507", tableName: "Pages", bundle: .main, value: "Loopback STUN; адреса и строки ", comment: "") +
                        NSLocalizedString("page.508", tableName: "Pages", bundle: .main, value: "кандидатов не сохраняются.", comment: ""),
                    observedAt: observation.observedAt
                )
            )
        } else {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "webrtc.loopback",
                    title: NSLocalizedString("page.506", tableName: "Pages", bundle: .main, value: "Локальный контроль", comment: ""),
                    value: NSLocalizedString("page.495", tableName: "Pages", bundle: .main, value: "Дополнительная проверка не запускалась", comment: ""),
                    state: .unverified,
                    severity: .neutral,
                    resolution: DiagnosticResolution(
                        key: .fingerprintAudit,
                        mode: .informational,
                        action: nil
                    ),
                    detail: NSLocalizedString("page.509", tableName: "Pages", bundle: .main, value: "Необязательно для обычного запуска.", comment: "")
                )
            )
        }
        fields.append(
            EnvironmentDiagnosticField(
                id: "webrtc.public-route",
                title: NSLocalizedString("page.510", tableName: "Pages", bundle: .main, value: "Публичный WebRTC-маршрут", comment: ""),
                value: NSLocalizedString("page.469", tableName: "Pages", bundle: .main, value: "Не измерялся", comment: ""),
                state: .unverified,
                severity: .neutral,
                detail:
                    NSLocalizedString("page.511", tableName: "Pages", bundle: .main, value: "Локальный контроль не доказывает ", comment: "") +
                    NSLocalizedString("page.512", tableName: "Pages", bundle: .main, value: "отсутствие всех сетевых утечек.", comment: "")
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
            NSLocalizedString("page.513", tableName: "Pages", bundle: .main, value: "Отключён настройками запуска", comment: "")
        case .notDisabledByNeAntik:
            NSLocalizedString("page.514", tableName: "Pages", bundle: .main, value: "NeAntik не отключает QUIC", comment: "")
        }
        let dnsValue: String
        let dnsDetail: String
        switch policy.dns {
        case .ordinaryChromium:
            dnsValue = NSLocalizedString("page.515", tableName: "Pages", bundle: .main, value: "Обычная политика Chromium и macOS", comment: "")
            dnsDetail = NSLocalizedString("page.516", tableName: "Pages", bundle: .main, value: "Имена сайтов разрешаются по обычной политике Chromium и macOS.", comment: "")
        case .proxyResolverFailClosed:
            dnsValue = NSLocalizedString("page.517", tableName: "Pages", bundle: .main, value: "Прямое разрешение сайтов ограничено", comment: "")
            if policy.proxyHostRequiresDNSResolution == false {
                dnsDetail = NSLocalizedString("page.518", tableName: "Pages", bundle: .main, value: "Chromium ограничивает прямое DNS-разрешение сайтов. Адрес proxy задан как IP, DNS для адреса proxy не требуется; фактический DNS-маршрут не измерялся.", comment: "")
            } else {
                dnsDetail = NSLocalizedString("page.519", tableName: "Pages", bundle: .main, value: "Chromium ограничивает прямое DNS-разрешение сайтов. Для подключения к proxy с именем хоста может потребоваться системное DNS-разрешение; фактический DNS-маршрут не измерялся.", comment: "")
            }
        }
        return EnvironmentDiagnosticSection(
            id: "transport",
            title: NSLocalizedString("page.520", tableName: "Pages", bundle: .main, value: "QUIC и DNS", comment: ""),
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
                        : .success,
                    detail: dnsDetail
                ),
                EnvironmentDiagnosticField(
                    id: "transport.quic-observed",
                    title: NSLocalizedString("page.521", tableName: "Pages", bundle: .main, value: "Фактический QUIC / HTTP/3", comment: ""),
                    value: NSLocalizedString("page.469", tableName: "Pages", bundle: .main, value: "Не измерялся", comment: ""),
                    state: .unverified,
                    severity: .neutral
                ),
                EnvironmentDiagnosticField(
                    id: "transport.dns-observed",
                    title: NSLocalizedString("page.522", tableName: "Pages", bundle: .main, value: "Фактический DNS-маршрут", comment: ""),
                    value: NSLocalizedString("page.469", tableName: "Pages", bundle: .main, value: "Не измерялся", comment: ""),
                    state: .unverified,
                    severity: .neutral
                )
            ]
        )
    }

    private static func geolocationSection(
        profile: BrowserProfile,
        policy: BrowserLaunchPolicy,
        proxyHealth: ProxyHealthState?,
        now: Date
    ) -> EnvironmentDiagnosticSection {
        guard case .proxied = policy.route else {
            return EnvironmentDiagnosticSection(
                id: "geolocation",
                title: NSLocalizedString("page.523", tableName: "Pages", bundle: .main, value: "Геолокация", comment: ""),
                fields: [
                    EnvironmentDiagnosticField(
                        id: "geolocation.proxy",
                        title: NSLocalizedString("page.524", tableName: "Pages", bundle: .main, value: "Контекст прокси", comment: ""),
                        value: NSLocalizedString("page.525", tableName: "Pages", bundle: .main, value: "Для прямого профиля не применяется", comment: ""),
                        state: .unavailable,
                        severity: .neutral
                    ),
                    browserGeolocationField
                ]
            )
        }

        var fields: [EnvironmentDiagnosticField] = []
        if let success = proxyHealth?.lastSuccess {
            let routeContextIsComplete = proxyHealth.map {
                ProxyCheckSummary.status(for: $0, now: now) == .currentSuccess
            } == true
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
                    title: NSLocalizedString("page.526", tableName: "Pages", bundle: .main, value: "Источник", comment: ""),
                    value: String(format: NSLocalizedString("page.527", tableName: "Pages", bundle: .main, value: "%@ через проверку прокси", comment: ""), String(describing: success.source.rawValue)),
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
                    title: NSLocalizedString("page.528", tableName: "Pages", bundle: .main, value: "Примерная локация", comment: ""),
                    value: safeLocationSummary(success),
                    state: .observed,
                    severity: routeContextIsComplete
                        ? .success
                        : .attention,
                    resolution: contextResolution,
                    detail:
                        (routeContextIsComplete ? NSLocalizedString("page.529", tableName: "Pages", bundle: .main, value: "Определена по выходному IP прокси. ", comment: "") : NSLocalizedString("page.530", tableName: "Pages", bundle: .main, value: "Локация из предыдущей проверки; сейчас не подтверждена. ", comment: "")) +
                        NSLocalizedString("page.531", tableName: "Pages", bundle: .main, value: "Точный IP здесь не хранится.", comment: ""),
                    observedAt: success.observedAt
                )
            )
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.context",
                    title: NSLocalizedString("page.532", tableName: "Pages", bundle: .main, value: "Часовой пояс и язык", comment: ""),
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
                    title: NSLocalizedString("page.524", tableName: "Pages", bundle: .main, value: "Контекст прокси", comment: ""),
                    value: NSLocalizedString("page.533", tableName: "Pages", bundle: .main, value: "Обновится автоматически перед запуском", comment: ""),
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
                    title: NSLocalizedString("page.439", tableName: "Pages", bundle: .main, value: "При запуске", comment: ""),
                    value: NSLocalizedString("page.534", tableName: "Pages", bundle: .main, value: "Движок не принимает контекст профиля", comment: ""),
                    state: .unavailable,
                    severity: .attention
                )
            )
        } else if policy.proxyContextIsFresh, appliedValues.count == 2 {
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.launch",
                    title: NSLocalizedString("page.439", tableName: "Pages", bundle: .main, value: "При запуске", comment: ""),
                    value: appliedValues.joined(separator: " · "),
                    state: .derived,
                    severity: .success,
                    detail:
                        NSLocalizedString("page.535", tableName: "Pages", bundle: .main, value: "Будут применены только к этому запуску профиля.", comment: "")
                )
            )
        } else {
            let hasStoredContext =
                profile.identity.timezoneIdentifier != nil ||
                profile.identity.localeIdentifier != nil
            fields.append(
                EnvironmentDiagnosticField(
                    id: "geolocation.launch",
                    title: NSLocalizedString("page.439", tableName: "Pages", bundle: .main, value: "При запуске", comment: ""),
                    value: hasStoredContext
                        ? NSLocalizedString("page.536", tableName: "Pages", bundle: .main, value: "Устаревший контекст обновится перед запуском", comment: "")
                        : NSLocalizedString("page.537", tableName: "Pages", bundle: .main, value: "Контекст определится перед запуском", comment: ""),
                    state: .unverified,
                    severity: .neutral,
                    resolution: DiagnosticResolution(
                        key: .proxyContext,
                        mode: .fixOnNextLaunch,
                        action: .testProxy
                    ),
                    detail:
                        NSLocalizedString("page.538", tableName: "Pages", bundle: .main, value: "Если прокси или контекст не подтвердятся, ", comment: "") +
                        NSLocalizedString("page.539", tableName: "Pages", bundle: .main, value: "NeAntik остановит запуск.", comment: "")
                )
            )
        }
        fields.append(browserGeolocationField)
        return EnvironmentDiagnosticSection(
            id: "geolocation",
            title: NSLocalizedString("page.523", tableName: "Pages", bundle: .main, value: "Геолокация", comment: ""),
            fields: fields
        )
    }

    private static var browserGeolocationField: EnvironmentDiagnosticField {
        EnvironmentDiagnosticField(
            id: "geolocation.browser-api",
            title: NSLocalizedString("page.540", tableName: "Pages", bundle: .main, value: "Geolocation API браузера", comment: ""),
            value: NSLocalizedString("page.541", tableName: "Pages", bundle: .main, value: "Не измеряется", comment: ""),
            state: .unavailable,
            severity: .neutral,
            detail:
                NSLocalizedString("page.542", tableName: "Pages", bundle: .main, value: "IP-геолокация не является GPS или ", comment: "") +
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
            return NSLocalizedString("page.543", tableName: "Pages", bundle: .main, value: "Успешно", comment: "")
        }
        return String(format: NSLocalizedString("page.544", tableName: "Pages", bundle: .main, value: "Успешно · отклик %@ мс", comment: ""), String(describing: milliseconds))
    }

    private static func safeLocationSummary(
        _ success: ProxyHealthSuccess
    ) -> String {
        let values = [
            safeText(success.city),
            safeText(success.countryName),
            safeText(success.countryCode)
        ].compactMap { $0 }
        return values.isEmpty ? NSLocalizedString("page.545", tableName: "Pages", bundle: .main, value: "IP подтверждён", comment: "") : values.joined(separator: ", ")
    }

    private static func contextSummary(
        _ success: ProxyHealthSuccess
    ) -> String {
        let values = [
            safeText(success.timezoneIdentifier),
            safeText(success.localeIdentifier)
        ].compactMap { $0 }
        return values.isEmpty ? NSLocalizedString("page.546", tableName: "Pages", bundle: .main, value: "Не определены", comment: "") : values.joined(separator: " · ")
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
        default: NSLocalizedString("page.547", tableName: "Pages", bundle: .main, value: "Профиль устройства из каталога NeAntik", comment: "")
        }
    }
}
