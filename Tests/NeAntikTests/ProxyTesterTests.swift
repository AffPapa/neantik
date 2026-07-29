import Foundation
import Testing
@testable import NeAntik

struct ProxyTesterTests {
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
}
