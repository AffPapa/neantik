import Foundation
import Testing
@testable import NeAntik

struct ProfileDiagnosticsSummaryTests {
    @Test
    func firstLaunchIsQuietlyReady() {
        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: .init(
                lock: .clear,
                browserData: .missing,
                recovery: .clear,
                lastLaunchedAt: nil
            ),
            runtimeProvenance: readyRuntime()
        )

        #expect(summary.status == .ready)
        #expect(summary.detail.contains("первому запуску"))
    }

    @Test
    func recoveryIsVisibleWithoutOpeningDetails() {
        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: .init(
                lock: .clear,
                browserData: .available(bytes: 10, entries: 1),
                recovery: .required,
                lastLaunchedAt: Date()
            )
        )

        #expect(summary.status == .attention)
        #expect(summary.detail.contains("восстановление"))
    }

    @Test
    func unavailableInspectionDoesNotLookHealthy() {
        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: .init(
                lock: .unavailable,
                browserData: .unavailable,
                recovery: .unavailable,
                lastLaunchedAt: Date()
            )
        )

        #expect(summary.status == .unavailable)
        #expect(summary.status != .ready)
    }

    @Test
    func missingDataAfterLaunchNeedsAttention() {
        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: .init(
                lock: .clear,
                browserData: .missing,
                recovery: .clear,
                lastLaunchedAt: Date()
            ),
            runtimeProvenance: readyRuntime()
        )

        #expect(summary.status == .attention)
    }

    @Test
    func unavailablePrivacyPanelIsNotReportedAsHealthy() {
        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: .init(
                lock: .clear,
                browserData: .available(bytes: 10, entries: 1),
                recovery: .clear,
                lastLaunchedAt: Date()
            ),
            privacyPanel: .init(
                profileID: nil,
                observedAt: nil,
                mediaDevices: .unavailable,
                mediaDeviceCount: nil,
                permissionsAPI: .unknown,
                camera: .unknown,
                microphone: .unknown
            ),
            runtimeProvenance: readyRuntime()
        )

        #expect(summary.status == .unavailable)
    }

    @Test
    func invalidRuntimeIsPresentedAsAttention() {
        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: .init(
                lock: .clear,
                browserData: .available(bytes: 10, entries: 1),
                recovery: .clear,
                lastLaunchedAt: Date()
            ),
            runtimeProvenance: RuntimeProvenanceSnapshot(
                name: "NeAntik Browser",
                version: "153.0.8010.52",
                source: "Встроен",
                flavor: "Fingerprint Chromium",
                architecture: "Apple Silicon",
                signature: "Невалидна",
                executableDigest: "Измерен локально",
                frameworkDigest: "Измерен локально",
                preflight: "Требует внимания",
                publicReleaseStatus: "Соответствует baseline"
            )
        )

        #expect(summary.status == .attention)
    }

    @Test
    func runtimeBelowDirectBaselineIsPresentedAsAttention() {
        var runtime = readyRuntime()
        runtime = RuntimeProvenanceSnapshot(
            name: runtime.name,
            version: runtime.version,
            source: runtime.source,
            flavor: runtime.flavor,
            architecture: runtime.architecture,
            signature: runtime.signature,
            executableDigest: runtime.executableDigest,
            frameworkDigest: runtime.frameworkDigest,
            preflight: runtime.preflight,
            publicReleaseStatus:
                "Ниже baseline 153.0.8010.52 — Direct-релиз заблокирован"
        )

        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: healthyLifecycle(),
            runtimeProvenance: runtime
        )

        #expect(summary.status == .attention)
        #expect(summary.detail.contains("Direct baseline"))
    }

    @Test
    func unknownDirectReleaseStatusIsNotReportedAsHealthy() {
        var runtime = readyRuntime()
        runtime = RuntimeProvenanceSnapshot(
            name: runtime.name,
            version: runtime.version,
            source: runtime.source,
            flavor: runtime.flavor,
            architecture: runtime.architecture,
            signature: runtime.signature,
            executableDigest: runtime.executableDigest,
            frameworkDigest: runtime.frameworkDigest,
            preflight: runtime.preflight,
            publicReleaseStatus: "Не определён"
        )

        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: healthyLifecycle(),
            runtimeProvenance: runtime
        )

        #expect(summary.status == .unavailable)
    }

    @Test
    func incompleteRuntimeProvenanceIsNotReportedAsHealthy() {
        let runtime = RuntimeProvenanceSnapshot(
            name: "NeAntik Browser",
            version: "153.0.8010.52",
            source: "Встроен",
            flavor: "Fingerprint Chromium",
            architecture: "Apple Silicon",
            signature: "Валидна",
            executableDigest: "Не измерен",
            frameworkDigest: "Измерен локально",
            preflight: "Готов к запуску",
            publicReleaseStatus: "Соответствует baseline"
        )

        let summary = ProfileDiagnosticsSummary.resolve(
            lifecycle: healthyLifecycle(),
            runtimeProvenance: runtime
        )

        #expect(summary.status == .unavailable)
    }

    private func healthyLifecycle() -> ProfileLifecycleHealthSnapshot {
        .init(
            lock: .clear,
            browserData: .available(bytes: 10, entries: 1),
            recovery: .clear,
            lastLaunchedAt: Date()
        )
    }

    private func readyRuntime() -> RuntimeProvenanceSnapshot {
        RuntimeProvenanceSnapshot(
            name: "NeAntik Browser",
            version: "153.0.8010.52",
            source: "Встроен",
            flavor: "Fingerprint Chromium",
            architecture: "Apple Silicon",
            signature: "Валидна",
            executableDigest: "Измерен локально",
            frameworkDigest: "Измерен локально",
            preflight: "Готов к запуску",
            publicReleaseStatus: "Соответствует baseline"
        )
    }
}
