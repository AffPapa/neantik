import Foundation
import Testing
@testable import NeAntik

struct ProxyTesterTests {
    @Test
    func connectRefusalIsNotMistakenForIPServiceFailure() async throws {
        let proxy = try ProxyImportParser.parse("127.0.0.1:8080", kind: .http).configuration
        for (status, connect, response, expected) in [
            (Int32(22), "502", "000", ProxyHealthOutcome.protocolFailed),
            (56, "502", "000", .protocolFailed),
            (22, "407", "000", .authenticationRejected),
            (56, "407", "000", .authenticationRejected),
            (22, "200", "429", .probeServiceFailed),
            (28, "200", "000", .timedOut)
        ] {
            do {
                _ = try await ProxyTester().probe(configuration: proxy, password: "", runProcess: { _, _, _, _ in
                    .init(status: status, output: Data("\nNEANTIK_METRICS_V2:0.001|\(connect)|\(response)\n".utf8), outputExceeded: false)
                })
                Issue.record("Controlled transport/service refusal succeeded")
            } catch let error as ProxyProbeError {
                #expect(error.outcome == expected)
            }
        }
    }

    private actor TunnelRefusalSequence {
        var count = 0
        let connectStatus: String
        init(_ status: String) { connectStatus = status }
        func next() -> ProxyProcessResult {
            count += 1
            if count == 1 {
                return .init(status: 56, output: Data("\nNEANTIK_METRICS_V2:0.001|\(connectStatus)|000\n".utf8), outputExceeded: false)
            }
            return .init(status: 0, output: Data("{\"ip\":\"203.0.113.12\"}\nNEANTIK_METRICS_V2:0.001|200|200\n".utf8), outputExceeded: false)
        }
    }

    @Test
    func refusedTunnelIsTerminalEvenIfAnotherServiceWouldSucceed() async throws {
        let proxy = try ProxyImportParser.parse("127.0.0.1:8080", kind: .http).configuration
        for (code, expected) in [("407", ProxyHealthOutcome.authenticationRejected), ("502", .protocolFailed)] {
            let sequence = TunnelRefusalSequence(code)
            do {
                _ = try await ProxyTester().probe(configuration: proxy, password: "", runProcess: { _, _, _, _ in await sequence.next() })
                Issue.record("Refused tunnel was overridden")
            } catch let error as ProxyProbeError {
                #expect(error.outcome == expected)
            }
            #expect(await sequence.count == 1)
        }
    }

    @Test
    func structuredMetricsRejectMalformedSuffixesAndSelectCurlSuffix() throws {
        for suffix in ["0.1|200", "nan|200|200", "-1|200|200", "0.1|+200|200", "0.1|20|200", "0.1|600|200", "0.1|200|999", "0.1|200|200|extra"] {
            #expect(throws: (any Error).self) {
                _ = try ProxyTester.parseProbeOutput(Data("{\"ip\":\"203.0.113.12\"}\nNEANTIK_METRICS_V2:\(suffix)\n".utf8))
            }
        }
        let body = "{\"ip\":\"203.0.113.12\",\"city\":\"NEANTIK_METRICS_V2: forged\"}"
        let parsed = try ProxyTester.parseProbeOutput(Data("\(body)\nNEANTIK_METRICS_V2:0.125|000|200\n".utf8))
        #expect(parsed.responseTimeMilliseconds == 125)
        #expect(parsed.result.ipAddress == "203.0.113.12")
    }

    @Test
    func structuredRouteMetricsPreserveBodyAndTiming() throws {
        let output = Data("{\"ip\":\"203.0.113.12\"}\nNEANTIK_METRICS_V2:0.125|200|200\n".utf8)
        let parsed = try ProxyTester.parseProbeOutput(output)
        #expect(parsed.result.ipAddress == "203.0.113.12")
        #expect(parsed.responseTimeMilliseconds == 125)
    }

    @Test
    func contradictorySuccessfulProcessCannotPublishProxySuccess() async throws {
        let proxy = try ProxyImportParser.parse("127.0.0.1:8080", kind: .http).configuration
        for metrics in ["0.001|502|200", "0.001|200|503", "0.001|200|000"] {
            do {
                _ = try await ProxyTester().probe(configuration: proxy, password: "", runProcess: { _, _, _, _ in
                    .init(status: 0, output: Data("{\"success\":true,\"ip\":\"203.0.113.12\",\"country_code\":\"DE\",\"timezone\":{\"id\":\"Europe/Berlin\"}}\nNEANTIK_METRICS_V2:\(metrics)\n".utf8), outputExceeded: false)
                })
                Issue.record("Contradictory process result published success")
            } catch let error as ProxyProbeError {
                #expect(error.outcome == .invalidResponse)
            }
        }
    }

    private actor ProbeSequence {
        var count = 0
        func next() -> ProxyProcessResult {
            count += 1
            if count == 1 { return .init(status: 0, output: Data("broken\nNEANTIK_METRICS_V1:0.01\n".utf8), outputExceeded: false) }
            if count == 2 { return .init(status: 22, output: Data(), outputExceeded: false) }
            return .init(status: 0, output: Data("{\"ip\":\"203.0.113.12\",\"timezone\":\"Europe/Berlin\",\"languages\":\"de-DE\"}\nNEANTIK_METRICS_V1:0.01\n".utf8), outputExceeded: false)
        }
    }

    @Test
    func malformedEvidenceIsNotOverriddenByLaterService429AndFallback() async throws {
        let sequence = ProbeSequence()
        let proxy = try ProxyImportParser.parse("127.0.0.1:8080", kind: .http).configuration
        do {
            _ = try await ProxyTester().probe(configuration: proxy, password: "", runProcess: { _, _, _, _ in await sequence.next() })
            Issue.record("Malformed evidence must not be replaced with a success")
        } catch let error as ProxyProbeError {
            #expect(error.outcome == .invalidResponse)
        }
        #expect(await sequence.count == 1)
    }

    @Test
    func largeConfigurationIsConsumedWithoutBlockingCaller() async throws {
        let payload = Data(repeating: 0x78, count: 128 * 1024)
        let result = try await ProxyTester.runCancellableProcess(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            standardInput: payload, maximumOutputBytes: payload.count)
        #expect(result.output == payload)
        #expect(!result.outputExceeded)
    }

    @Test
    func cancellationUnblocksLargeInputToNonreadingChild() async {
        let started = Date()
        let task = Task {
            try await ProxyTester.runCancellableProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                standardInput: Data(repeating: 0x78, count: 128 * 1024))
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled input writer succeeded") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error") }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test
    func passwordCompatibilityEnvelopeIsBoundedByUTF8Bytes() {
        func singleGrapheme(atUTF8Boundary byteCount: Int) -> String {
            "a\u{1AB0}" + String(
                repeating: "\u{301}",
                count: (byteCount - 4) / 2
            )
        }

        let family = "👨‍👩‍👧‍👦"
        let legacyBoundary = String(
            repeating: family,
            count: ProxyImportParser.maximumPasswordLength
        )
        let overCharacterBoundary = legacyBoundary + family
        let byteBoundary = singleGrapheme(
            atUTF8Boundary: ProxyImportParser.maximumPasswordBytes
        )
        let overByteBoundary = byteBoundary + "\u{301}"
        let pathological =
            "a" + String(repeating: "\u{301}", count: 1_100_000)

        #expect(legacyBoundary.utf8.count == 102_400)
        #expect(ProxyTester.isValidPassword(legacyBoundary))
        #expect(!ProxyTester.isValidPassword(overCharacterBoundary))
        #expect(byteBoundary.count == 1)
        #expect(ProxyTester.isValidPassword(byteBoundary))
        #expect(!ProxyTester.isValidPassword(overByteBoundary))
        #expect(pathological.count == 1)
        #expect(pathological.utf8.count > 2 * 1_024 * 1_024)
        #expect(!ProxyTester.isValidPassword(pathological))
        #expect(!ProxyTester.isValidPassword("secret\0tail"))
    }

    @Test
    func parsesProbeMetricsAfterUntrustedBody() throws {
        let data = Data(
            """
            {"ip":"203.0.113.12","city":"NEANTIK_METRICS_V1:999.0"}
            NEANTIK_METRICS_V1:0.482000
            """.utf8
        )

        let parsed = try ProxyTester.parseProbeOutput(data)

        #expect(parsed.result.ipAddress == "203.0.113.12")
        #expect(parsed.responseTimeMilliseconds == 482)
    }

    @Test
    func rejectsMissingOrInvalidProbeMetrics() {
        for suffix in [
            "",
            "\nNEANTIK_METRICS_V1:not-a-number\n",
            "\nNEANTIK_METRICS_V1:-1\n",
            "\nNEANTIK_METRICS_V1:121\n"
        ] {
            #expect(throws: NeAntikError.self) {
                try ProxyTester.parseProbeOutput(
                    Data(("{\"ip\":\"203.0.113.12\"}" + suffix).utf8)
                )
            }
        }
    }

    @Test
    func curlStatusesMapToSanitizedCategories() {
        #expect(ProxyTester.outcome(forCurlStatus: 5) == .nameResolutionFailed)
        #expect(ProxyTester.outcome(forCurlStatus: 28) == .timedOut)
        #expect(ProxyTester.outcome(forCurlStatus: 67) == .authenticationRejected)
        #expect(
            ProxyTester.outcome(forCurlStatus: 60) ==
                .transportSecurityFailed
        )
        #expect(ProxyTester.outcome(forCurlStatus: 97) == .protocolFailed)
        #expect(ProxyTester.outcome(forCurlStatus: 56) == .protocolFailed)
        #expect(ProxyTester.outcome(forCurlStatus: 22) == .probeServiceFailed)
        #expect(
            ProxyHealthOutcome.probeServiceFailed.userSummary.contains(
                "ограничил запросы"
            )
        )
        #expect(ProxyHealthOutcome.protocolFailed.userSummary.contains("тип и порт"))
        #expect(ProxyHealthOutcome.protocolFailed.userSummary.contains("причина пока не определена"))
        #expect(ProxyHealthOutcome.transportSecurityFailed.userSummary.contains("TLS"))
    }

    @Test
    func cancellationTerminatesProxyTestProcessPromptly() async {
        let startedAt = Date()
        let task = Task {
            try await ProxyTester.runCancellableProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                standardInput: Data()
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Cancelled proxy process unexpectedly succeeded.")
        } catch is CancellationError {
            // Expected: cancellation must reach and terminate the subprocess.
        } catch {
            Issue.record(
                "Cancelled proxy process returned the wrong error: \(error)"
            )
        }
        #expect(Date().timeIntervalSince(startedAt) < 2)
    }

    @Test
    func oversizedProcessOutputIsDrainedAndStoppedPromptly() async throws {
        let startedAt = Date()
        let result = try await ProxyTester.runCancellableProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            standardInput: Data(),
            maximumOutputBytes: 1_024
        )

        #expect(result.outputExceeded)
        #expect(result.output.count == 1_025)
        #expect(Date().timeIntervalSince(startedAt) < 2)
    }

    @Test
    func finiteProcessOutputPreservesTailAndBoundary() async throws {
        for (value, limit, exceeded) in [
            ("short-valid-tail", 1_024, false),
            (String(repeating: "x", count: 1_024), 1_024, false),
            (String(repeating: "x", count: 1_025), 1_024, true)
        ] {
            let result = try await ProxyTester.runCancellableProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [value],
                standardInput: Data(),
                maximumOutputBytes: limit
            )

            #expect(result.output == Data(value.utf8))
            #expect(result.outputExceeded == exceeded)
        }
    }

    @Test
    func curlConfigEscapingPreservesSupportedSpecialCharacters() {
        #expect(
            ProxyTester.escaped("u\\\"ser\tpass\nline\rnext\u{000B}v") ==
                "u\\\\\\\"ser\\tpass\\nline\\rnext\\vv"
        )
    }

    @Test
    func proxyTestCannotUseCurlConfigOrNoProxyBypass() {
        let arguments = ProxyTester.curlArguments
        let noProxyIndex = arguments.firstIndex(of: "--noproxy")

        #expect(arguments.first == "--disable")
        #expect(noProxyIndex != nil)
        if let noProxyIndex {
            #expect(arguments.indices.contains(noProxyIndex + 1))
            #expect(arguments[noProxyIndex + 1].isEmpty)
        }
        #expect(
            arguments.suffix(1) ==
                ["https://ipapi.co/json/"]
        )
    }

    @Test
    func parsesProxyLocationIdentity() throws {
        let data = Data(
            """
            {
              "ip": "203.0.113.12",
              "city": "Berlin",
              "country_name": "Germany",
              "country_code": "DE",
              "timezone": "Europe/Berlin",
              "languages": "de-DE,en"
            }
            """.utf8
        )

        let result = try ProxyTester.parseResponse(data)

        #expect(result.ipAddress == "203.0.113.12")
        #expect(result.locationSummary == "Berlin, Germany")
        #expect(result.countryCode == "DE")
        #expect(result.timezoneIdentifier == "Europe/Berlin")
        #expect(result.localeIdentifier == "de-DE")
    }

    @Test
    func crossCheckedServicesRequireMatchingExitAndCountry() throws {
        let first = Data(
            """
            {"success":true,"ip":"203.0.113.12","country_code":"DE",\
            "country":"Germany","city":"Berlin",\
            "timezone":{"id":"Europe/Berlin"}}
            """.utf8
        )
        let second = Data(
            """
            {"ipAddress":"203.0.113.12","countryCode":"DE",\
            "timeZones":["Europe/Berlin"],"languages":["de","en"]}
            """.utf8
        )
        let result = try ProxyTester.parseCrossCheckedResponses(
            ipWhois: first,
            freeIPAPI: second
        )
        #expect(result.ipAddress == "203.0.113.12")
        #expect(result.timezoneIdentifier == "Europe/Berlin")
        #expect(result.localeIdentifier == "de")

        for conflicting in [
            """
            {"ipAddress":"203.0.113.13","countryCode":"DE",\
            "timeZones":["Europe/Berlin"],"languages":["de"]}
            """,
            """
            {"ipAddress":"203.0.113.12","countryCode":"US",\
            "timeZones":["Europe/Berlin"],"languages":["de"]}
            """,
            """
            {"ipAddress":"203.0.113.12","countryCode":"DE",\
            "timeZones":["Europe/Berlin"],"languages":[]}
            """,
            """
            {"ipAddress":"203.0.113.12","countryCode":"DE",\
            "timeZones":["Europe/Paris"],"languages":["de"]}
            """
        ] {
            #expect(throws: NeAntikError.self) {
                try ProxyTester.parseCrossCheckedResponses(
                    ipWhois: first,
                    freeIPAPI: Data(conflicting.utf8)
                )
            }
        }
    }

    @Test
    func crossCheckedEvidenceHasOwnSourceAndFreshness() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let evidence = ProxyContextEvidence.from(
            .crossChecked,
            observedAt: observedAt
        )
        #expect(evidence.source == "ipwho.is+freeipapi.com")
        #expect(evidence.isValid)
        #expect(evidence.isFresh(relativeTo: observedAt))
    }

    @Test
    func rejectsExplicitFailureEvenWithCompleteContext() {
        let data = Data("{\"error\":true,\"ip\":\"203.0.113.12\",\"timezone\":\"Europe/Berlin\",\"languages\":\"de-DE\"}".utf8)
        #expect(throws: (any Error).self) { try ProxyTester.parseResponse(data) }
    }

    @Test
    func rejectsFailedLocationResponse() {
        let data = Data(
            """
            {"error": true, "reason": "UNTRUSTED_REMOTE_MARKER"}
            """.utf8
        )

        do {
            _ = try ProxyTester.parseResponse(data)
            Issue.record("Remote error payload unexpectedly succeeded.")
        } catch {
            #expect(
                error.localizedDescription.contains(
                    "IP-сервис вернул некорректный ответ."
                )
            )
            #expect(
                !error.localizedDescription.contains(
                    "UNTRUSTED_REMOTE_MARKER"
                )
            )
        }
    }

    @Test
    func acceptsLiteralIPv4AndIPv6Only() throws {
        for ipAddress in ["203.0.113.12", "2001:db8::1"] {
            let data = try JSONSerialization.data(
                withJSONObject: ["ip": ipAddress]
            )
            #expect(
                try ProxyTester.parseResponse(data).ipAddress == ipAddress
            )
        }
    }

    @Test
    func rejectsNonLiteralOrDecoratedIPAddress() throws {
        for value in [
            "UNTRUSTED_REMOTE_MARKER",
            "proxy.example",
            " 203.0.113.12",
            "203.0.113.12 ",
            "203.0.113.12\n",
            "fe80::1%en0"
        ] {
            let data = try JSONSerialization.data(
                withJSONObject: ["ip": value]
            )
            #expect(throws: NeAntikError.self) {
                try ProxyTester.parseResponse(data)
            }
        }
    }

    @Test
    func rejectsOversizedOrMalformedResponseGenerically() {
        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: ProxyTester.maximumResponseBytes + 1
        )
        for data in [oversized, Data("{malformed".utf8)] {
            do {
                _ = try ProxyTester.parseResponse(data)
                Issue.record("Invalid response unexpectedly succeeded.")
            } catch {
                #expect(
                    error.localizedDescription.contains(
                        "IP-сервис вернул некорректный ответ."
                    )
                )
                #expect(!error.localizedDescription.contains("{malformed"))
            }
        }
    }

    @Test
    func unsafeLocationLabelsAreNotReflected() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "ip": "203.0.113.12",
                "city": "Berlin\nUNTRUSTED_REMOTE_MARKER",
                "country_name": String(repeating: "x", count: 129),
                "country_code": " DE "
            ]
        )

        let result = try ProxyTester.parseResponse(data)

        #expect(result.city == nil)
        #expect(result.countryName == nil)
        #expect(result.countryCode == "DE")
    }

    @Test
    func ignoresInvalidTimezoneAndLocaleHints() throws {
        let data = Data(
            """
            {
              "ip": "203.0.113.12",
              "timezone": "../../invalid",
              "languages": "еn-US"
            }
            """.utf8
        )

        let result = try ProxyTester.parseResponse(data)

        #expect(result.timezoneIdentifier == nil)
        #expect(result.localeIdentifier == nil)
    }

    @Test
    func proxyContextEvidenceHasExplicitSourceAndFreshness() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let evidence = ProxyContextEvidence.ipAPI(observedAt: observedAt)

        #expect(evidence.source == "ipapi.co")
        #expect(
            evidence.isFresh(
                relativeTo: observedAt.addingTimeInterval(29 * 24 * 60 * 60)
            )
        )
        #expect(
            !evidence.isFresh(
                relativeTo: observedAt.addingTimeInterval(31 * 24 * 60 * 60)
            )
        )
        #expect(
            !evidence.isFresh(
                relativeTo: observedAt.addingTimeInterval(-10 * 60)
            )
        )
    }

    @Test
    func identityRejectsUnknownProxyContextSource() {
        let evidence = ProxyContextEvidence(
            source: "untrusted.example",
            observedAt: Date()
        )
        let identity = BrowserIdentity(
            seed: 123,
            timezoneIdentifier: "Europe/Berlin",
            localeIdentifier: "de-DE",
            proxyContextEvidence: evidence
        )

        #expect(identity.proxyContextEvidence == nil)
        #expect(identity.timezoneIdentifier == "Europe/Berlin")
        #expect(identity.localeIdentifier == "de-DE")
    }

    @Test
    func legacyIdentityKeepsContextWithoutInventingEvidence() throws {
        let data = Data(
            """
            {
              "seed": 123,
              "timezoneIdentifier": "Europe/Berlin",
              "localeIdentifier": "de-DE"
            }
            """.utf8
        )

        let identity = try JSONDecoder().decode(
            BrowserIdentity.self,
            from: data
        )

        #expect(identity.timezoneIdentifier == "Europe/Berlin")
        #expect(identity.localeIdentifier == "de-DE")
        #expect(identity.proxyContextEvidence == nil)
    }
}
