import Combine
import Darwin
import Foundation
import Network

enum FingerprintAuditVerdict: String, Codable, Sendable {
    case verified
    case partial
    case unchanged
    case unstable

    var title: String {
        switch self {
        case .verified:
            "Отличается и стабильно"
        case .partial:
            "Частично отличается"
        case .unchanged:
            "Критичных отличий нет"
        case .unstable:
            "Идентификатор нестабилен"
        }
    }

    var explanation: String {
        switch self {
        case .verified:
            "Минимум две критичные поверхности браузера отличаются между профилями и остаются стабильными при повторном запуске профиля A."
        case .partial:
            "Одна критичная поверхность отличается и остаётся стабильной. Движок даёт ограниченное разделение отпечатков."
        case .unchanged:
            "Критичные поверхности не доказали различие между профилями. Недоступные измерения не считаются разделением."
        case .unstable:
            "Минимум одно критичное значение изменилось при повторном запуске того же профиля."
        }
    }
}

enum FingerprintAuditExecutionMode: String, Codable, Sendable {
    case browser
    case headlessSingleProcessDiagnostic = "headless-single-process-diagnostic"

    var isReleaseEvidence: Bool {
        self == .browser
    }

    var additionalLaunchArguments: [String] {
        switch self {
        case .browser:
            []
        case .headlessSingleProcessDiagnostic:
            [
                "--single-process",
                "--no-sandbox"
            ]
        }
    }

    var diagnosticTitle: String {
        switch self {
        case .browser:
            "Обычный режим браузера"
        case .headlessSingleProcessDiagnostic:
            "Диагностический режим"
        }
    }
}

struct FingerprintCapture: Codable, Equatable, Sendable {
    let profileID: UUID
    let profileName: String
    let identityCode: String
    let capturedAt: Date
    let values: [String: String]
}

struct FingerprintAuditReport: Codable, Equatable, Sendable {
    static let currentAuditSchemaVersion = 6
    static let criticalKeys = [
        "canvas",
        "webgl_pixels",
        "audio",
        "client_rects"
    ]
    static let publicAlphaStableContextKeys = [
        "webgl_vendor",
        "webgl_renderer",
        "webgl_extensions",
        "webgpu_policy",
        "user_agent",
        "platform",
        "client_hints",
        "screen",
        "hardware_concurrency",
        "device_memory",
        "touch_points",
        "fonts",
        "languages",
        "timezone"
    ]
    static let productionExtendedContextKeys = [
        "audio_repeat",
        "canvas_repeat",
        "client_rects_repeat",
        "webgl_pixels_repeat",
        "webgl_shader_precision",
        "css_screen_match",
        "intl_locale",
        "worker_canvas",
        "worker_webgl_pixels",
        "worker_webgl_vendor",
        "worker_webgl_renderer",
        "worker_webgl_extensions",
        "worker_webgl_shader_precision",
        "worker_user_agent",
        "worker_platform",
        "worker_languages",
        "worker_timezone",
        "worker_intl_locale",
        "worker_hardware_concurrency",
        "worker_device_memory",
        "worker_client_hints",
        "network_route",
        "webrtc_probe",
        "webrtc_complete",
        "webrtc_stun_requests",
        "webrtc_candidate_summary"
    ]

    let id: UUID
    let createdAt: Date
    let auditSchemaVersion: Int?
    let identityCatalogVersion: Int?
    let managerVersion: String?
    let managerBuild: String?
    let runtimeName: String
    let runtimeVersion: String?
    let runtimeFlavor: BrowserRuntimeFlavor
    let runtimeCodeSignatureValid: Bool?
    let runtimeExecutableSHA256: String?
    let runtimeFrameworkSHA256: String?
    let executionMode: FingerprintAuditExecutionMode?
    let webrtcDirectControl: FingerprintCapture?
    let firstInitial: FingerprintCapture
    let second: FingerprintCapture
    let firstRepeat: FingerprintCapture

    init(
        id: UUID,
        createdAt: Date,
        auditSchemaVersion: Int = Self.currentAuditSchemaVersion,
        identityCatalogVersion: Int =
            BrowserIdentityCatalog.currentVersion,
        managerVersion: String? = nil,
        managerBuild: String? = nil,
        runtimeName: String,
        runtimeVersion: String?,
        runtimeFlavor: BrowserRuntimeFlavor,
        runtimeCodeSignatureValid: Bool? = nil,
        runtimeExecutableSHA256: String? = nil,
        runtimeFrameworkSHA256: String? = nil,
        executionMode: FingerprintAuditExecutionMode = .browser,
        webrtcDirectControl: FingerprintCapture? = nil,
        firstInitial: FingerprintCapture,
        second: FingerprintCapture,
        firstRepeat: FingerprintCapture
    ) {
        self.id = id
        self.createdAt = createdAt
        self.auditSchemaVersion = auditSchemaVersion
        self.identityCatalogVersion = identityCatalogVersion
        self.managerVersion = managerVersion
        self.managerBuild = managerBuild
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
        self.runtimeFlavor = runtimeFlavor
        self.runtimeCodeSignatureValid = runtimeCodeSignatureValid
        self.runtimeExecutableSHA256 = runtimeExecutableSHA256
        self.runtimeFrameworkSHA256 = runtimeFrameworkSHA256
        self.executionMode = executionMode
        self.webrtcDirectControl = webrtcDirectControl
        self.firstInitial = firstInitial
        self.second = second
        self.firstRepeat = firstRepeat
    }

    var effectiveExecutionMode: FingerprintAuditExecutionMode {
        executionMode ?? .browser
    }

    var effectiveAuditSchemaVersion: Int {
        auditSchemaVersion ?? 1
    }

    var safeManagerVersionSummary: String {
        let version = Self.safeMetadataValue(managerVersion)
        let build = Self.safeMetadataValue(managerBuild)
        switch (version, build) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return "сборка \(build)"
        case (nil, nil):
            return "не записана"
        }
    }

    var safeRuntimeVersionSummary: String {
        let version = Self.safeMetadataValue(runtimeVersion) ?? "не записана"
        return "\(runtimeFlavor.title) · \(version)"
    }

    var safeRuntimeSignatureSummary: String {
        runtimeCodeSignatureValid == true
            ? "Подпись подтверждена"
            : "Подпись не подтверждена"
    }

    var safeRuntimeExecutableHashSummary: String {
        Self.safeSHA256(runtimeExecutableSHA256)
    }

    var safeRuntimeFrameworkHashSummary: String {
        Self.safeSHA256(runtimeFrameworkSHA256)
    }

    /// Allowlisted release provenance only. Never derive this text by encoding
    /// the report: captures contain profile identity and browser measurements.
    var safeDiagnosticSummary: String {
        [
            "NeAntik — безопасная сводка fingerprint-проверки",
            "Менеджер: \(safeManagerVersionSummary)",
            "Схема проверки: \(effectiveAuditSchemaVersion)",
            "Каталог устройств: \(identityCatalogVersion.map(String.init) ?? "не записан")",
            "Движок: \(safeRuntimeVersionSummary)",
            "Режим: \(effectiveExecutionMode.diagnosticTitle)",
            "Подпись движка: \(safeRuntimeSignatureSummary)",
            "SHA-256 executable: \(safeRuntimeExecutableHashSummary)",
            "SHA-256 framework: \(safeRuntimeFrameworkHashSummary)",
            "Публичное тестирование: \(isPublicAlphaReleaseQualified ? "PASS" : "FAIL")",
            "Строгая проверка: \(isProductionReleaseQualified ? "PASS" : "FAIL")"
        ].joined(separator: "\n")
    }

    var unstableKeys: [String] {
        Self.changedKeys(firstInitial.values, firstRepeat.values)
    }

    var changedKeys: [String] {
        Self.changedKeys(firstInitial.values, second.values)
    }

    var changedCriticalKeys: [String] {
        comparableCriticalKeys.filter {
            firstInitial.values[$0] != second.values[$0]
        }
    }

    var unavailableCriticalKeys: [String] {
        Self.criticalKeys.filter { key in
            !Self.isAvailable(firstInitial.values[key]) ||
                !Self.isAvailable(second.values[key]) ||
                !Self.isAvailable(firstRepeat.values[key])
        }
    }

    var unstableCriticalKeys: [String] {
        Self.criticalKeys.filter {
            firstInitial.values[$0] != firstRepeat.values[$0]
        }
    }

    var verdict: FingerprintAuditVerdict {
        if !unstableCriticalKeys.isEmpty {
            return .unstable
        }
        if changedCriticalKeys.count >= 2 {
            return .verified
        }
        if changedCriticalKeys.count == 1 {
            return .partial
        }
        return .unchanged
    }

    var productionUnavailableKeys: [String] {
        Self.productionRequiredKeys.filter { key in
            !Self.isAvailable(firstInitial.values[key]) ||
                !Self.isAvailable(second.values[key]) ||
                !Self.isAvailable(firstRepeat.values[key])
        }
    }

    var productionUnstableKeys: [String] {
        Self.productionRequiredKeys.filter {
            firstInitial.values[$0] != firstRepeat.values[$0]
        }
    }

    var productionReleaseIssues: [String] {
        var issues = publicAlphaReleaseIssues
        if effectiveAuditSchemaVersion != Self.currentAuditSchemaVersion {
            issues.append(
                "The report does not use the current strict fingerprint audit schema."
            )
        }
        if identityCatalogVersion !=
            BrowserIdentityCatalog.currentVersion
        {
            issues.append(
                "The report does not use the current immutable identity catalog."
            )
        }
        if !productionExtendedUnavailableKeys.isEmpty {
            issues.append(
                "Required browser surfaces are unavailable: " +
                    productionExtendedUnavailableKeys.joined(separator: ", ") +
                    "."
            )
        }
        if !productionExtendedUnstableKeys.isEmpty {
            issues.append(
                "Required browser surfaces are unstable: " +
                    productionExtendedUnstableKeys.joined(separator: ", ") +
                    "."
            )
        }
        issues.append(contentsOf: crossRealmConsistencyIssues)
        issues.append(contentsOf: deviceTupleConsistencyIssues)
        if let webrtcDirectControl {
            issues.append(
                contentsOf: Self.networkPrivacyIssues(
                    for: webrtcDirectControl,
                    label: "WebRTC direct control"
                )
            )
        } else {
            issues.append(
                "The report does not contain a WebRTC direct positive control."
            )
        }
        issues.append(contentsOf: networkPrivacyIssues)
        return issues
    }

    var publicAlphaReleaseIssues: [String] {
        var issues: [String] = []
        if executionMode != .browser {
            issues.append(
                executionMode == nil
                    ? "The report does not explicitly record browser mode."
                    : "The report was captured in diagnostic mode."
            )
        }
        if !runtimeFlavor.capabilities.contains(.fingerprintIdentity) {
            issues.append(
                "The report does not identify a fingerprint-compatible runtime."
            )
        }
        if runtimeVersion?.isEmpty != false {
            issues.append("The report does not identify the runtime version.")
        }
        if runtimeCodeSignatureValid != true {
            issues.append(
                "The report does not prove a valid runtime code signature."
            )
        }
        if !Self.isSHA256(runtimeExecutableSHA256) {
            issues.append(
                "The report does not bind the runtime executable SHA-256."
            )
        }
        if !Self.isSHA256(runtimeFrameworkSHA256) {
            issues.append(
                "The report does not bind the runtime framework SHA-256."
            )
        }
        if firstInitial.profileID == second.profileID ||
            firstInitial.profileID != firstRepeat.profileID {
            issues.append(
                "The report does not contain a valid A → B → A profile sequence."
            )
        }
        if firstInitial.identityCode == second.identityCode ||
            firstInitial.identityCode != firstRepeat.identityCode {
            issues.append(
                "The report does not contain distinct, stable profile identities."
            )
        }
        if verdict != .verified {
            issues.append("The critical-surface verdict is not verified.")
        }
        if !publicAlphaUnavailableKeys.isEmpty {
            issues.append(
                "Required browser surfaces are unavailable: " +
                    publicAlphaUnavailableKeys.joined(separator: ", ") + "."
            )
        }
        if !publicAlphaUnstableKeys.isEmpty {
            issues.append(
                "Required browser surfaces are unstable: " +
                    publicAlphaUnstableKeys.joined(separator: ", ") + "."
            )
        }
        if !changedCriticalKeys.contains("webgl_pixels") {
            issues.append("WebGL pixels did not differ between profiles.")
        }
        return issues
    }

    var isProductionReleaseQualified: Bool {
        productionReleaseIssues.isEmpty
    }

    var isPublicAlphaReleaseQualified: Bool {
        publicAlphaReleaseIssues.isEmpty
    }

    var deviceTupleConsistencyIssues: [String] {
        guard let runtimeVersion, !runtimeVersion.isEmpty else {
            return []
        }
        let captures = [
            ("profile A, first capture", firstInitial),
            ("profile B", second),
            ("profile A, repeat capture", firstRepeat)
        ]
        guard captures.allSatisfy({ Self.canMapDeviceTuple($0.1) }) else {
            return []
        }
        return captures.flatMap { label, capture in
            Self.deviceTupleIssues(
                for: capture,
                label: label,
                runtimeVersion: runtimeVersion
            )
        }
    }

    var crossRealmConsistencyIssues: [String] {
        [
            ("profile A, first capture", firstInitial),
            ("profile B", second),
            ("profile A, repeat capture", firstRepeat)
        ].flatMap { label, capture in
            Self.crossRealmIssues(for: capture, label: label)
        }
    }

    var networkPrivacyIssues: [String] {
        [
            ("profile A, first capture", firstInitial),
            ("profile B", second),
            ("profile A, repeat capture", firstRepeat)
        ].flatMap { label, capture in
            Self.networkPrivacyIssues(for: capture, label: label)
        }
    }

    private var comparableCriticalKeys: [String] {
        Self.criticalKeys.filter { key in
            Self.isAvailable(firstInitial.values[key]) &&
                Self.isAvailable(second.values[key]) &&
                Self.isAvailable(firstRepeat.values[key])
        }
    }

    private static func isAvailable(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value != "unavailable"
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else {
            return false
        }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func safeSHA256(_ value: String?) -> String {
        guard isSHA256(value), let value else {
            return "не подтверждён"
        }
        return value
    }

    private static func safeMetadataValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let sanitized = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return nil
        }
        return String(sanitized.prefix(80))
    }

    private static func canMapDeviceTuple(_ capture: FingerprintCapture) -> Bool {
        capture.identityCode.hasPrefix("NA-") &&
            capture.identityCode.count == 11 &&
            UInt32(capture.identityCode.dropFirst(3), radix: 16) != nil
    }

    private static func deviceTupleIssues(
        for capture: FingerprintCapture,
        label: String,
        runtimeVersion: String
    ) -> [String] {
        guard capture.identityCode.hasPrefix("NA-"),
              capture.identityCode.count == 11,
              let seed = UInt32(
                capture.identityCode.dropFirst(3),
                radix: 16
              )
        else {
            return [
                "The \(label) identity code cannot be mapped to the reviewed Apple device catalog."
            ]
        }
        let tuple = appleDeviceTuples[
            Int(seed % UInt32(appleDeviceTuples.count))
        ]
        var issues: [String] = []
        func expect(_ key: String, _ expected: String) {
            if capture.values[key] != expected {
                issues.append(
                    "The \(label) \(key) value does not match device tuple \(tuple.id)."
                )
            }
        }

        expect("hardware_concurrency", String(tuple.hardwareConcurrency))
        expect("device_memory", String(tuple.webDeviceMemoryGB))
        expect("screen", tuple.screen)
        expect("platform", "MacIntel")
        expect("webgl_vendor", "Google Inc. (Apple)")
        expect("webgpu_policy", "disabled")
        if capture.values["webgl_renderer"]?.contains(
            "Apple \(tuple.gpuModel)"
        ) != true {
            issues.append(
                "The \(label) WebGL renderer does not match device tuple \(tuple.id)."
            )
        }
        guard let hintsText = capture.values["client_hints"],
              let hintsData = hintsText.data(using: .utf8),
              let hints = try? JSONSerialization.jsonObject(
                with: hintsData
              ) as? [String: Any]
        else {
            issues.append(
                "The \(label) Client Hints cannot be validated against device tuple \(tuple.id)."
            )
            return issues
        }
        for (key, expected) in [
            ("architecture", "arm"),
            ("bitness", "64"),
            ("platform", "macOS"),
            ("platformVersion", tuple.platformVersion),
            ("uaFullVersion", runtimeVersion)
        ] where hints[key] as? String != expected {
            issues.append(
                    "The \(label) Client Hints \(key) value does not match device tuple \(tuple.id)."
            )
        }
        if capture.values["user_agent"]?.contains(
            "Chrome/\(runtimeVersion)"
        ) != true {
            issues.append(
                "The \(label) User-Agent does not match the compiled runtime version."
            )
        }
        return issues
    }

    private struct AppleDeviceTuple {
        let id: String
        let gpuModel: String
        let hardwareConcurrency: Int
        let physicalMemoryGB: Int
        let webDeviceMemoryGB: Int
        let screen: String
        let deviceScaleFactor: Int
        let platformVersion: String
    }

    private static let appleDeviceTuples = [
        AppleDeviceTuple(
            id: "macbook-air-m1",
            gpuModel: "M1",
            hardwareConcurrency: 8,
            physicalMemoryGB: 8,
            webDeviceMemoryGB: 8,
            screen: "1280x800x1280x775x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.5.0"
        ),
        AppleDeviceTuple(
            id: "macbook-pro-m1-pro",
            gpuModel: "M1 Pro",
            hardwareConcurrency: 10,
            physicalMemoryGB: 16,
            webDeviceMemoryGB: 8,
            screen: "1512x982x1512x957x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.4.1"
        ),
        AppleDeviceTuple(
            id: "macbook-air-m2",
            gpuModel: "M2",
            hardwareConcurrency: 8,
            physicalMemoryGB: 8,
            webDeviceMemoryGB: 8,
            screen: "1280x832x1280x807x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.4.0"
        ),
        AppleDeviceTuple(
            id: "macbook-pro-m2-max",
            gpuModel: "M2 Max",
            hardwareConcurrency: 12,
            physicalMemoryGB: 32,
            webDeviceMemoryGB: 8,
            screen: "1728x1117x1728x1092x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.3.2"
        ),
        AppleDeviceTuple(
            id: "macbook-pro-m2-pro",
            gpuModel: "M2 Pro",
            hardwareConcurrency: 12,
            physicalMemoryGB: 16,
            webDeviceMemoryGB: 8,
            screen: "1512x982x1512x957x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.3.1"
        ),
        AppleDeviceTuple(
            id: "macbook-air-m3",
            gpuModel: "M3",
            hardwareConcurrency: 8,
            physicalMemoryGB: 8,
            webDeviceMemoryGB: 8,
            screen: "1280x832x1280x807x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.3.0"
        ),
        AppleDeviceTuple(
            id: "macbook-pro-m3-max",
            gpuModel: "M3 Max",
            hardwareConcurrency: 16,
            physicalMemoryGB: 36,
            webDeviceMemoryGB: 8,
            screen: "1728x1117x1728x1092x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.2.0"
        ),
        AppleDeviceTuple(
            id: "macbook-pro-m3-pro",
            gpuModel: "M3 Pro",
            hardwareConcurrency: 12,
            physicalMemoryGB: 18,
            webDeviceMemoryGB: 8,
            screen: "1512x982x1512x957x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.1.1"
        ),
        AppleDeviceTuple(
            id: "macbook-air-m4",
            gpuModel: "M4",
            hardwareConcurrency: 10,
            physicalMemoryGB: 16,
            webDeviceMemoryGB: 8,
            screen: "1280x832x1280x807x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.1.0"
        ),
        AppleDeviceTuple(
            id: "macbook-pro-m4-max",
            gpuModel: "M4 Max",
            hardwareConcurrency: 16,
            physicalMemoryGB: 36,
            webDeviceMemoryGB: 8,
            screen: "1728x1117x1728x1092x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.0.1"
        ),
        AppleDeviceTuple(
            id: "macbook-pro-m4-pro",
            gpuModel: "M4 Pro",
            hardwareConcurrency: 14,
            physicalMemoryGB: 24,
            webDeviceMemoryGB: 8,
            screen: "1512x982x1512x957x24x2",
            deviceScaleFactor: 2,
            platformVersion: "15.5.0"
        )
    ]

    private var publicAlphaUnavailableKeys: [String] {
        Self.publicAlphaRequiredKeys.filter { key in
            !Self.isAvailable(firstInitial.values[key]) ||
                !Self.isAvailable(second.values[key]) ||
                !Self.isAvailable(firstRepeat.values[key])
        }
    }

    private var publicAlphaUnstableKeys: [String] {
        Self.publicAlphaRequiredKeys.filter {
            firstInitial.values[$0] != firstRepeat.values[$0]
        }
    }

    private var productionExtendedUnavailableKeys: [String] {
        Self.productionExtendedContextKeys.filter { key in
            !Self.isAvailable(firstInitial.values[key]) ||
                !Self.isAvailable(second.values[key]) ||
                !Self.isAvailable(firstRepeat.values[key])
        }
    }

    private var productionExtendedUnstableKeys: [String] {
        Self.productionExtendedContextKeys.filter {
            firstInitial.values[$0] != firstRepeat.values[$0]
        }
    }

    private static var publicAlphaRequiredKeys: [String] {
        criticalKeys + publicAlphaStableContextKeys
    }

    private static var productionRequiredKeys: [String] {
        publicAlphaRequiredKeys + productionExtendedContextKeys
    }

    private static func crossRealmIssues(
        for capture: FingerprintCapture,
        label: String
    ) -> [String] {
        let values = capture.values
        var issues: [String] = []

        func expectEqual(_ first: String, _ second: String) {
            guard isAvailable(values[first]), isAvailable(values[second]) else {
                return
            }
            if values[first] != values[second] {
                issues.append(
                    "The \(label) \(first) value disagrees with \(second)."
                )
            }
        }

        for pair in [
            ("audio", "audio_repeat"),
            ("canvas", "canvas_repeat"),
            ("canvas", "worker_canvas"),
            ("client_rects", "client_rects_repeat"),
            ("webgl_pixels", "webgl_pixels_repeat"),
            ("webgl_pixels", "worker_webgl_pixels"),
            ("webgl_vendor", "worker_webgl_vendor"),
            ("webgl_renderer", "worker_webgl_renderer"),
            ("webgl_extensions", "worker_webgl_extensions"),
            ("webgl_shader_precision", "worker_webgl_shader_precision"),
            ("user_agent", "worker_user_agent"),
            ("platform", "worker_platform"),
            ("languages", "worker_languages"),
            ("timezone", "worker_timezone"),
            ("intl_locale", "worker_intl_locale"),
            ("hardware_concurrency", "worker_hardware_concurrency"),
            ("device_memory", "worker_device_memory")
        ] {
            expectEqual(pair.0, pair.1)
        }

        if isAvailable(values["css_screen_match"]),
           values["css_screen_match"] !=
            "width:1|height:1|resolution:1"
        {
            issues.append(
                "The \(label) CSS media queries disagree with the Screen API."
            )
        }

        if let topHints = parsedClientHints(values["client_hints"]),
           let workerHints = parsedClientHints(values["worker_client_hints"])
        {
            for key in [
                "architecture",
                "bitness",
                "mobile",
                "model",
                "platform",
                "platformVersion",
                "uaFullVersion",
                "wow64"
            ] where String(describing: topHints[key]) !=
                String(describing: workerHints[key])
            {
                issues.append(
                    "The \(label) Client Hints \(key) value disagrees between the page and worker."
                )
            }
        }

        return issues
    }

    private struct WebRTCCandidateSummary: Decodable {
        let total: Int
        let host: Int
        let srflx: Int
        let prflx: Int
        let relay: Int
        let unknown: Int

        var isValid: Bool {
            let counts = [total, host, srflx, prflx, relay, unknown]
            return counts.allSatisfy { (0...256).contains($0) } &&
                total == host + srflx + prflx + relay + unknown
        }
    }

    private static func networkPrivacyIssues(
        for capture: FingerprintCapture,
        label: String
    ) -> [String] {
        guard let route = capture.values["network_route"],
              route == "direct" || route == "proxied"
        else {
            return ["The \(label) network route is invalid."]
        }
        guard capture.values["webrtc_probe"] ==
            "loopback-stun-v1"
        else {
            return ["The \(label) WebRTC probe contract is invalid."]
        }
        guard capture.values["webrtc_complete"] == "true" else {
            return ["The \(label) WebRTC gathering did not complete."]
        }
        guard let requestText =
            capture.values["webrtc_stun_requests"],
              let requestCount = Int(requestText),
              (0...256).contains(requestCount),
              String(requestCount) == requestText
        else {
            return ["The \(label) STUN request count is invalid."]
        }
        guard let encoded = capture.values["webrtc_candidate_summary"],
              let data = encoded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == Set([
                "total", "host", "srflx", "prflx", "relay", "unknown"
              ]),
              let summary = try? JSONDecoder().decode(
                WebRTCCandidateSummary.self,
                from: data
              ),
              summary.isValid
        else {
            return [
                "The \(label) WebRTC candidate summary is invalid."
            ]
        }
        var issues: [String] = []
        if summary.unknown > 0 {
            issues.append(
                "The \(label) WebRTC candidate summary contains unknown candidate types."
            )
        }
        if route == "direct", requestCount == 0 {
            issues.append(
                "The \(label) direct route did not reach the loopback STUN control."
            )
        }
        if route == "proxied", requestCount != 0 {
            issues.append(
                "The \(label) proxied route sent a loopback STUN request."
            )
        }
        if route == "proxied",
           summary.host > 0 || summary.srflx > 0 || summary.prflx > 0
        {
            issues.append(
                "The \(label) proxied route exposed a direct WebRTC candidate."
            )
        }
        return issues
    }

    private static func parsedClientHints(
        _ text: String?
    ) -> [String: Any]? {
        guard let text,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func changedKeys(
        _ first: [String: String],
        _ second: [String: String]
    ) -> [String] {
        Set(first.keys)
            .union(second.keys)
            .filter { first[$0] != second[$0] }
            .sorted()
    }
}

struct FingerprintAuditReportStore: Sendable {
    static let maximumStoredReports = 3

    let paths: AppPaths

    func save(_ report: FingerprintAuditReport) throws -> URL {
        try paths.prepareBaseDirectories()
        let url = paths.fingerprintAuditsDirectory.appendingPathComponent(
            "audit-\(Int(report.createdAt.timeIntervalSince1970))-\(report.id.uuidString).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(encoder.encode(report), to: url)
        try pruneReports(preserving: url)
        return url
    }

    func pruneStoredReports() throws {
        try paths.prepareBaseDirectories()
        try pruneReports(preserving: nil)
    }

    private func pruneReports(preserving savedURL: URL?) throws {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let savedPath = savedURL?.standardizedFileURL.path
        let candidates = try FileManager.default.contentsOfDirectory(
            at: paths.fingerprintAuditsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap {
            url -> (url: URL, modifiedAt: Date, device: dev_t, inode: ino_t)?
            in
            guard url.standardizedFileURL.path != savedPath,
                  url.lastPathComponent.hasPrefix("audit-"),
                  url.pathExtension == "json"
            else {
                return nil
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let identity = try regularFileIdentity(at: url)
            else {
                return nil
            }
            return (
                url,
                values.contentModificationDate ?? .distantPast,
                identity.device,
                identity.inode
            )
        }.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }

        let retainedCandidateCount = max(
            0,
            Self.maximumStoredReports - (savedURL == nil ? 0 : 1)
        )
        for candidate in candidates.dropFirst(retainedCandidateCount) {
            guard let current = try regularFileIdentity(at: candidate.url),
                  current.device == candidate.device,
                  current.inode == candidate.inode
            else {
                continue
            }
            let result = candidate.url.path.withCString {
                Darwin.unlink($0)
            }
            guard result == 0 || errno == ENOENT else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
        }
    }

    private func regularFileIdentity(
        at url: URL
    ) throws -> (device: dev_t, inode: ino_t)? {
        var status = stat()
        let result = url.path.withCString {
            Darwin.lstat($0, &status)
        }
        if result != 0 {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return nil
        }
        return (status.st_dev, status.st_ino)
    }
}

@MainActor
final class FingerprintAuditCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var phase = "Готово"
    @Published private(set) var report: FingerprintAuditReport?
    @Published private(set) var reportURL: URL?
    @Published var errorMessage: String?

    private let paths: AppPaths
    private let processes: BrowserProcessManager
    private var task: Task<Void, Never>?
    private var activeProfileID: UUID?

    init(paths: AppPaths, processes: BrowserProcessManager) {
        self.paths = paths
        self.processes = processes
        do {
            try FingerprintAuditReportStore(
                paths: paths
            ).pruneStoredReports()
        } catch {
            errorMessage =
                "Не удалось безопасно ограничить старые локальные отчёты отпечатка."
        }
    }

    func start(
        first: BrowserProfile,
        second: BrowserProfile,
        runtime: BrowserRuntime,
        executionMode: FingerprintAuditExecutionMode = .browser,
        managerVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        managerBuild: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
    ) {
        guard !isRunning else { return }
        guard first.id != second.id else {
            errorMessage = "Выбери два разных профиля."
            return
        }
        guard runtime.supportsFingerprintIdentity else {
            errorMessage =
                "Выбери Chromium с поддержкой разделения отпечатков."
            return
        }
        let preflight = BrowserRuntimePreflightValidator.validate(runtime)
        guard preflight.isReady else {
            errorMessage = preflight.errors.joined(separator: " ")
            return
        }
        for profile in [first, second] {
            if processes.runningProfileIDs.contains(profile.id) {
                errorMessage =
                    "Останови «\(profile.name)» перед проверкой."
                return
            }
        }

        isRunning = true
        phase = "Готовим проверку отпечатка"
        report = nil
        reportURL = nil
        errorMessage = nil

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                phase = "Проверяем браузерный движок"
                let initialRuntimeInspection =
                    await inspectRuntime(runtime.executableURL)

                phase = "Проверяем прямой WebRTC-контроль"
                var controlProfile = first
                controlProfile.proxy = nil
                let webrtcDirectControl = try await capture(
                    profile: controlProfile,
                    runtime: runtime,
                    executionMode: executionMode
                )

                phase = "Снимаем \(first.name) · проход 1 из 3"
                let firstInitial = try await capture(
                    profile: first,
                    runtime: runtime,
                    executionMode: executionMode
                )

                phase = "Снимаем \(second.name) · проход 2 из 3"
                let secondCapture = try await capture(
                    profile: second,
                    runtime: runtime,
                    executionMode: executionMode
                )

                phase = "Повторяем \(first.name) · проход 3 из 3"
                let firstRepeat = try await capture(
                    profile: first,
                    runtime: runtime,
                    executionMode: executionMode
                )
                let finalRuntimeInspection =
                    await inspectRuntime(runtime.executableURL)
                guard initialRuntimeInspection == finalRuntimeInspection else {
                    throw NeAntikError.fingerprintAuditFailed(
                        "Браузерный движок изменился во время проверки отпечатка."
                    )
                }

                let newReport = FingerprintAuditReport(
                    id: UUID(),
                    createdAt: Date(),
                    managerVersion: managerVersion,
                    managerBuild: managerBuild,
                    runtimeName: runtime.name,
                    runtimeVersion: finalRuntimeInspection.version,
                    runtimeFlavor: runtime.flavor,
                    runtimeCodeSignatureValid:
                        finalRuntimeInspection.codeSignatureValid,
                    runtimeExecutableSHA256:
                        finalRuntimeInspection.executableSHA256,
                    runtimeFrameworkSHA256:
                        finalRuntimeInspection.frameworkSHA256,
                    executionMode: executionMode,
                    webrtcDirectControl: webrtcDirectControl,
                    firstInitial: firstInitial,
                    second: secondCapture,
                    firstRepeat: firstRepeat
                )
                let savedURL = try FingerprintAuditReportStore(
                    paths: paths
                ).save(newReport)
                report = newReport
                reportURL = savedURL
                phase = newReport.verdict.title
            } catch is CancellationError {
                phase = "Отменено"
            } catch {
                errorMessage = error.localizedDescription
                phase = "Проверка не прошла"
            }
            activeProfileID = nil
            isRunning = false
            task = nil
        }
    }

    private func inspectRuntime(
        _ executableURL: URL
    ) async -> BrowserRuntimeInspection {
        await Task.detached(priority: .userInitiated) {
            BrowserRuntimeInspector.inspect(executableURL: executableURL)
        }.value
    }

    func cancel() {
        task?.cancel()
        if let activeProfileID {
            processes.stop(profileID: activeProfileID)
        }
        activeProfileID = nil
    }

    private func capture(
        profile: BrowserProfile,
        runtime: BrowserRuntime,
        executionMode: FingerprintAuditExecutionMode
    ) async throws -> FingerprintCapture {
        try Task.checkCancellation()
        try paths.prepareProfileDirectories(for: profile.id)
        let auditServer = try await FingerprintAuditLoopbackServer.start()
        defer { auditServer.stop() }
        let stunServer =
            try await FingerprintAuditLoopbackSTUNServer.start()
        defer { stunServer.stop() }
        var auditURLComponents = URLComponents(
            url: auditServer.url,
            resolvingAgainstBaseURL: false
        )!
        auditURLComponents.queryItems = [
            URLQueryItem(
                name: "stunPort",
                value: String(stunServer.port.rawValue)
            )
        ]
        let auditURL = auditURLComponents.url!

        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "app.neantik.fingerprint-audit",
                isDirectory: true
            )
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dataDirectory.path
        )

        let portFile = dataDirectory.appendingPathComponent(
            "DevToolsActivePort"
        )
        activeProfileID = profile.id

        do {
            let devToolsArguments = [
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=0",
                "--remote-allow-origins=http://neantik.local",
                "--disable-extensions",
                "--disable-background-networking",
                "--disable-component-update",
                "--disable-sync",
                "--window-size=1200,800"
            ] + executionMode.additionalLaunchArguments
            try processes.launch(
                profile: profile,
                runtime: runtime,
                additionalArguments: devToolsArguments,
                // Loopback is a potentially trustworthy origin, so
                // secure-context-only fingerprint surfaces such as
                // navigator.deviceMemory remain observable. No external
                // page or user data is transmitted by the audit.
                startURLOverride: auditURL,
                browserDataDirectoryOverride: dataDirectory,
                purpose: .fingerprintAudit(
                    httpLoopbackPort: UInt16(auditServer.url.port!)
                )
            )
            let port = try await waitForDevToolsPort(at: portFile)
            var values = try await evaluateProbeWithRetry(
                port: port,
                expectedPageURL: auditURL
            )
            values["network_route"] =
                profile.proxy == nil ? "direct" : "proxied"
            values["webrtc_stun_requests"] =
                String(stunServer.acceptedRequestCount)
            processes.stop(profileID: profile.id)
            try await waitUntilStopped(profileID: profile.id)
            activeProfileID = nil
            try? FileManager.default.removeItem(at: dataDirectory)

            return FingerprintCapture(
                profileID: profile.id,
                profileName: profile.name,
                identityCode: profile.identity.displayCode,
                capturedAt: Date(),
                values: values
            )
        } catch {
            processes.stop(profileID: profile.id)
            do {
                try await waitUntilStopped(profileID: profile.id)
                try? FileManager.default.removeItem(at: dataDirectory)
            } catch {
                // Keep the disposable directory while a browser may still use
                // it. The system temporary-directory cleanup can remove it
                // after the process has exited.
            }
            activeProfileID = nil
            throw error
        }
    }

    private func waitForDevToolsPort(at url: URL) async throws -> Int {
        for _ in 0..<80 {
            try Task.checkCancellation()
            if let contents = try? String(
                contentsOf: url,
                encoding: .utf8
            ),
               let firstLine = contents
                .split(whereSeparator: \.isNewline)
                .first,
               let port = Int(firstLine),
               (1...65_535).contains(port)
            {
                return port
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NeAntikError.fingerprintAuditFailed(
            "Chromium не открыл локальный DevTools port."
        )
    }

    private func waitForPageTarget(
        port: Int,
        expectedPageURL: URL
    ) async throws -> URL {
        let endpoint = URL(
            string: "http://127.0.0.1:\(port)/json/list"
        )!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for _ in 0..<40 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(from: endpoint)
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 200,
                   let url = try Self.pageTargetWebSocketURL(
                    from: data,
                    expectedPageURL: expectedPageURL
                   )
                {
                    return url
                }
            } catch {
                // Chromium may need a moment after writing DevToolsActivePort.
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NeAntikError.fingerprintAuditFailed(
            "Chromium открыл DevTools, но страница проверки не стала готовой."
        )
    }

    private func evaluateProbeWithRetry(
        port: Int,
        expectedPageURL: URL
    ) async throws -> [String: String] {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let webSocketURL = try await waitForPageTarget(
                    port: port,
                    expectedPageURL: expectedPageURL
                )
                return try await evaluateProbe(at: webSocketURL)
            } catch NeAntikError.fingerprintAuditFailed(let message)
                where Self.isTransientDevToolsContextError(message)
            {
                lastError = NeAntikError.fingerprintAuditFailed(message)
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: 600_000_000)
                    continue
                }
            } catch {
                throw error
            }
        }
        throw lastError ??
            NeAntikError.fingerprintAuditFailed(
                "DevTools probe не успел вернуть значения браузера."
            )
    }

    nonisolated private static func isTransientDevToolsContextError(
        _ message: String
    ) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("execution context was destroyed") ||
            normalized.contains("cannot find context with specified id") ||
            normalized.contains("target closed")
    }

    private func evaluateProbe(
        at webSocketURL: URL
    ) async throws -> [String: String] {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: webSocketURL)
        request.setValue("http://neantik.local", forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let command: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": Self.probeExpression,
                "awaitPromise": true,
                "returnByValue": true,
                "userGesture": true
            ]
        ]
        let commandData = try JSONSerialization.data(
            withJSONObject: command
        )
        guard let commandString = String(
            data: commandData,
            encoding: .utf8
        ) else {
            throw NeAntikError.fingerprintAuditFailed(
                "Не удалось подготовить DevTools запрос."
            )
        }

        let timeout = Task {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }

        try await socket.send(.string(commandString))
        while true {
            try Task.checkCancellation()
            let message = try await socket.receive()
            let data: Data
            switch message {
            case let .string(value):
                data = Data(value.utf8)
            case let .data(value):
                data = value
            @unknown default:
                continue
            }

            guard let object = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
                object["id"] as? Int == 1
            else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                throw NeAntikError.fingerprintAuditFailed(
                    error["message"] as? String ??
                        "DevTools отклонил probe."
                )
            }
            guard let result = object["result"] as? [String: Any],
                  result["exceptionDetails"] == nil,
                  let remoteObject = result["result"] as? [String: Any],
                  let json = remoteObject["value"] as? String,
                  let jsonData = json.data(using: .utf8)
            else {
                throw NeAntikError.fingerprintAuditFailed(
                    "Браузер вернул некорректный результат probe."
                )
            }
            return try JSONDecoder().decode(
                [String: String].self,
                from: jsonData
            )
        }
    }

    private func waitUntilStopped(profileID: UUID) async throws {
        for _ in 0..<80 {
            if !processes.runningProfileIDs.contains(profileID) {
                return
            }
            await Task.detached {
                try? await Task.sleep(nanoseconds: 125_000_000)
            }.value
        }
        throw NeAntikError.fingerprintAuditFailed(
            "Chromium не завершился после проверки отпечатка."
        )
    }

    nonisolated static func pageTargetWebSocketURL(
        from data: Data,
        expectedPageURL: URL? = nil
    ) throws -> URL? {
        let targets = try JSONDecoder().decode(
            [DevToolsTarget].self,
            from: data
        )
        guard let target = targets.first(where: {
            guard $0.type == "page" else { return false }
            guard let expectedPageURL else { return true }
            return $0.url == expectedPageURL.absoluteString
        }) else {
            return nil
        }
        return URL(string: target.webSocketDebuggerURL)
    }

    private struct DevToolsTarget: Decodable {
        let type: String
        let url: String?
        let webSocketDebuggerURL: String

        private enum CodingKeys: String, CodingKey {
            case type
            case url
            case webSocketDebuggerURL = "webSocketDebuggerUrl"
        }
    }

    nonisolated static let probeExpression = #"""
    (async () => {
      const fnv = bytes => {
        let value = 0x811c9dc5;
        for (const byte of bytes) {
          value ^= byte;
          value = Math.imul(value, 0x01000193);
        }
        return (value >>> 0).toString(16).padStart(8, '0');
      };
      const hashText = value => fnv(new TextEncoder().encode(String(value)));

      const canvas = document.createElement('canvas');
      canvas.width = 360;
      canvas.height = 120;
      const context = canvas.getContext('2d');
      context.textBaseline = 'alphabetic';
      context.fillStyle = '#f60';
      context.fillRect(20, 20, 180, 70);
      context.fillStyle = '#069';
      context.font = '18px Arial';
      context.fillText('NeAntik 0123456789', 24, 58);
      context.globalCompositeOperation = 'multiply';
      context.fillStyle = 'rgba(90, 20, 220, 0.73)';
      context.beginPath();
      context.arc(205, 55, 36, 0, Math.PI * 2);
      context.fill();
      const canvasHash = fnv(
        context.getImageData(0, 0, canvas.width, canvas.height).data
      );
      const canvasRepeatHash = fnv(
        context.getImageData(0, 0, canvas.width, canvas.height).data
      );

      let webglPixels = 'unavailable';
      let webglPixelsRepeat = 'unavailable';
      let webglVendor = 'unavailable';
      let webglRenderer = 'unavailable';
      let webglExtensions = 'unavailable';
      let webglShaderPrecision = 'unavailable';
      try {
        const webglCanvas = document.createElement('canvas');
        webglCanvas.width = 128;
        webglCanvas.height = 128;
        const gl = webglCanvas.getContext('webgl', {
          antialias: true,
          preserveDrawingBuffer: true
        });
        if (gl) {
          const debug = gl.getExtension('WEBGL_debug_renderer_info');
          webglVendor = String(
            debug ? gl.getParameter(debug.UNMASKED_VENDOR_WEBGL) :
              gl.getParameter(gl.VENDOR)
          );
          webglRenderer = String(
            debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) :
              gl.getParameter(gl.RENDERER)
          );
          const vertex = gl.createShader(gl.VERTEX_SHADER);
          gl.shaderSource(
            vertex,
            'attribute vec2 p;varying vec2 v;void main(){v=p;gl_Position=vec4(p,0.0,1.0);}'
          );
          gl.compileShader(vertex);
          if (!gl.getShaderParameter(vertex, gl.COMPILE_STATUS)) {
            throw new Error('WebGL vertex shader did not compile');
          }
          const fragment = gl.createShader(gl.FRAGMENT_SHADER);
          gl.shaderSource(
            fragment,
            'precision highp float;varying vec2 v;void main(){gl_FragColor=vec4(v.x*v.x+0.4,v.y*v.y+0.3,sin(v.x*9.0)*0.2+0.5,1.0);}'
          );
          gl.compileShader(fragment);
          if (!gl.getShaderParameter(fragment, gl.COMPILE_STATUS)) {
            throw new Error('WebGL fragment shader did not compile');
          }
          const program = gl.createProgram();
          gl.attachShader(program, vertex);
          gl.attachShader(program, fragment);
          gl.linkProgram(program);
          if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
            throw new Error('WebGL program did not link');
          }
          gl.useProgram(program);
          const buffer = gl.createBuffer();
          gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
          gl.bufferData(
            gl.ARRAY_BUFFER,
            new Float32Array([-1, -1, 1, -1, 0, 1]),
            gl.STATIC_DRAW
          );
          const location = gl.getAttribLocation(program, 'p');
          gl.enableVertexAttribArray(location);
          gl.vertexAttribPointer(location, 2, gl.FLOAT, false, 0, 0);
          gl.viewport(0, 0, 128, 128);
          gl.drawArrays(gl.TRIANGLES, 0, 3);
          const pixels = new Uint8Array(128 * 128 * 4);
          gl.readPixels(0, 0, 128, 128, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
          if (gl.getError() !== gl.NO_ERROR) {
            throw new Error('WebGL pixel readback failed');
          }
          webglPixels = fnv(pixels);
          const repeatPixels = new Uint8Array(128 * 128 * 4);
          gl.readPixels(
            0, 0, 128, 128, gl.RGBA, gl.UNSIGNED_BYTE, repeatPixels
          );
          if (gl.getError() !== gl.NO_ERROR) {
            throw new Error('WebGL repeated pixel readback failed');
          }
          webglPixelsRepeat = fnv(repeatPixels);
          webglExtensions = hashText(
            (gl.getSupportedExtensions() || []).sort().join('|')
          );
          const precisionValues = [];
          for (const shader of [gl.VERTEX_SHADER, gl.FRAGMENT_SHADER]) {
            for (const precision of [
              gl.LOW_FLOAT, gl.MEDIUM_FLOAT, gl.HIGH_FLOAT,
              gl.LOW_INT, gl.MEDIUM_INT, gl.HIGH_INT
            ]) {
              const value = gl.getShaderPrecisionFormat(shader, precision);
              precisionValues.push(
                value ? [
                  value.rangeMin, value.rangeMax, value.precision
                ].join(':') : 'none'
              );
            }
          }
          webglShaderPrecision = hashText(precisionValues.join('|'));
        }
      } catch (_) {}

      let webgpuPolicy = 'disabled';
      try {
        const adapter = navigator.gpu ?
          await navigator.gpu.requestAdapter() : null;
        if (adapter) {
          const limits = {};
          for (const key in adapter.limits) {
            limits[key] = String(adapter.limits[key]);
          }
          webgpuPolicy = `available:${hashText(JSON.stringify({
            features: Array.from(adapter.features || []).sort(),
            limits
          }))}`;
        }
      } catch (_) {}

      const renderAudioHash = async () => {
        const Audio = window.OfflineAudioContext ||
          window.webkitOfflineAudioContext;
        if (!Audio) throw new Error('OfflineAudioContext unavailable');
        const audio = new Audio(1, 6000, 44100);
        const oscillator = audio.createOscillator();
        oscillator.type = 'triangle';
        oscillator.frequency.value = 10000;
        const compressor = audio.createDynamicsCompressor();
        compressor.threshold.value = -50;
        compressor.knee.value = 40;
        compressor.ratio.value = 12;
        compressor.attack.value = 0;
        compressor.release.value = 0.25;
        oscillator.connect(compressor);
        compressor.connect(audio.destination);
        oscillator.start(0);
        const rendered = await audio.startRendering();
        const samples = rendered.getChannelData(0);
        return fnv(new Uint8Array(samples.buffer));
      };
      let audioHash = 'unavailable';
      let audioRepeatHash = 'unavailable';
      try {
        audioHash = await renderAudioHash();
        audioRepeatHash = await renderAudioHash();
      } catch (_) {}

      const rectHost = document.createElement('div');
      rectHost.style.cssText =
        'position:absolute;left:-9999px;width:240.25px;font:15.5px Arial;letter-spacing:.17px';
      rectHost.innerHTML =
        '<span>NeAntik fingerprint rectangle probe with wrapping text</span>';
      document.body.appendChild(rectHost);
      const rectValues = Array.from(
        rectHost.firstChild.getClientRects()
      ).map(rect => [
        rect.x, rect.y, rect.width, rect.height
      ].map(value => value.toFixed(6)).join(',')).join('|');
      const rectRepeatValues = Array.from(
        rectHost.firstChild.getClientRects()
      ).map(rect => [
        rect.x, rect.y, rect.width, rect.height
      ].map(value => value.toFixed(6)).join(',')).join('|');
      rectHost.remove();

      const fontCandidates = [
        'Arial', 'Helvetica Neue', 'Times New Roman', 'Courier New',
        'Menlo', 'SF Pro Text', 'Verdana', 'Georgia'
      ];
      const fonts = fontCandidates.filter(font =>
        document.fonts && document.fonts.check(`16px "${font}"`)
      );

      let clientHints = {};
      try {
        if (navigator.userAgentData) {
          clientHints = await navigator.userAgentData.getHighEntropyValues([
            'architecture', 'bitness', 'brands', 'fullVersionList',
            'mobile', 'model', 'platform', 'platformVersion',
            'uaFullVersion', 'wow64'
          ]);
        }
      } catch (_) {}

      const cssScreenMatch = [
        `width:${matchMedia(
          `(device-width: ${screen.width}px)`
        ).matches ? 1 : 0}`,
        `height:${matchMedia(
          `(device-height: ${screen.height}px)`
        ).matches ? 1 : 0}`,
        `resolution:${matchMedia(
          `(resolution: ${window.devicePixelRatio}dppx)`
        ).matches ? 1 : 0}`
      ].join('|');

      const workerValues = await new Promise(resolve => {
        if (typeof Worker !== 'function' ||
            typeof OffscreenCanvas !== 'function') {
          resolve({});
          return;
        }
        const source = `
          (async () => {
            const fnv = bytes => {
              let value = 0x811c9dc5;
              for (const byte of bytes) {
                value ^= byte;
                value = Math.imul(value, 0x01000193);
              }
              return (value >>> 0).toString(16).padStart(8, '0');
            };
            const hashText = value =>
              fnv(new TextEncoder().encode(String(value)));
            const canvas = new OffscreenCanvas(360, 120);
            const context = canvas.getContext('2d');
            context.textBaseline = 'alphabetic';
            context.fillStyle = '#f60';
            context.fillRect(20, 20, 180, 70);
            context.fillStyle = '#069';
            context.font = '18px Arial';
            context.fillText('NeAntik 0123456789', 24, 58);
            context.globalCompositeOperation = 'multiply';
            context.fillStyle = 'rgba(90, 20, 220, 0.73)';
            context.beginPath();
            context.arc(205, 55, 36, 0, Math.PI * 2);
            context.fill();
            const canvasHash = fnv(
              context.getImageData(
                0, 0, canvas.width, canvas.height
              ).data
            );

            let webglPixels = 'unavailable';
            let webglVendor = 'unavailable';
            let webglRenderer = 'unavailable';
            let webglExtensions = 'unavailable';
            let webglShaderPrecision = 'unavailable';
            try {
              const webglCanvas = new OffscreenCanvas(128, 128);
              const gl = webglCanvas.getContext('webgl', {
                antialias: true,
                preserveDrawingBuffer: true
              });
              if (gl) {
                const debug =
                  gl.getExtension('WEBGL_debug_renderer_info');
                webglVendor = String(
                  debug ?
                    gl.getParameter(debug.UNMASKED_VENDOR_WEBGL) :
                    gl.getParameter(gl.VENDOR)
                );
                webglRenderer = String(
                  debug ?
                    gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) :
                    gl.getParameter(gl.RENDERER)
                );
                const vertex = gl.createShader(gl.VERTEX_SHADER);
                gl.shaderSource(
                  vertex,
                  'attribute vec2 p;varying vec2 v;void main(){v=p;gl_Position=vec4(p,0.0,1.0);}'
                );
                gl.compileShader(vertex);
                const fragment = gl.createShader(gl.FRAGMENT_SHADER);
                gl.shaderSource(
                  fragment,
                  'precision highp float;varying vec2 v;void main(){gl_FragColor=vec4(v.x*v.x+0.4,v.y*v.y+0.3,sin(v.x*9.0)*0.2+0.5,1.0);}'
                );
                gl.compileShader(fragment);
                const program = gl.createProgram();
                gl.attachShader(program, vertex);
                gl.attachShader(program, fragment);
                gl.linkProgram(program);
                if (!gl.getShaderParameter(vertex, gl.COMPILE_STATUS) ||
                    !gl.getShaderParameter(fragment, gl.COMPILE_STATUS) ||
                    !gl.getProgramParameter(program, gl.LINK_STATUS)) {
                  throw new Error('worker WebGL shader failed');
                }
                gl.useProgram(program);
                const buffer = gl.createBuffer();
                gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
                gl.bufferData(
                  gl.ARRAY_BUFFER,
                  new Float32Array([-1, -1, 1, -1, 0, 1]),
                  gl.STATIC_DRAW
                );
                const location = gl.getAttribLocation(program, 'p');
                gl.enableVertexAttribArray(location);
                gl.vertexAttribPointer(
                  location, 2, gl.FLOAT, false, 0, 0
                );
                gl.viewport(0, 0, 128, 128);
                gl.drawArrays(gl.TRIANGLES, 0, 3);
                const pixels = new Uint8Array(128 * 128 * 4);
                gl.readPixels(
                  0, 0, 128, 128,
                  gl.RGBA, gl.UNSIGNED_BYTE, pixels
                );
                if (gl.getError() !== gl.NO_ERROR) {
                  throw new Error('worker WebGL pixel readback failed');
                }
                webglPixels = fnv(pixels);
                webglExtensions = hashText(
                  (gl.getSupportedExtensions() || [])
                    .sort().join('|')
                );
                const precisionValues = [];
                for (const shader of [
                  gl.VERTEX_SHADER, gl.FRAGMENT_SHADER
                ]) {
                  for (const precision of [
                    gl.LOW_FLOAT, gl.MEDIUM_FLOAT, gl.HIGH_FLOAT,
                    gl.LOW_INT, gl.MEDIUM_INT, gl.HIGH_INT
                  ]) {
                    const value = gl.getShaderPrecisionFormat(
                      shader, precision
                    );
                    precisionValues.push(
                      value ? [
                        value.rangeMin,
                        value.rangeMax,
                        value.precision
                      ].join(':') : 'none'
                    );
                  }
                }
                webglShaderPrecision =
                  hashText(precisionValues.join('|'));
              }
            } catch (_) {}

            let clientHints = {};
            try {
              if (navigator.userAgentData) {
                clientHints =
                  await navigator.userAgentData.getHighEntropyValues([
                    'architecture', 'bitness', 'brands',
                    'fullVersionList', 'mobile', 'model',
                    'platform', 'platformVersion',
                    'uaFullVersion', 'wow64'
                  ]);
              }
            } catch (_) {}

            postMessage({
              canvas: canvasHash,
              webgl_pixels: webglPixels,
              webgl_vendor: webglVendor,
              webgl_renderer: webglRenderer,
              webgl_extensions: webglExtensions,
              webgl_shader_precision: webglShaderPrecision,
              user_agent: navigator.userAgent,
              platform: navigator.platform,
              languages: (navigator.languages || []).join(','),
              timezone:
                Intl.DateTimeFormat().resolvedOptions().timeZone || '',
              intl_locale:
                Intl.DateTimeFormat().resolvedOptions().locale || '',
              hardware_concurrency:
                String(navigator.hardwareConcurrency || ''),
              device_memory: String(navigator.deviceMemory || ''),
              client_hints: JSON.stringify(clientHints)
            });
          })().catch(() => postMessage({}));
        `;
        const blobURL = URL.createObjectURL(
          new Blob([source], { type: 'text/javascript' })
        );
        const worker = new Worker(blobURL);
        const finish = value => {
          worker.terminate();
          URL.revokeObjectURL(blobURL);
          resolve(value && typeof value === 'object' ? value : {});
        };
        const timer = setTimeout(() => finish({}), 4000);
        worker.onmessage = event => {
          clearTimeout(timer);
          finish(event.data);
        };
        worker.onerror = () => {
          clearTimeout(timer);
          finish({});
        };
      });
      const workerValue = key => {
        const value = workerValues[key];
        return value === undefined || value === null || value === '' ?
          'unavailable' : String(value);
      };

      let rtcSummary = {
        total: 0,
        host: 0,
        srflx: 0,
        prflx: 0,
        relay: 0,
        unknown: 0
      };
      let rtcSummaryValue = 'unavailable';
      let rtcComplete = 'false';
      const stunPort = new URL(location.href).searchParams.get('stunPort');
      const stunURL = stunPort && /^[1-9][0-9]{0,4}$/.test(stunPort) ?
        `stun:127.0.0.1:${stunPort}` : null;
      try {
        if (!stunURL) throw new Error('missing loopback STUN port');
        const peer = new RTCPeerConnection({
          iceServers: [{ urls: [stunURL] }],
          iceTransportPolicy: 'all'
        });
        peer.createDataChannel('probe');
        peer.onicecandidate = event => {
          if (!event.candidate) return;
          const type = String(
            event.candidate.type || 'unknown'
          ).toLowerCase();
          rtcSummary.total += 1;
          if (Object.prototype.hasOwnProperty.call(rtcSummary, type) &&
              type !== 'total') {
            rtcSummary[type] += 1;
          } else {
            rtcSummary.unknown += 1;
          }
        };
        await peer.setLocalDescription(await peer.createOffer());
        if (peer.iceGatheringState !== 'complete') {
          await new Promise(resolve => {
            let settled = false;
            const finish = () => {
              if (settled) return;
              settled = true;
              peer.removeEventListener('icegatheringstatechange', changed);
              clearTimeout(timer);
              resolve();
            };
            const changed = () => {
              if (peer.iceGatheringState === 'complete') finish();
            };
            const timer = setTimeout(finish, 8000);
            peer.addEventListener('icegatheringstatechange', changed);
            changed();
          });
        }
        rtcComplete = peer.iceGatheringState === 'complete' ?
          'true' : 'false';
        peer.close();
        rtcSummaryValue = JSON.stringify(rtcSummary);
      } catch (_) {}

      return JSON.stringify({
        canvas: canvasHash,
        canvas_repeat: canvasRepeatHash,
        webgl_pixels: webglPixels,
        webgl_pixels_repeat: webglPixelsRepeat,
        webgl_vendor: webglVendor,
        webgl_renderer: webglRenderer,
        webgl_extensions: webglExtensions,
        webgl_shader_precision: webglShaderPrecision,
        webgpu_policy: webgpuPolicy,
        audio: audioHash,
        audio_repeat: audioRepeatHash,
        client_rects: hashText(rectValues),
        client_rects_repeat: hashText(rectRepeatValues),
        user_agent: navigator.userAgent,
        platform: navigator.platform,
        languages: (navigator.languages || []).join(','),
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || '',
        intl_locale:
          Intl.DateTimeFormat().resolvedOptions().locale || '',
        css_screen_match: cssScreenMatch,
        screen: [
          screen.width, screen.height, screen.availWidth, screen.availHeight,
          screen.colorDepth, window.devicePixelRatio
        ].join('x'),
        hardware_concurrency: String(navigator.hardwareConcurrency || ''),
        device_memory: String(navigator.deviceMemory || ''),
        touch_points: String(navigator.maxTouchPoints || 0),
        fonts: fonts.join(','),
        client_hints: JSON.stringify(clientHints),
        worker_canvas: workerValue('canvas'),
        worker_webgl_pixels: workerValue('webgl_pixels'),
        worker_webgl_vendor: workerValue('webgl_vendor'),
        worker_webgl_renderer: workerValue('webgl_renderer'),
        worker_webgl_extensions: workerValue('webgl_extensions'),
        worker_webgl_shader_precision:
          workerValue('webgl_shader_precision'),
        worker_user_agent: workerValue('user_agent'),
        worker_platform: workerValue('platform'),
        worker_languages: workerValue('languages'),
        worker_timezone: workerValue('timezone'),
        worker_intl_locale: workerValue('intl_locale'),
        worker_hardware_concurrency:
          workerValue('hardware_concurrency'),
        worker_device_memory: workerValue('device_memory'),
        worker_client_hints: workerValue('client_hints'),
        webrtc_probe: 'loopback-stun-v1',
        webrtc_complete: rtcComplete,
        webrtc_candidate_summary: rtcSummaryValue
      });
    })()
    """#
}

private final class FingerprintAuditLoopbackServer {
    let url: URL

    private let listener: NWListener

    private init(listener: NWListener, url: URL) {
        self.listener = listener
        self.url = url
    }

    static func start() async throws -> FingerprintAuditLoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            let completionGate = CompletionGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port,
                          let url = URL(
                            string: "http://127.0.0.1:\(port.rawValue)/"
                          )
                    else {
                        guard completionGate.claim() else { return }
                        listener.cancel()
                        continuation.resume(
                            throwing: NeAntikError.fingerprintAuditFailed(
                                "Не удалось создать приватный loopback origin для проверки."
                            )
                        )
                        return
                    }
                    guard completionGate.claim() else { return }
                    continuation.resume(
                        returning: FingerprintAuditLoopbackServer(
                            listener: listener,
                            url: url
                        )
                    )
                case let .failed(error):
                    guard completionGate.claim() else { return }
                    continuation.resume(
                        throwing: NeAntikError.fingerprintAuditFailed(
                            "Не удалось запустить приватный loopback origin: \(error.localizedDescription)"
                        )
                    )
                case .cancelled:
                    guard completionGate.claim() else { return }
                    continuation.resume(
                        throwing: NeAntikError.fingerprintAuditFailed(
                            "Приватный loopback origin был отменён."
                        )
                    )
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(
                    queue: DispatchQueue(
                        label: "app.neantik.fingerprint-audit.connection"
                    )
                )
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 16_384
                ) { _, _, _, _ in
                    let body = """
                    <!doctype html><meta charset="utf-8">
                    <title>Проверка отпечатка NeAntik</title>
                    """
                    let response = """
                    HTTP/1.1 200 OK\r
                    Content-Type: text/html; charset=utf-8\r
                    Content-Length: \(body.utf8.count)\r
                    Cache-Control: no-store\r
                    Connection: close\r
                    \r
                    \(body)
                    """
                    connection.send(
                        content: Data(response.utf8),
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        }
                    )
                }
            }
            listener.start(
                queue: DispatchQueue(
                    label: "app.neantik.fingerprint-audit.listener"
                )
            )
        }
    }

    func stop() {
        listener.cancel()
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}
