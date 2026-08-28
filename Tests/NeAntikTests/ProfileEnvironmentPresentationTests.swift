import Foundation
import Testing
@testable import NeAntik

struct ProfileEnvironmentPresentationTests {
    @Test(arguments: [
        (0, "0 разделов"),
        (1, "1 раздел"),
        (2, "2 раздела"),
        (5, "5 разделов"),
        (11, "11 разделов"),
        (21, "21 раздел"),
        (24, "24 раздела"),
        (25, "25 разделов"),
    ])
    func diagnosticSectionCountUsesRussianPluralization(
        count: Int,
        expected: String
    ) {
        #expect(
            ProfileEnvironmentPresentation.sectionCountTitle(count) == expected
        )
    }

    @Test
    func expandingASectionCollapsesThePreviouslyExpandedSection() {
        let expanded = ProfileEnvironmentPresentation.expansionSelection(
            current: ["fingerprint"],
            sectionID: "webrtc",
            isExpanded: true
        )
        #expect(expanded == ["webrtc"])

        let collapsed = ProfileEnvironmentPresentation.expansionSelection(
            current: expanded,
            sectionID: "webrtc",
            isExpanded: false
        )
        #expect(collapsed.isEmpty)
    }

    @Test
    func severityRollupKeepsEvidenceOriginSeparateFromUrgency() {
        let fields = [
            field(id: "configured", severity: .neutral),
            field(id: "measured", severity: .success),
            field(id: "review", severity: .attention),
            field(id: "failed", severity: .failure),
        ]

        #expect(
            ProfileEnvironmentPresentation.highestSeverity(in: fields)
                == .failure
        )
        #expect(
            EvidenceBadgePresentation.systemImage(for: .unverified)
                == "questionmark.circle"
        )
        #expect(
            EvidenceBadgePresentation.systemImage(for: .observed)
                == "eye.circle"
        )
        #expect(
            DiagnosticSeverityPresentation.systemImage(for: .failure)
                == "xmark.octagon.fill"
        )
    }

    @Test
    func collapsedSummaryIncludesFailureAndAttentionCounts() {
        let section = EnvironmentDiagnosticSection(
            id: "route",
            title: "Маршрут и прокси",
            fields: [
                field(
                    id: "route.mode",
                    value: "Через HTTP-прокси",
                    severity: .neutral
                ),
                field(id: "failed", severity: .failure),
                field(id: "review", severity: .attention),
            ]
        )

        #expect(
            ProfileEnvironmentPresentation.sectionSummary(for: section)
                == "Через HTTP-прокси · 1 проблема · " +
                    "1 требует внимания"
        )
    }

    @Test
    func initialExpansionSelectsOnlyFirstCriticalSection() {
        let snapshot = makeSnapshot(
            sections: [
                EnvironmentDiagnosticSection(
                    id: "route",
                    title: "Маршрут и прокси",
                    fields: [field(id: "route.mode")]
                ),
                EnvironmentDiagnosticSection(
                    id: "fingerprint",
                    title: "Fingerprint",
                    fields: [field(id: "signature", severity: .failure)]
                ),
                EnvironmentDiagnosticSection(
                    id: "webrtc",
                    title: "WebRTC",
                    fields: [field(id: "loopback", severity: .blocking)]
                ),
            ]
        )

        #expect(
            ProfileEnvironmentPresentation.initialExpandedSectionID(
                in: snapshot
            ) == "fingerprint"
        )
        #expect(
            ProfileEnvironmentPresentation.criticalFindings(in: snapshot)
                .map(\.id) == ["signature", "loopback"]
        )
    }

    @Test
    func neutralSnapshotStartsFullyCollapsedAndKeepsOverviewFacts() {
        let snapshot = makeSnapshot(
            sections: [
                EnvironmentDiagnosticSection(
                    id: "route",
                    title: "Маршрут и прокси",
                    fields: [
                        field(
                            id: "route.mode",
                            value: "Прямое подключение"
                        )
                    ]
                ),
                EnvironmentDiagnosticSection(
                    id: "fingerprint",
                    title: "Fingerprint",
                    fields: [
                        field(
                            id: "fingerprint.runtime",
                            value: "Chromium 151"
                        )
                    ]
                ),
            ]
        )

        #expect(
            ProfileEnvironmentPresentation.initialExpandedSectionID(
                in: snapshot
            ) == nil
        )
        #expect(
            ProfileEnvironmentPresentation.routeSummary(in: snapshot)
                == "Прямое подключение"
        )
        #expect(
            ProfileEnvironmentPresentation.runtimeSummary(in: snapshot)
                == "Chromium 151"
        )
        #expect(
            ProfileEnvironmentPresentation.displayTitle(
                for: snapshot.sections[1]
            ) == "Отпечаток браузера"
        )
    }

    @Test
    func rollupDeduplicatesOneRootCauseAndReturnsItsAction() {
        let resolution = DiagnosticResolution(
            key: .proxyContext,
            mode: .actionRequired,
            action: .testProxy
        )
        let snapshot = makeSnapshot(
            sections: [
                EnvironmentDiagnosticSection(
                    id: "route",
                    title: "Маршрут",
                    fields: [
                        field(
                            id: "route.last-probe",
                            severity: .attention,
                            resolution: resolution
                        ),
                        field(
                            id: "geolocation.context",
                            severity: .attention,
                            resolution: resolution
                        ),
                        field(
                            id: "geolocation.launch",
                            severity: .attention,
                            resolution: resolution
                        ),
                    ]
                )
            ]
        )

        #expect(
            ProfileEnvironmentPresentation.attentionCount(in: snapshot) == 1
        )
        #expect(
            ProfileEnvironmentPresentation.recommendedAction(in: snapshot) ==
                .testProxy
        )
        #expect(
            ProfileEnvironmentPresentation.rollupTitle(
                highestSeverity: .attention,
                failureCount: 0,
                attentionCount: 1
            ) == "Нужно проверить"
        )
    }

    @Test
    func mixedSeverityRootCauseCountsOnlyItsHighestSeverity() {
        let attentionResolution = DiagnosticResolution(
            key: .proxyContext,
            mode: .actionRequired,
            action: .testProxy
        )
        let failureResolution = DiagnosticResolution(
            key: .proxyContext,
            mode: .actionRequired,
            action: .editProxy
        )
        let section = EnvironmentDiagnosticSection(
            id: "geolocation",
            title: "Геолокация",
            fields: [
                field(
                    id: "geolocation.location",
                    value: "Контекст выхода",
                    severity: .attention,
                    resolution: attentionResolution
                ),
                field(
                    id: "geolocation.context",
                    severity: .failure,
                    resolution: failureResolution
                ),
                field(
                    id: "geolocation.launch",
                    severity: .attention,
                    resolution: attentionResolution
                ),
            ]
        )
        let snapshot = makeSnapshot(sections: [section])

        #expect(
            ProfileEnvironmentPresentation.failureCount(in: snapshot) == 1
        )
        #expect(
            ProfileEnvironmentPresentation.attentionCount(in: snapshot) == 0
        )
        #expect(
            ProfileEnvironmentPresentation.sectionSummary(for: section) ==
                "Контекст выхода · Значение · 1 проблема"
        )
        #expect(
            ProfileEnvironmentPresentation.recommendedAction(in: snapshot) ==
                .editProxy
        )
    }

    @Test
    func launchFixIsNeutralButVisibleInReadyRollup() {
        let resolution = DiagnosticResolution(
            key: .proxyContext,
            mode: .fixOnNextLaunch,
            action: .testProxy
        )
        let snapshot = makeSnapshot(
            sections: [
                EnvironmentDiagnosticSection(
                    id: "route",
                    title: "Маршрут",
                    fields: [
                        field(
                            id: "route.last-probe",
                            severity: .neutral,
                            resolution: resolution
                        )
                    ]
                )
            ]
        )

        #expect(
            ProfileEnvironmentPresentation.hasAutomaticLaunchFix(
                in: snapshot
            )
        )
        #expect(
            ProfileEnvironmentPresentation.rollupTitle(
                highestSeverity: .neutral,
                failureCount: 0,
                attentionCount: 0,
                hasAutomaticLaunchFix: true
            ) == "Готово · прокси проверится при запуске"
        )
    }

    @Test
    func overviewCompactsRuntimeAndUsesReadyLanguage() {
        let snapshot = makeSnapshot(
            sections: [
                EnvironmentDiagnosticSection(
                    id: "fingerprint",
                    title: "Fingerprint",
                    fields: [
                        field(
                            id: "fingerprint.runtime",
                            value:
                                "Chromium с разделением отпечатков · " +
                                "151.0.7922.108",
                            severity: .success
                        )
                    ]
                )
            ]
        )

        #expect(
            ProfileEnvironmentPresentation.runtimeSummary(in: snapshot) ==
                "Chromium 151"
        )
        #expect(
            ProfileEnvironmentPresentation.rollupTitle(
                highestSeverity: .success,
                failureCount: 0,
                attentionCount: 0
            ) == "Среда готова"
        )
    }

    private func field(
        id: String,
        value: String = "Значение",
        severity: DiagnosticFindingSeverity = .neutral,
        resolution: DiagnosticResolution? = nil
    ) -> EnvironmentDiagnosticField {
        EnvironmentDiagnosticField(
            id: id,
            title: "Поле",
            value: value,
            state: .configured,
            severity: severity,
            resolution: resolution
        )
    }

    private func makeSnapshot(
        sections: [EnvironmentDiagnosticSection]
    ) -> ProfileEnvironmentSnapshot {
        ProfileEnvironmentSnapshot(
            schemaVersion: ProfileEnvironmentSnapshot.currentSchemaVersion,
            profileID: UUID(),
            generatedAt: Date(timeIntervalSince1970: 0),
            sections: sections,
            limitations: []
        )
    }
}
