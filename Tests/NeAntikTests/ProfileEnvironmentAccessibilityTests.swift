import Foundation
import Testing
@testable import NeAntik

struct ProfileEnvironmentAccessibilityTests {
    @Test
    func evidenceSymbolsAreDistinctAndObservedIsNotSuccess() {
        let evidenceStates: [DiagnosticEvidenceState] = [
            .configured,
            .derived,
            .observed,
            .unavailable,
            .unverified,
        ]
        let evidenceSymbols = evidenceStates.map(
            EvidenceBadgePresentation.systemImage
        )

        #expect(Set(evidenceSymbols).count == evidenceStates.count)
        #expect(
            EvidenceBadgePresentation.systemImage(for: .observed) !=
                DiagnosticSeverityPresentation.systemImage(for: .success)
        )
        #expect(
            DiagnosticEvidenceState.observed.title !=
                DiagnosticSeverityPresentation.title(for: .success)
        )
    }

    @Test
    func severityRollupUsesTheMostSeriousFinding() {
        let fields = [
            field(id: "neutral", severity: .neutral),
            field(id: "success", severity: .success),
            field(id: "attention", severity: .attention),
            field(id: "failure", severity: .failure),
            field(id: "blocking", severity: .blocking),
        ]

        #expect(
            ProfileEnvironmentPresentation.highestSeverity(in: fields) ==
                .blocking
        )
        #expect(
            ProfileEnvironmentPresentation.highestSeverity(
                in: Array(fields.dropLast())
            ) == .failure
        )
        #expect(
            ProfileEnvironmentPresentation.highestSeverity(in: []) ==
                .neutral
        )
    }

    @Test
    func collapsedSectionSummaryKeepsHiddenProblemsVisible() {
        let section = EnvironmentDiagnosticSection(
            id: "transport",
            title: "QUIC и DNS",
            fields: [
                EnvironmentDiagnosticField(
                    id: "transport.quic-policy",
                    title: "QUIC",
                    value: "Отключён",
                    state: .configured,
                    severity: .success
                ),
                field(id: "hidden-failure", severity: .failure),
                field(id: "hidden-attention", severity: .attention),
            ]
        )

        let summary = ProfileEnvironmentPresentation.sectionSummary(
            for: section
        )

        #expect(summary.contains("1 проблема"))
        #expect(summary.contains("1 требует внимания"))
    }

    @Test
    func inspectorPreservesAllFiveEnvironmentSections() {
        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: BrowserProfile(name: "Accessibility"),
            runtime: nil,
            proxyHealth: nil
        )

        #expect(
            snapshot.sections.map(\.id) == [
                "route",
                "fingerprint",
                "webrtc",
                "transport",
                "geolocation",
            ]
        )
    }

    @Test
    func intentionallyUnmeasuredFieldsRemainNeutral() throws {
        let snapshot = ProfileEnvironmentInspector.snapshot(
            profile: BrowserProfile(name: "Neutral evidence"),
            runtime: nil,
            proxyHealth: nil
        )
        let fields = snapshot.sections.flatMap(\.fields)
        let expectedNeutralIDs = [
            "route.chromium-http",
            "transport.quic-observed",
            "transport.dns-observed",
            "geolocation.browser-api",
        ]

        for fieldID in expectedNeutralIDs {
            let diagnostic = try #require(
                fields.first { $0.id == fieldID }
            )
            #expect(diagnostic.severity == .neutral)
        }
    }

    private func field(
        id: String,
        severity: DiagnosticFindingSeverity
    ) -> EnvironmentDiagnosticField {
        EnvironmentDiagnosticField(
            id: id,
            title: id,
            value: "Тестовое значение",
            state: .observed,
            severity: severity
        )
    }
}
