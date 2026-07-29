import Foundation
import Testing
@testable import NeAntik

struct ProxyTesterTests {
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
    func rejectsFailedLocationResponse() {
        let data = Data(
            """
            {"error": true, "reason": "Rate limit exceeded"}
            """.utf8
        )

        #expect(throws: NeAntikError.self) {
            try ProxyTester.parseResponse(data)
        }
    }

    @Test
    func ignoresInvalidTimezoneAndLocaleHints() throws {
        let data = Data(
            """
            {
              "ip": "203.0.113.12",
              "timezone": "../../invalid",
              "languages": "en-US-extra"
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
