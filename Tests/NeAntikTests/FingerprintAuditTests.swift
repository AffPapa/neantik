import Foundation
import JavaScriptCore
import Testing
@testable import NeAntik

struct FingerprintAuditTests {
    @Test
    func verifiesStableDistinctCriticalSurfaces() {
        let first = capture(
            name: "First",
            values: [
                "canvas": "canvas-a",
                "webgl_pixels": "webgl-a",
                "audio": "audio-shared",
                "client_rects": "rects-shared",
                "platform": "MacIntel"
            ]
        )
        let second = capture(
            name: "Second",
            values: [
                "canvas": "canvas-b",
                "webgl_pixels": "webgl-b",
                "audio": "audio-shared",
                "client_rects": "rects-shared",
                "platform": "MacIntel"
            ]
        )
        let repeatCapture = capture(
            id: first.profileID,
            name: "First",
            values: first.values
        )

        let report = report(
            first: first,
            second: second,
            repeatCapture: repeatCapture
        )

        #expect(report.verdict == .verified)
        #expect(report.changedCriticalKeys == ["canvas", "webgl_pixels"])
        #expect(report.unstableCriticalKeys.isEmpty)
    }

    @Test
    func reportsLimitedSingleSurfaceSeparation() {
        let first = capture(
            name: "First",
            values: baseValues(canvas: "canvas-a")
        )
        let second = capture(
            name: "Second",
            values: baseValues(canvas: "canvas-b")
        )

        let result = report(
            first: first,
            second: second,
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )

        #expect(result.verdict == .partial)
        #expect(result.changedCriticalKeys == ["canvas"])
    }

    @Test
    func unavailableSurfaceCannotProveSeparation() {
        var secondValues = baseValues(canvas: "canvas-a")
        secondValues["webgl_pixels"] = "unavailable"
        let first = capture(
            name: "First",
            values: baseValues(canvas: "canvas-a")
        )

        let result = report(
            first: first,
            second: capture(name: "Second", values: secondValues),
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )

        #expect(result.verdict == .unchanged)
        #expect(result.changedCriticalKeys.isEmpty)
        #expect(result.unavailableCriticalKeys == ["webgl_pixels"])
    }

    @Test
    func rejectsUnstableIdentityEvenWhenProfilesDiffer() {
        let first = capture(
            name: "First",
            values: baseValues(canvas: "canvas-a")
        )
        let second = capture(
            name: "Second",
            values: baseValues(canvas: "canvas-b")
        )
        var repeatedValues = first.values
        repeatedValues["audio"] = "audio-random"

        let result = report(
            first: first,
            second: second,
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: repeatedValues
            )
        )

        #expect(result.verdict == .unstable)
        #expect(result.unstableCriticalKeys == ["audio"])
    }

    @Test
    func probeCoversCriticalAndContextSurfaces() {
        let expression = FingerprintAuditCoordinator.probeExpression

        for marker in [
            "canvas",
            "webgl_pixels",
            "audio",
            "client_rects",
            "webgl_renderer",
            "webgpu_policy",
            "client_hints",
            "webrtc_candidates",
            "COMPILE_STATUS",
            "LINK_STATUS",
            "pixel readback failed"
        ] {
            #expect(expression.contains(marker))
        }
    }

    @Test
    func probeIsValidJavaScript() throws {
        let context = try #require(JSContext())
        context.setObject(
            FingerprintAuditCoordinator.probeExpression,
            forKeyedSubscript: "neantikProbeSource" as NSString
        )
        context.evaluateScript(
            "new Function('return (' + neantikProbeSource + ')')"
        )

        #expect(context.exception == nil)
    }

    @Test
    func decodesChromiumDevToolsPageTargetURL() throws {
        let data = Data(
            """
            [
              {
                "type": "page",
                "webSocketDebuggerUrl":
                  "ws://127.0.0.1:9222/devtools/page/NEANTIK"
              }
            ]
            """.utf8
        )

        let url = try FingerprintAuditCoordinator
            .pageTargetWebSocketURL(from: data)

        #expect(
            url?.absoluteString ==
                "ws://127.0.0.1:9222/devtools/page/NEANTIK"
        )
    }

    @Test
    func savesPrivateDecodableReport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let first = capture(
            name: "First",
            values: baseValues(canvas: "a")
        )
        let savedReport = report(
            first: first,
            second: capture(
                name: "Second",
                values: baseValues(canvas: "b")
            ),
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )
        let url = try FingerprintAuditReportStore(
            paths: AppPaths(rootDirectory: root)
        ).save(savedReport)

        let decoded = try JSONDecoder.neAntikISO8601.decode(
            FingerprintAuditReport.self,
            from: Data(contentsOf: url)
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(decoded.id == savedReport.id)
        #expect(decoded.effectiveExecutionMode == .browser)
        #expect(permissions?.intValue == 0o600)
    }

    @Test
    func recordsDiagnosticExecutionModeWithoutChangingBrowserDefault() throws {
        let first = capture(
            name: "First",
            values: baseValues(canvas: "a")
        )
        let browserReport = report(
            first: first,
            second: capture(
                name: "Second",
                values: baseValues(canvas: "b")
            ),
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )
        let diagnosticReport = FingerprintAuditReport(
            id: browserReport.id,
            createdAt: browserReport.createdAt,
            runtimeName: browserReport.runtimeName,
            runtimeVersion: browserReport.runtimeVersion,
            runtimeFlavor: browserReport.runtimeFlavor,
            runtimeCodeSignatureValid:
                browserReport.runtimeCodeSignatureValid,
            runtimeExecutableSHA256:
                browserReport.runtimeExecutableSHA256,
            runtimeFrameworkSHA256:
                browserReport.runtimeFrameworkSHA256,
            executionMode: .headlessSingleProcessDiagnostic,
            firstInitial: browserReport.firstInitial,
            second: browserReport.second,
            firstRepeat: browserReport.firstRepeat
        )
        let data = try JSONEncoder().encode(diagnosticReport)
        let decoded = try JSONDecoder().decode(
            FingerprintAuditReport.self,
            from: data
        )

        #expect(browserReport.effectiveExecutionMode == .browser)
        #expect(browserReport.effectiveExecutionMode.isReleaseEvidence)
        #expect(
            decoded.effectiveExecutionMode ==
                .headlessSingleProcessDiagnostic
        )
        #expect(!decoded.effectiveExecutionMode.isReleaseEvidence)
        #expect(
            decoded.effectiveExecutionMode.additionalLaunchArguments ==
                ["--single-process", "--no-sandbox"]
        )
        #expect(
            FingerprintAuditExecutionMode.browser
                .additionalLaunchArguments.isEmpty
        )
    }

    @Test
    func qualifiesOnlyCompleteBrowserEvidence() {
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
        )
        let second = capture(
            name: "Second",
            values: productionValues(
                canvas: "canvas-b",
                webGLPixels: "webgl-b",
                renderer: "Apple M4"
            )
        )
        let result = report(
            first: first,
            second: second,
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )

        #expect(result.verdict == .verified)
        #expect(result.productionUnavailableKeys.isEmpty)
        #expect(result.productionUnstableKeys.isEmpty)
        #expect(result.productionReleaseIssues.isEmpty)
        #expect(result.isProductionReleaseQualified)
    }

    @Test
    func validatesCoherentAppleDeviceTuplesForPinnedRuntime() {
        let firstValues = coherentTupleValues(
            canvas: "canvas-a",
            webGLPixels: "webgl-a",
            gpu: "M2 Pro",
            cores: 12,
            screen: "1512x982x1512x957x24x2",
            platformVersion: "15.3.1"
        )
        let secondValues = coherentTupleValues(
            canvas: "canvas-b",
            webGLPixels: "webgl-b",
            gpu: "M4",
            cores: 10,
            screen: "1280x832x1280x807x24x2",
            platformVersion: "15.1.0"
        )
        let first = capture(
            name: "First",
            identityCode: "NA-13579BDF",
            values: firstValues
        )
        let result = FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            runtimeName: "NeAntik Browser",
            runtimeVersion: "144.0.7559.132",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            runtimeExecutableSHA256: String(repeating: "a", count: 64),
            runtimeFrameworkSHA256: String(repeating: "b", count: 64),
            firstInitial: first,
            second: capture(
                name: "Second",
                identityCode: "NA-2468ACE0",
                values: secondValues
            ),
            firstRepeat: capture(
                id: first.profileID,
                name: first.profileName,
                identityCode: first.identityCode,
                values: first.values
            )
        )

        #expect(result.deviceTupleConsistencyIssues.isEmpty)
        #expect(result.isProductionReleaseQualified)
    }

    @Test
    func validatesCoherentAppleDeviceTuplesForFutureRuntime() {
        let runtimeVersion = "150.0.7871.186"
        let firstValues = coherentTupleValues(
            canvas: "canvas-a",
            webGLPixels: "webgl-a",
            gpu: "M2 Pro",
            cores: 12,
            screen: "1512x982x1512x957x24x2",
            platformVersion: "15.3.1",
            runtimeVersion: runtimeVersion
        )
        var secondValues = coherentTupleValues(
            canvas: "canvas-b",
            webGLPixels: "webgl-b",
            gpu: "M4",
            cores: 10,
            screen: "1280x832x1280x807x24x2",
            platformVersion: "15.1.0",
            runtimeVersion: runtimeVersion
        )
        secondValues["client_hints"] = """
        {"architecture":"arm","bitness":"64","platform":"macOS","platformVersion":"15.1.0","uaFullVersion":"144.0.7559.132"}
        """
        let first = capture(
            name: "First",
            identityCode: "NA-13579BDF",
            values: firstValues
        )
        let result = FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            runtimeName: "NeAntik Browser",
            runtimeVersion: runtimeVersion,
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            runtimeExecutableSHA256: String(repeating: "a", count: 64),
            runtimeFrameworkSHA256: String(repeating: "b", count: 64),
            firstInitial: first,
            second: capture(
                name: "Second",
                identityCode: "NA-2468ACE0",
                values: secondValues
            ),
            firstRepeat: capture(
                id: first.profileID,
                name: first.profileName,
                identityCode: first.identityCode,
                values: first.values
            )
        )

        #expect(
            result.deviceTupleConsistencyIssues.contains {
                $0.contains("Client Hints uaFullVersion")
            }
        )
        #expect(!result.isProductionReleaseQualified)
    }

    @Test
    func rejectsCrossFieldAppleDeviceTupleMismatch() {
        var values = coherentTupleValues(
            canvas: "canvas-a",
            webGLPixels: "webgl-a",
            gpu: "M2 Pro",
            cores: 12,
            screen: "1512x982x1512x957x24x2",
            platformVersion: "15.3.1"
        )
        values["hardware_concurrency"] = "10"
        let first = capture(
            name: "First",
            identityCode: "NA-13579BDF",
            values: values
        )
        let result = FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            runtimeName: "NeAntik Browser",
            runtimeVersion: "144.0.7559.132",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            runtimeExecutableSHA256: String(repeating: "a", count: 64),
            runtimeFrameworkSHA256: String(repeating: "b", count: 64),
            firstInitial: first,
            second: capture(
                name: "Second",
                identityCode: "NA-2468ACE0",
                values: coherentTupleValues(
                    canvas: "canvas-b",
                    webGLPixels: "webgl-b",
                    gpu: "M4",
                    cores: 10,
                    screen: "1280x832x1280x807x24x2",
                    platformVersion: "15.1.0"
                )
            ),
            firstRepeat: capture(
                id: first.profileID,
                name: first.profileName,
                identityCode: first.identityCode,
                values: first.values
            )
        )

        #expect(!result.deviceTupleConsistencyIssues.isEmpty)
        #expect(!result.isProductionReleaseQualified)
    }

    @Test
    func verifiedWithoutWebGLIsNotProductionQualified() {
        var firstValues = productionValues(
            canvas: "canvas-a",
            webGLPixels: "webgl-a",
            renderer: "Apple M2"
        )
        var secondValues = productionValues(
            canvas: "canvas-b",
            webGLPixels: "webgl-b",
            renderer: "Apple M4"
        )
        firstValues["webgl_pixels"] = "unavailable"
        firstValues["webgl_vendor"] = "unavailable"
        firstValues["webgl_renderer"] = "unavailable"
        secondValues["webgl_pixels"] = "unavailable"
        secondValues["webgl_vendor"] = "unavailable"
        secondValues["webgl_renderer"] = "unavailable"
        secondValues["audio"] = "audio-b"
        let first = capture(name: "First", values: firstValues)
        let result = report(
            first: first,
            second: capture(name: "Second", values: secondValues),
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )

        #expect(result.verdict == .verified)
        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.productionUnavailableKeys == [
                "webgl_pixels",
                "webgl_vendor",
                "webgl_renderer"
            ]
        )
        #expect(
            result.productionReleaseIssues.contains {
                $0.contains("WebGL pixels did not differ")
            }
        )
    }

    @Test
    func diagnosticReportCanNeverQualifyForProduction() {
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
        )
        let browserReport = report(
            first: first,
            second: capture(
                name: "Second",
                values: productionValues(
                    canvas: "canvas-b",
                    webGLPixels: "webgl-b",
                    renderer: "Apple M4"
                )
            ),
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )
        let diagnostic = FingerprintAuditReport(
            id: browserReport.id,
            createdAt: browserReport.createdAt,
            runtimeName: browserReport.runtimeName,
            runtimeVersion: browserReport.runtimeVersion,
            runtimeFlavor: browserReport.runtimeFlavor,
            runtimeCodeSignatureValid:
                browserReport.runtimeCodeSignatureValid,
            runtimeExecutableSHA256:
                browserReport.runtimeExecutableSHA256,
            runtimeFrameworkSHA256:
                browserReport.runtimeFrameworkSHA256,
            executionMode: .headlessSingleProcessDiagnostic,
            firstInitial: browserReport.firstInitial,
            second: browserReport.second,
            firstRepeat: browserReport.firstRepeat
        )

        #expect(browserReport.isProductionReleaseQualified)
        #expect(!diagnostic.isProductionReleaseQualified)
        #expect(
            diagnostic.productionReleaseIssues.contains(
                "The report was captured in diagnostic mode."
            )
        )
    }

    @Test
    func decodesLegacyReportAsBrowserEvidence() throws {
        let first = capture(
            name: "First",
            values: baseValues(canvas: "a")
        )
        let savedReport = report(
            first: first,
            second: capture(
                name: "Second",
                values: baseValues(canvas: "b")
            ),
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )
        let encoded = try JSONEncoder().encode(savedReport)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "executionMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            FingerprintAuditReport.self,
            from: legacyData
        )

        #expect(decoded.executionMode == nil)
        #expect(decoded.effectiveExecutionMode == .browser)
        #expect(!decoded.isProductionReleaseQualified)
        #expect(
            decoded.productionReleaseIssues.contains(
                "The report does not explicitly record browser mode."
            )
        )
    }

    @Test
    func unstableContextCannotQualifyForProduction() {
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
        )
        let second = capture(
            name: "Second",
            values: productionValues(
                canvas: "canvas-b",
                webGLPixels: "webgl-b",
                renderer: "Apple M4"
            )
        )
        var repeatValues = first.values
        repeatValues["hardware_concurrency"] = "32"
        let result = report(
            first: first,
            second: second,
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: repeatValues
            )
        )

        #expect(result.verdict == .verified)
        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.productionUnstableKeys == ["hardware_concurrency"]
        )
    }

    @Test
    func invalidProfileSequenceCannotQualifyForProduction() {
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
        )
        let second = capture(
            id: first.profileID,
            name: "Second",
            values: productionValues(
                canvas: "canvas-b",
                webGLPixels: "webgl-b",
                renderer: "Apple M4"
            )
        )
        let result = report(
            first: first,
            second: second,
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )

        #expect(result.verdict == .verified)
        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.productionReleaseIssues.contains(
                "The report does not contain a valid A → B → A profile sequence."
            )
        )
    }

    @Test
    func unboundRuntimeBinaryCannotQualifyForProduction() {
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
        )
        let second = capture(
            name: "Second",
            values: productionValues(
                canvas: "canvas-b",
                webGLPixels: "webgl-b",
                renderer: "Apple M4"
            )
        )
        let result = FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            runtimeName: "Test",
            runtimeVersion: "1",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            firstInitial: first,
            second: second,
            firstRepeat: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )

        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.productionReleaseIssues.contains(
                "The report does not bind the runtime executable SHA-256."
            )
        )
        #expect(
            result.productionReleaseIssues.contains(
                "The report does not bind the runtime framework SHA-256."
            )
        )
    }

    private func baseValues(canvas: String) -> [String: String] {
        [
            "canvas": canvas,
            "webgl_pixels": "webgl",
            "audio": "audio",
            "client_rects": "rects"
        ]
    }

    private func productionValues(
        canvas: String,
        webGLPixels: String,
        renderer: String
    ) -> [String: String] {
        [
            "canvas": canvas,
            "webgl_pixels": webGLPixels,
            "audio": "audio",
            "client_rects": "rects",
            "webgl_vendor": "Google Inc. (Apple)",
            "webgl_renderer": renderer,
            "webgl_extensions": "extensions",
            "webgpu_policy": "disabled",
            "user_agent": "Mozilla/5.0",
            "platform": "MacIntel",
            "client_hints": "{\"platform\":\"macOS\"}",
            "screen": "1512x982x1512x944x24x2",
            "hardware_concurrency": "8",
            "device_memory": "8",
            "touch_points": "0",
            "fonts": "Arial,Menlo",
            "languages": "en-US,en",
            "timezone": "Europe/Berlin"
        ]
    }

    private func coherentTupleValues(
        canvas: String,
        webGLPixels: String,
        gpu: String,
        cores: Int,
        screen: String,
        platformVersion: String,
        runtimeVersion: String = "144.0.7559.132"
    ) -> [String: String] {
        var values = productionValues(
            canvas: canvas,
            webGLPixels: webGLPixels,
            renderer:
                "ANGLE (Apple, ANGLE Metal Renderer: Apple \(gpu), Unspecified Version)"
        )
        values["user_agent"] =
            "Mozilla/5.0 Chrome/\(runtimeVersion) Safari/537.36"
        values["client_hints"] = """
        {"architecture":"arm","bitness":"64","platform":"macOS","platformVersion":"\(platformVersion)","uaFullVersion":"\(runtimeVersion)"}
        """
        values["screen"] = screen
        values["hardware_concurrency"] = String(cores)
        return values
    }

    private func capture(
        id: UUID = UUID(),
        name: String,
        identityCode: String? = nil,
        values: [String: String]
    ) -> FingerprintCapture {
        FingerprintCapture(
            profileID: id,
            profileName: name,
            identityCode: identityCode ?? "NA-\(id.uuidString)",
            capturedAt: Date(timeIntervalSince1970: 1),
            values: values
        )
    }

    private func report(
        first: FingerprintCapture,
        second: FingerprintCapture,
        repeatCapture: FingerprintCapture
    ) -> FingerprintAuditReport {
        FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            runtimeName: "Test",
            runtimeVersion: "1",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            runtimeExecutableSHA256: String(repeating: "a", count: 64),
            runtimeFrameworkSHA256: String(repeating: "b", count: 64),
            firstInitial: first,
            second: second,
            firstRepeat: repeatCapture
        )
    }
}

private extension JSONDecoder {
    static var neAntikISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
