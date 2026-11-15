import Foundation
import Testing
@testable import NeAntik

struct SiteCompatibilityAssessmentTests {
    @Test
    func featureObservationsHaveEnglishAndRussianPresentation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let en = try #require(Bundle(path: root.appendingPathComponent("Resources/en.lproj").path))
        let ru = try #require(Bundle(path: root.appendingPathComponent("Resources/ru.lproj").path))
        let cases: [(SiteFeatureObservation, String)] = [
            (.observed, "Available in the tested environment"),
            (.unavailable, "Unavailable in the tested environment"),
            (.notChecked, "Not Checked"),
            (.failed, "Could not read the device list"),
            (.timedOut, "Devices did not respond in time")
        ]
        for (observation, expected) in cases {
            #expect(observation.localizedTitle(bundle: en) == expected)
            #expect(observation.localizedTitle(bundle: ru) == observation.title)
        }
    }

    @Test
    func enumerationMustSucceedBeforeShowingAvailability() {
        #expect(SiteCompatibilityAssessment.mediaState(["media_devices": "available"]) == .notChecked)
        #expect(SiteCompatibilityAssessment.mediaState(["media_devices": "available", "media_device_count": "-1"]) == .notChecked)
        #expect(SiteCompatibilityAssessment.mediaState(["media_devices": "available", "media_device_count": "0", "media_device_observation": "observed"]) == .observed)
        #expect(SiteCompatibilityAssessment.mediaState(["media_devices": "available", "media_device_count": "unavailable", "media_device_observation": "error"]) == .failed)
        #expect(SiteCompatibilityAssessment.mediaState(["media_devices": "available", "media_device_observation": "timeout"]) == .timedOut)
        #expect(SiteCompatibilityAssessment.mediaState(["media_devices": "unavailable", "media_device_observation": "api-absent"]) == .unavailable)
        #expect(SiteCompatibilityAssessment.mediaState(["media_devices": "available", "media_device_count": "1", "media_device_observation": "invented"]) == .notChecked)
    }

    @Test
    func unknownOrMalformedObservationsFailClosed() {
        #expect(SiteCompatibilityAssessment.state(nil) == .notChecked)
        #expect(SiteCompatibilityAssessment.state("not-probed") == .notChecked)
        #expect(SiteCompatibilityAssessment.state("unavailable") == .unavailable)
        #expect(SiteCompatibilityAssessment.state("available") == .observed)
        #expect(SiteCompatibilityAssessment.state("a1b2c3d4") == .observed)
        #expect(SiteCompatibilityAssessment.state("203.0.113.8") == .notChecked)
    }

    @Test
    func compatibilityReportExpiresAfterOneDayAndRejectsFutureDates() {
        let observedAt = Date(timeIntervalSince1970: 1_000_000)
        let profile = BrowserProfile(name: "Freshness")
        let runtime = BrowserRuntime(
            name: "Test Runtime",
            executableURL: URL(fileURLWithPath: "/tmp/test-runtime"),
            source: "test",
            inspection: BrowserRuntimeInspection(
                version: "153.0.8010.52",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )
        let assessment = SiteCompatibilityAssessment(
            profileID: profile.id,
            observedAt: observedAt,
            configurationRevision: ProfileFingerprintConfigurationRevision(
                profile: profile,
                runtime: runtime
            ),
            canvas: .observed,
            webGL: .observed,
            audio: .observed,
            mediaDevices: .unavailable,
            limitations: "Local API availability only."
        )

        #expect(assessment.isFresh(at: observedAt.addingTimeInterval(60)))
        #expect(assessment.isFresh(at: observedAt.addingTimeInterval(86_399)))
        #expect(!assessment.isFresh(at: observedAt.addingTimeInterval(86_401)))
        #expect(!assessment.isFresh(at: observedAt.addingTimeInterval(-301)))
        #expect(!assessment.isFresh(at: .distantFuture))
    }
}
