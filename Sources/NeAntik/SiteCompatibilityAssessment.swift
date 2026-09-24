import Foundation

enum SiteFeatureObservation: Equatable, Sendable {
    case observed
    case unavailable
    case notChecked

    var title: String {
        switch self {
        case .observed: "Доступно в проверенной среде"
        case .unavailable: "Недоступно в проверенной среде"
        case .notChecked: "Не проверено"
        }
    }
}

struct SiteCompatibilityAssessment: Equatable, Sendable {
    static let freshnessLifetime: TimeInterval = 24 * 60 * 60

    let profileID: UUID
    let observedAt: Date
    let configurationRevision: ProfileFingerprintConfigurationRevision
    let canvas: SiteFeatureObservation
    let webGL: SiteFeatureObservation
    let audio: SiteFeatureObservation
    let mediaDevices: SiteFeatureObservation
    let limitations: String

    static func resolve(
        report: FingerprintAuditReport,
        profile: BrowserProfile,
        runtime: BrowserRuntime,
        now: Date = Date()
    ) -> Self? {
        guard report.effectiveExecutionMode == .browser,
              report.effectiveAuditSchemaVersion == FingerprintAuditReport.currentAuditSchemaVersion,
              report.runtimeFlavor == runtime.flavor,
              let observation = report.revisionBoundFingerprintObservations(
                auditedProfiles: [profile],
                currentProfiles: [profile],
                runtime: runtime
              ).first(where: { $0.profileID == profile.id }),
              observation.isUsable(for: profile, runtime: runtime, now: now),
              let configurationRevision = observation.configurationRevision
        else { return nil }

        let captured = report.firstRepeat.values
        return Self(
            profileID: profile.id,
            observedAt: observation.observedAt,
            configurationRevision: configurationRevision,
            canvas: Self.state(captured["canvas"]),
            webGL: Self.state(captured["webgl_pixels"]),
            audio: Self.state(captured["audio"]),
            mediaDevices: Self.state(captured["media_devices"]),
            limitations: "Проверяет только доступность функций в локальном Chromium. Не проверяет выбранный сайт, его интерфейс, вход, сценарии или решения его защиты. Сводка действует 24 часа."
        )
    }

    func isUsable(for profile: BrowserProfile, runtime: BrowserRuntime?, now: Date) -> Bool {
        guard profile.id == profileID, let runtime,
              configurationRevision == ProfileFingerprintConfigurationRevision(profile: profile, runtime: runtime)
        else { return false }
        return isFresh(at: now)
    }

    func isFresh(at now: Date) -> Bool {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        let age = now.timeIntervalSince(observedAt)
        return age >= -5 * 60 && age <= Self.freshnessLifetime
    }

    static func state(_ value: String?) -> SiteFeatureObservation {
        guard let value, !value.isEmpty else { return .notChecked }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == "unavailable" || normalized == "unsupported" || normalized == "не доступно" || normalized == "недоступно" {
            return .unavailable
        }
        if normalized == "available" || normalized == "доступно" || normalized == "true" {
            return .observed
        }
        if normalized.count == 8 && normalized.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) {
            return .observed
        }
        if ["unknown", "not checked", "не проверено"].contains(normalized) {
            return .notChecked
        }
        return .notChecked
    }
}
