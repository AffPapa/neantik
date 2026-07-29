import Foundation
import JavaScriptCore
import Testing
@testable import NeAntik

struct FingerprintAuditTests {
    @Test
    func safeDiagnosticSummaryUsesOnlyAllowlistedProvenance() {
        let profileID = UUID()
        let secretProfileName = "PROFILE-NAME-MUST-NOT-LEAK"
        let secretIdentityCode = "NA-DEADBEEF"
        let secretSurfaceValue = "proxy-login:secret@example.test"
        let first = FingerprintCapture(
            profileID: profileID,
            profileName: secretProfileName,
            identityCode: secretIdentityCode,
            capturedAt: Date(timeIntervalSince1970: 1),
            values: [
                "canvas": secretSurfaceValue,
                "webgl_pixels": "webgl-a",
                "audio": "audio-a",
                "client_rects": "rects-a"
            ]
        )
        let second = FingerprintCapture(
            profileID: UUID(),
            profileName: "SECOND-PROFILE-MUST-NOT-LEAK",
            identityCode: "NA-CAFEBABE",
            capturedAt: Date(timeIntervalSince1970: 2),
            values: [
                "canvas": "canvas-b",
                "webgl_pixels": "webgl-b",
                "audio": "audio-a",
                "client_rects": "rects-a"
            ]
        )
        let executableHash = String(repeating: "a", count: 64)
        let frameworkHash = String(repeating: "b", count: 64)
        let report = FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 3),
            managerVersion: "0.3.12",
            managerBuild: "15",
            runtimeName: "NeAntik Browser",
            runtimeVersion: "150.0.7871.186",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            runtimeExecutableSHA256: executableHash,
            runtimeFrameworkSHA256: frameworkHash,
            firstInitial: first,
            second: second,
            firstRepeat: first
        )

        let summary = report.safeDiagnosticSummary

        #expect(summary.contains("Менеджер: 0.3.12 (15)"))
        #expect(
            summary.contains(
                "Движок: Chromium с разделением отпечатков · 150.0.7871.186"
            )
        )
        #expect(summary.contains(executableHash))
        #expect(summary.contains(frameworkHash))
        #expect(!summary.contains(secretProfileName))
        #expect(!summary.contains(secretIdentityCode))
        #expect(!summary.contains(secretSurfaceValue))
        #expect(!summary.contains(profileID.uuidString))
        #expect(!summary.contains(second.profileName))
        #expect(!summary.contains(second.identityCode))
    }

    @Test
    func safeDiagnosticSummaryRejectsMalformedMetadataAndHashes() {
        let first = capture(
            name: "First",
            values: baseValues(canvas: "canvas-a")
        )
        let result = FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            managerVersion: "0.4\nINJECTED",
            managerBuild: " ",
            runtimeName: "Ignored runtime name",
            runtimeVersion: "",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: false,
            runtimeExecutableSHA256: "NOT-A-HASH",
            runtimeFrameworkSHA256: nil,
            firstInitial: first,
            second: capture(
                name: "Second",
                values: baseValues(canvas: "canvas-b")
            ),
            firstRepeat: first
        )

        #expect(result.safeManagerVersionSummary == "0.4 INJECTED")
        #expect(result.safeRuntimeExecutableHashSummary == "не подтверждён")
        #expect(result.safeRuntimeFrameworkHashSummary == "не подтверждён")
        #expect(
            result.safeDiagnosticSummary.contains(
                "Подпись движка: Подпись не подтверждена"
            )
        )
        #expect(!result.safeDiagnosticSummary.contains("Ignored runtime name"))
    }

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
            "webrtc_candidate_summary",
            "loopback-stun-v1",
            "webrtc_complete",
            "stunPort",
            "audio_repeat",
            "canvas_repeat",
            "worker_canvas",
            "worker_webgl_pixels",
            "worker_client_hints",
            "css_screen_match",
            "webgl_shader_precision",
            "COMPILE_STATUS",
            "LINK_STATUS",
            "pixel readback failed"
        ] {
            #expect(expression.contains(marker))
        }
        #expect(!expression.contains("candidate.candidate"))
        #expect(!expression.contains("webrtc_candidates"))
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
    func crossRealmMismatchFailsStrictProductionButNotPublicAlpha() {
        var firstValues = productionValues(
            canvas: "canvas-a",
            webGLPixels: "webgl-a",
            renderer: "Apple M2"
        )
        firstValues["worker_platform"] = "Win32"
        let first = capture(name: "First", values: firstValues)
        let result = report(
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

        #expect(result.isPublicAlphaReleaseQualified)
        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.crossRealmConsistencyIssues.contains {
                $0.contains(
                    "platform value disagrees with worker_platform"
                )
            }
        )
    }

    @Test
    func repeatedOfflineAudioMismatchFailsStrictProduction() {
        var firstValues = productionValues(
            canvas: "canvas-a",
            webGLPixels: "webgl-a",
            renderer: "Apple M2"
        )
        firstValues["audio_repeat"] = "audio-random"
        let first = capture(name: "First", values: firstValues)
        let result = report(
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

        #expect(result.isPublicAlphaReleaseQualified)
        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.crossRealmConsistencyIssues.contains {
                $0.contains("audio value disagrees with audio_repeat")
            }
        )
    }

    @Test
    func proxiedRouteRejectsDirectWebRTCCandidate() {
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
        )
        var secondValues = productionValues(
            canvas: "canvas-b",
            webGLPixels: "webgl-b",
            renderer: "Apple M4"
        )
        secondValues["network_route"] = "proxied"
        secondValues["webrtc_stun_requests"] = "0"
        secondValues["webrtc_candidate_summary"] =
            #"{"total":1,"host":1,"srflx":0,"prflx":0,"relay":0,"unknown":0}"#
        let result = report(
            first: first,
            second: capture(name: "Second", values: secondValues),
            repeatCapture: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )

        #expect(result.isPublicAlphaReleaseQualified)
        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.networkPrivacyIssues.contains {
                $0.contains(
                    "proxied route exposed a direct WebRTC candidate"
                )
            }
        )
    }

    @Test
    func rejectsMalformedWebRTCCandidateSummary() {
        var firstValues = productionValues(
            canvas: "canvas-a",
            webGLPixels: "webgl-a",
            renderer: "Apple M2"
        )
        firstValues["webrtc_candidate_summary"] =
            #"{"total":1,"host":0,"srflx":0,"prflx":0,"relay":0,"unknown":0}"#
        let first = capture(name: "First", values: firstValues)
        let result = report(
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

        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.networkPrivacyIssues.contains {
                $0.contains("WebRTC candidate summary is invalid")
            }
        )
    }

    @Test
    func incompleteWebRTCGatheringFailsStrictProduction() {
        var firstValues = productionValues(
            canvas: "canvas-a",
            webGLPixels: "webgl-a",
            renderer: "Apple M2"
        )
        firstValues["webrtc_complete"] = "false"
        let first = capture(name: "First", values: firstValues)
        let result = report(
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

        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.networkPrivacyIssues.contains {
                $0.contains("WebRTC gathering did not complete")
            }
        )
    }

    @Test
    func proxiedRelayOnlyWebRTCCandidatePassesNetworkGate() {
        var secondValues = productionValues(
            canvas: "canvas-b",
            webGLPixels: "webgl-b",
            renderer: "Apple M4"
        )
        secondValues["network_route"] = "proxied"
        secondValues["webrtc_stun_requests"] = "0"
        secondValues["webrtc_candidate_summary"] =
            #"{"total":1,"host":0,"srflx":0,"prflx":0,"relay":1,"unknown":0}"#
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
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

        #expect(result.networkPrivacyIssues.isEmpty)
        #expect(result.isProductionReleaseQualified)
    }

    @Test
    func proxiedSTUNRequestFailsStrictProduction() {
        var secondValues = productionValues(
            canvas: "canvas-b",
            webGLPixels: "webgl-b",
            renderer: "Apple M4"
        )
        secondValues["network_route"] = "proxied"
        secondValues["webrtc_stun_requests"] = "1"
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
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

        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.networkPrivacyIssues.contains {
                $0.contains("proxied route sent a loopback STUN request")
            }
        )
    }

    @Test
    func legacyAuditSchemaCannotQualifyForStrictProduction() throws {
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
        )
        let current = report(
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
        let encoded = try JSONEncoder().encode(current)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "auditSchemaVersion")
        let data = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(
            FingerprintAuditReport.self,
            from: data
        )

        #expect(legacy.effectiveAuditSchemaVersion == 1)
        #expect(legacy.isPublicAlphaReleaseQualified)
        #expect(!legacy.isProductionReleaseQualified)
        #expect(
            legacy.productionReleaseIssues.contains(
                "The report does not use the current strict fingerprint audit schema."
            )
        )
    }

    @Test
    func identityCatalogDriftCannotQualifyForStrictProduction() {
        let first = capture(
            name: "First",
            values: productionValues(
                canvas: "canvas-a",
                webGLPixels: "webgl-a",
                renderer: "Apple M2"
            )
        )
        let result = FingerprintAuditReport(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            identityCatalogVersion: 2,
            runtimeName: "Test",
            runtimeVersion: "1",
            runtimeFlavor: .fingerprintChromium,
            runtimeCodeSignatureValid: true,
            runtimeExecutableSHA256: String(repeating: "a", count: 64),
            runtimeFrameworkSHA256: String(repeating: "b", count: 64),
            webrtcDirectControl: capture(
                name: "WebRTC control",
                identityCode: "NA-13579BDF",
                values: first.values
            ),
            firstInitial: first,
            second: capture(
                name: "Second",
                values: productionValues(
                    canvas: "canvas-b",
                    webGLPixels: "webgl-b",
                    renderer: "Apple M4"
                )
            ),
            firstRepeat: capture(
                id: first.profileID,
                name: first.profileName,
                values: first.values
            )
        )

        #expect(result.isPublicAlphaReleaseQualified)
        #expect(!result.isProductionReleaseQualified)
        #expect(
            result.productionReleaseIssues.contains(
                "The report does not use the current immutable identity catalog."
            )
        )
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
            webrtcDirectControl: capture(
                name: "WebRTC control",
                identityCode: "NA-13579BDF",
                values: firstValues
            ),
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
        secondValues["audio_repeat"] = "audio-b"
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
            "audio_repeat": "audio",
            "client_rects": "rects"
        ]
    }

    private func productionValues(
        canvas: String,
        webGLPixels: String,
        renderer: String
    ) -> [String: String] {
        let clientHints = "{\"platform\":\"macOS\"}"
        return [
            "canvas": canvas,
            "canvas_repeat": canvas,
            "webgl_pixels": webGLPixels,
            "webgl_pixels_repeat": webGLPixels,
            "audio": "audio",
            "audio_repeat": "audio",
            "client_rects": "rects",
            "client_rects_repeat": "rects",
            "webgl_vendor": "Google Inc. (Apple)",
            "webgl_renderer": renderer,
            "webgl_extensions": "extensions",
            "webgl_shader_precision": "precision",
            "webgpu_policy": "disabled",
            "user_agent": "Mozilla/5.0",
            "platform": "MacIntel",
            "client_hints": clientHints,
            "screen": "1512x982x1512x944x24x2",
            "css_screen_match": "width:1|height:1|resolution:1",
            "hardware_concurrency": "8",
            "device_memory": "8",
            "touch_points": "0",
            "fonts": "Arial,Menlo",
            "languages": "en-US,en",
            "timezone": "Europe/Berlin",
            "intl_locale": "en-US",
            "worker_canvas": canvas,
            "worker_webgl_pixels": webGLPixels,
            "worker_webgl_vendor": "Google Inc. (Apple)",
            "worker_webgl_renderer": renderer,
            "worker_webgl_extensions": "extensions",
            "worker_webgl_shader_precision": "precision",
            "worker_user_agent": "Mozilla/5.0",
            "worker_platform": "MacIntel",
            "worker_languages": "en-US,en",
            "worker_timezone": "Europe/Berlin",
            "worker_intl_locale": "en-US",
            "worker_hardware_concurrency": "8",
            "worker_client_hints": clientHints,
            "network_route": "direct",
            "webrtc_probe": "loopback-stun-v1",
            "webrtc_complete": "true",
            "webrtc_stun_requests": "1",
            "webrtc_candidate_summary":
                #"{"total":0,"host":0,"srflx":0,"prflx":0,"relay":0,"unknown":0}"#
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
        values["worker_user_agent"] = values["user_agent"]
        values["worker_client_hints"] = values["client_hints"]
        values["screen"] = screen
        values["hardware_concurrency"] = String(cores)
        values["worker_hardware_concurrency"] = String(cores)
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
            webrtcDirectControl: capture(
                name: "WebRTC control",
                values: first.values
            ),
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
