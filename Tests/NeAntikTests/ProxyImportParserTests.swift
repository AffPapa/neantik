import Foundation
import Testing
@testable import NeAntik

struct ProxyImportParserTests {
    @Test(
        "Поддерживаемые форматы прокси",
        arguments: [
            "user:secret@proxy.example:8080",
            "proxy.example:8080@user:secret",
            "user:secret:proxy.example:8080",
            "proxy.example:8080:user:secret",
        ]
    )
    func supportedFormats(value: String) throws {
        let draft = try ProxyImportParser.parse(value, kind: .https)

        #expect(draft.configuration.kind == .https)
        #expect(draft.configuration.host == "proxy.example")
        #expect(draft.configuration.port == 8080)
        #expect(draft.configuration.username == "user")
        #expect(draft.password == "secret")
    }

    @Test func directEndpointNeedsNoCredentials() throws {
        let draft = try ProxyImportParser.parse(
            "127.0.0.1:3128",
            kind: .http
        )
        #expect(draft.configuration.host == "127.0.0.1")
        #expect(draft.configuration.port == 3128)
        #expect(draft.configuration.username.isEmpty)
        #expect(draft.password.isEmpty)
    }

    @Test func bracketedIPv6IsSupported() throws {
        let draft = try ProxyImportParser.parse(
            "user:pass@[2001:db8::1]:1080",
            kind: .https
        )
        #expect(draft.configuration.host == "[2001:db8::1]")
        #expect(draft.configuration.displayEndpoint == "[2001:db8::1]:1080")
    }

    @Test func percentEncodedCredentialSeparatorsAreDecoded() throws {
        let draft = try ProxyImportParser.parse(
            "mail%40example.com:p%3Ass%25word@proxy.example:443",
            kind: .https
        )
        #expect(draft.configuration.username == "mail@example.com")
        #expect(draft.password == "p:ss%word")
    }

    @Test func passwordRetainsLegacyCharacterLimit() throws {
        let boundary = String(
            repeating: "a",
            count: ProxyImportParser.maximumPasswordLength
        )
        let draft = try ProxyImportParser.parse(
            "user:\(boundary)@proxy.example:443",
            kind: .https
        )
        #expect(draft.password == boundary)

        #expect(throws: ProxyImportError.invalid) {
            try ProxyImportParser.parse(
                "user:\(boundary)a@proxy.example:443",
                kind: .https
            )
        }
    }

    @Test func ambiguousColonFormatFailsClosed() {
        #expect(throws: ProxyImportError.ambiguous) {
            try ProxyImportParser.parse(
                "host:1234:user:5678",
                kind: .http
            )
        }
    }

    @Test func explicitOrderResolvesAmbiguousColonFormat() throws {
        let endpointLeft = try ProxyImportParser.parse(
            "host:1234:user:5678",
            kind: .http,
            order: .endpointFirst
        )
        #expect(endpointLeft.configuration.host == "host")
        #expect(endpointLeft.configuration.port == 1234)
        #expect(endpointLeft.configuration.username == "user")
        #expect(endpointLeft.password == "5678")

        let endpointRight = try ProxyImportParser.parse(
            "host:1234:user:5678",
            kind: .http,
            order: .credentialsFirst
        )
        #expect(endpointRight.configuration.host == "user")
        #expect(endpointRight.configuration.port == 5678)
        #expect(endpointRight.configuration.username == "host")
        #expect(endpointRight.password == "1234")
    }

    @Test func malformedOrUnsafeInputIsRejected() {
        for value in [
            "https://proxy.example:443",
            "user:bad%@proxy.example:443",
            "user:pass@proxy.example:0",
            "user:pass@proxy.example:65536",
            "user:pass@proxy.example:notaport",
            "user:pa\nss@proxy.example:443",
            "user:pass@proxy.example:443@extra",
            "2001:db8::1:443",
        ] {
            #expect(throws: (any Error).self) {
                try ProxyImportParser.parse(value, kind: .http)
            }
        }
    }

    @Test func socksCredentialsHaveClearFailure() {
        #expect(
            throws: ProxyImportError.socksAuthenticationUnsupported
        ) {
            try ProxyImportParser.parse(
                "user:secret@proxy.example:1080",
                kind: .socks5
            )
        }
    }

    @Test func summariesAndErrorsNeverRevealPassword() throws {
        let password = "unique-super-secret"
        let draft = try ProxyImportParser.parse(
            "user:\(password)@proxy.example:443",
            kind: .https
        )
        #expect(!draft.redactedSummary.contains(password))

        do {
            _ = try ProxyImportParser.parse(
                "user:\(password)@invalid host:443",
                kind: .https
            )
            Issue.record("Ожидалась ошибка")
        } catch {
            #expect(!error.localizedDescription.contains(password))
        }
    }
}
