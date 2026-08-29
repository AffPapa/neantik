import Foundation
import Testing
@testable import NeAntik

struct FingerprintAuditObservationTests {
    @Test
    func validBrowserReportMapsOnlyStableAWithoutRawSurfaces() {
        let firstID = UUID()
        let secondID = UUID()
        let repeatedAt = Date(timeIntervalSince1970: 30)
        let report = makeReport(
            first: capture(
                id: firstID,
                identityCode: "NA-FIRST",
                capturedAt: Date(timeIntervalSince1970: 10),
                canvas: "private-canvas-a",
                webGL: "private-webgl-a"
            ),
            second: capture(
                id: secondID,
                identityCode: "NA-SECOND",
                capturedAt: Date(timeIntervalSince1970: 20),
                canvas: "private-canvas-b",
                webGL: "private-webgl-b"
            ),
            repeatCapture: capture(
                id: firstID,
                identityCode: "NA-FIRST",
                capturedAt: repeatedAt,
                canvas: "private-canvas-a",
                webGL: "private-webgl-a"
            )
        )

        let observations = report.validatedProfileFingerprintObservations()

        #expect(observations.count == 1)
        #expect(observations.first?.profileID == firstID)
        #expect(observations.first?.profileID != secondID)
        #expect(observations.first?.observedAt == repeatedAt)
        #expect(observations.first?.route == .direct)
        #expect(observations.first?.verdict == .verified)
        #expect(observations.first?.webRTCLoopback == .passed)
    }

    @Test
    func duplicateOrSwappedABASequenceIsRejected() {
        let first = capture(
            id: UUID(),
            identityCode: "NA-FIRST",
            canvas: "canvas-a",
            webGL: "webgl-a"
        )
        let second = capture(
            id: UUID(),
            identityCode: "NA-SECOND",
            canvas: "canvas-b",
            webGL: "webgl-b"
        )
        let duplicate = makeReport(
            first: first,
            second: FingerprintCapture(
                profileID: first.profileID,
                profileName: "Duplicate",
                identityCode: first.identityCode,
                capturedAt: second.capturedAt,
                values: second.values
            ),
            repeatCapture: first
        )
        let swapped = makeReport(
            first: first,
            second: second,
            repeatCapture: second
        )

        #expect(duplicate.validatedProfileFingerprintObservations().isEmpty)
        #expect(swapped.validatedProfileFingerprintObservations().isEmpty)
    }

    @Test
    func invalidRouteIsRejected() {
        let firstID = UUID()
        var invalidValues = networkValues(
            route: "direct",
            canvas: "canvas-a",
            webGL: "webgl-a"
        )
        invalidValues["network_route"] = "vpn"
        let first = FingerprintCapture(
            profileID: firstID,
            profileName: "First",
            identityCode: "NA-FIRST",
            capturedAt: Date(timeIntervalSince1970: 10),
            values: invalidValues
        )
        let report = makeReport(
            first: first,
            second: capture(
                id: UUID(),
                identityCode: "NA-SECOND",
                canvas: "canvas-b",
                webGL: "webgl-b"
            ),
            repeatCapture: FingerprintCapture(
                profileID: firstID,
                profileName: "First",
                identityCode: "NA-FIRST",
                capturedAt: Date(timeIntervalSince1970: 30),
                values: invalidValues
            )
        )

        #expect(report.validatedProfileFingerprintObservations().isEmpty)
    }

    @Test
    func incompleteWebRTCIsRejected() {
        let firstID = UUID()
        let first = capture(
            id: firstID,
            identityCode: "NA-FIRST",
            canvas: "canvas-a",
            webGL: "webgl-a"
        )
        var incompleteValues = first.values
        incompleteValues["webrtc_complete"] = "false"
        let incompleteRepeat = FingerprintCapture(
            profileID: firstID,
            profileName: "First",
            identityCode: first.identityCode,
            capturedAt: Date(timeIntervalSince1970: 30),
            values: incompleteValues
        )
        let report = makeReport(
            first: first,
            second: capture(
                id: UUID(),
                identityCode: "NA-SECOND",
                canvas: "canvas-b",
                webGL: "webgl-b"
            ),
            repeatCapture: incompleteRepeat
        )

        #expect(report.validatedProfileFingerprintObservations().isEmpty)
    }

    @Test
    func completePrivacyViolationMapsToBoundedFailure() {
        let firstID = UUID()
        let failedFirst = capture(
            id: firstID,
            identityCode: "NA-FIRST",
            route: "proxied",
            stunRequestCount: 1,
            canvas: "canvas-a",
            webGL: "webgl-a"
        )
        let failedRepeat = capture(
            id: firstID,
            identityCode: "NA-FIRST",
            capturedAt: Date(timeIntervalSince1970: 30),
            route: "proxied",
            stunRequestCount: 1,
            canvas: "canvas-a",
            webGL: "webgl-a"
        )
        let report = makeReport(
            first: failedFirst,
            second: capture(
                id: UUID(),
                identityCode: "NA-SECOND",
                route: "proxied",
                canvas: "canvas-b",
                webGL: "webgl-b"
            ),
            repeatCapture: failedRepeat
        )

        let observation =
            report.validatedProfileFingerprintObservations().first

        #expect(observation?.route == .proxied)
        #expect(observation?.webRTCLoopback == .failed)
    }

    @Test
    func manualReportDeliveryGateDeliversEachIDOnce() {
        var gate = ManualFingerprintReportDeliveryGate()
        let firstID = UUID()
        let secondID = UUID()

        let rejectedNil = gate.shouldDeliver(
            reportID: nil,
            isReleaseAudit: false
        )
        let deliveredFirst = gate.shouldDeliver(
            reportID: firstID,
            isReleaseAudit: false
        )
        let rejectedDuplicate = gate.shouldDeliver(
            reportID: firstID,
            isReleaseAudit: false
        )
        let deliveredSecond = gate.shouldDeliver(
            reportID: secondID,
            isReleaseAudit: false
        )
        let rejectedRelease = gate.shouldDeliver(
            reportID: UUID(),
            isReleaseAudit: true
        )

        #expect(!rejectedNil)
        #expect(deliveredFirst)
        #expect(!rejectedDuplicate)
        #expect(deliveredSecond)
        #expect(!rejectedRelease)
        #expect(gate.lastDeliveredReportID == secondID)
    }

    @Test
    func reportCannotBindToIdentityChangedWhileAuditWasRunning() {
        let first = BrowserProfile(
            name: "First",
            identity: BrowserIdentity(seed: 101)
        )
        let second = BrowserProfile(
            name: "Second",
            identity: BrowserIdentity(seed: 202)
        )
        let changedFirst = BrowserProfile(
            id: first.id,
            name: first.name,
            identity: BrowserIdentity(seed: 303)
        )
        let report = makeReport(
            first: capture(
                id: first.id,
                identityCode: first.identity.displayCode,
                canvas: "canvas-a",
                webGL: "webgl-a"
            ),
            second: capture(
                id: second.id,
                identityCode: second.identity.displayCode,
                canvas: "canvas-b",
                webGL: "webgl-b"
            ),
            repeatCapture: capture(
                id: first.id,
                identityCode: first.identity.displayCode,
                capturedAt: Date(timeIntervalSince1970: 30),
                canvas: "canvas-a",
                webGL: "webgl-a"
            )
        )
        let runtime = BrowserRuntime(
            name: "Test runtime",
            executableURL: URL(fileURLWithPath: "/tmp/NeAntik Browser"),
            source: "Test",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "151",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )

        let stable = report.revisionBoundFingerprintObservations(
            auditedProfiles: [first, second],
            currentProfiles: [first, second],
            runtime: runtime
        )
        let changed = report.revisionBoundFingerprintObservations(
            auditedProfiles: [first, second],
            currentProfiles: [changedFirst, second],
            runtime: runtime
        )

        #expect(stable.count == 1)
        #expect(stable.first?.configurationRevision != nil)
        #expect(changed.isEmpty)
    }

    @Test
    func auditRequestKeepsProxyRevisionCapturedBeforeSheetUpdates() {
        let identity = BrowserIdentity(seed: 404)
        let original = BrowserProfile(
            name: "First",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "old-proxy.example",
                port: 443,
                username: ""
            ),
            identity: identity
        )
        let second = BrowserProfile(
            name: "Second",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "second-proxy.example",
                port: 443,
                username: ""
            ),
            identity: BrowserIdentity(seed: 505)
        )
        let runtime = BrowserRuntime(
            name: "Test runtime",
            executableURL: URL(fileURLWithPath: "/tmp/NeAntik Browser"),
            source: "Test",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "151",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )
        let request = FingerprintAuditRequest(
            auditedProfiles: [original, second],
            initialFirstID: original.id,
            runtime: runtime
        )
        let changed = BrowserProfile(
            id: original.id,
            name: original.name,
            proxy: ProxyConfiguration(
                kind: .https,
                host: "new-proxy.example",
                port: 443,
                username: ""
            ),
            identity: identity
        )
        let report = makeReport(
            first: capture(
                id: original.id,
                identityCode: identity.displayCode,
                route: "proxied",
                canvas: "canvas-a",
                webGL: "webgl-a"
            ),
            second: capture(
                id: second.id,
                identityCode: second.identity.displayCode,
                route: "proxied",
                canvas: "canvas-b",
                webGL: "webgl-b"
            ),
            repeatCapture: capture(
                id: original.id,
                identityCode: identity.displayCode,
                capturedAt: Date(timeIntervalSince1970: 30),
                route: "proxied",
                canvas: "canvas-a",
                webGL: "webgl-a"
            )
        )

        let observations = report.revisionBoundFingerprintObservations(
            auditedProfiles: request.auditedProfiles,
            currentProfiles: [changed, second],
            runtime: request.runtime
        )

        #expect(
            request.auditedProfiles.first?.proxy?.host ==
                "old-proxy.example"
        )
        #expect(observations.isEmpty)
    }

    private func makeReport(
        first: FingerprintCapture,
        second: FingerprintCapture,
        repeatCapture: FingerprintCapture
    ) -> FingerprintAuditReport {
        FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 40),
            runtimeName: "Test runtime",
            runtimeVersion: "1",
            runtimeFlavor: .fingerprintChromium,
            executionMode: .browser,
            webrtcDirectControl: capture(
                id: first.profileID,
                identityCode: first.identityCode,
                capturedAt: Date(timeIntervalSince1970: 1),
                canvas: "control-canvas",
                webGL: "control-webgl"
            ),
            firstInitial: first,
            second: second,
            firstRepeat: repeatCapture
        )
    }

    private func capture(
        id: UUID,
        identityCode: String,
        capturedAt: Date = Date(timeIntervalSince1970: 10),
        route: String = "direct",
        stunRequestCount: Int? = nil,
        canvas: String,
        webGL: String
    ) -> FingerprintCapture {
        FingerprintCapture(
            profileID: id,
            profileName: "Profile",
            identityCode: identityCode,
            capturedAt: capturedAt,
            values: networkValues(
                route: route,
                stunRequestCount: stunRequestCount,
                canvas: canvas,
                webGL: webGL
            )
        )
    }

    private func networkValues(
        route: String,
        stunRequestCount: Int? = nil,
        canvas: String,
        webGL: String
    ) -> [String: String] {
        let requests = stunRequestCount ?? (route == "direct" ? 1 : 0)
        return [
            "canvas": canvas,
            "webgl_pixels": webGL,
            "audio": "audio",
            "client_rects": "rects",
            "network_route": route,
            "webrtc_probe": "loopback-stun-v1",
            "webrtc_complete": "true",
            "webrtc_stun_requests": String(requests),
            "webrtc_candidate_summary":
                #"{"total":0,"host":0,"srflx":0,"prflx":0,"relay":0,"unknown":0}"#
        ]
    }
}
