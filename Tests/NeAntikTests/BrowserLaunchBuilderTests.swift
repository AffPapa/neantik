import Foundation
import Testing
@testable import NeAntik

private final class RuntimeInspectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var inspectedPaths: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return inspectedPaths
    }

    func inspect(_ url: URL) -> BrowserRuntimeInspection {
        lock.lock()
        inspectedPaths.append(url.standardizedFileURL.path)
        lock.unlock()
        return BrowserRuntimeInspection(
            version: "150.0.7871.186",
            architectures: ["arm64"],
            codeSignatureValid: true
        )
    }
}

struct BrowserLaunchBuilderTests {
    private func testRuntimeLocator() -> BrowserRuntimeLocator {
        BrowserRuntimeLocator(
            runtimeInspector: { _ in
                BrowserRuntimeInspection(
                    version: "150.0.7871.186",
                    architectures: ["arm64"],
                    codeSignatureValid: true
                )
            },
            allowsExternalRuntimes: true
        )
    }

    @Test
    func createsIsolatedProfileArguments() {
        let profile = BrowserProfile(
            name: "Work",
            startURL: "example.com",
            proxy: ProxyConfiguration(
                kind: .socks5,
                host: "127.0.0.1",
                port: 1080,
                username: ""
            )
        )
        let directory = URL(fileURLWithPath: "/tmp/neantik-profile")

        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: directory
        )

        #expect(arguments.contains("--user-data-dir=/tmp/neantik-profile"))
        #expect(!arguments.contains("--disable-background-mode"))
        #expect(arguments.contains("--proxy-server=socks5://127.0.0.1:1080"))
        #expect(
            arguments.contains(
                "--webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
        )
        #expect(arguments.contains("--disable-quic"))
        #expect(!arguments.contains("--dns-prefetch-disable"))
        #expect(
            arguments.contains(
                "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"
            )
        )
        #expect(arguments.contains("--proxy-bypass-list=<-loopback>"))
        #expect(arguments.last == "https://example.com")
    }

    @Test
    func directProfileHasNoProxyButLimitsWebRTCToPublicInterface() {
        let profile = BrowserProfile(name: "Direct")
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/direct")
        )

        #expect(!arguments.contains { $0.hasPrefix("--proxy-server=") })
        #expect(arguments.filter { $0 == "--no-proxy-server" }.count == 1)
        #expect(!arguments.contains("--proxy-auto-detect"))
        #expect(!arguments.contains { $0.hasPrefix("--proxy-pac-url=") })
        #expect(
            arguments.contains(
                "--webrtc-ip-handling-policy=default_public_interface_only"
            )
        )
        #expect(!arguments.contains("--dns-prefetch-disable"))
        #expect(!arguments.contains("--disable-quic"))
        #expect(!arguments.contains { $0.hasPrefix("--host-resolver-rules=") })
        #expect(!arguments.contains { $0.hasPrefix("--fingerprint=") })
        #expect(!arguments.contains("--fingerprint-platform=macos"))
    }

    @Test
    func appendsAuditArgumentsBeforeInternalStartURL() {
        let profile = BrowserProfile(
            name: "Audit",
            startURL: "https://example.com"
        )
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/audit"),
            additionalArguments: ["--remote-debugging-port=0"],
            startURLOverride: URL(string: "about:blank")
        )

        #expect(arguments.contains("--remote-debugging-port=0"))
        #expect(arguments.last == "about:blank")
        #expect(
            arguments.firstIndex(of: "--remote-debugging-port=0")! <
                arguments.count - 1
        )
    }

    @Test
    func auditOnlyLoopbackBypassDoesNotWeakenNormalProxyLaunch() {
        let profile = BrowserProfile(
            name: "Proxy audit",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8080,
                username: ""
            )
        )
        let directory = URL(fileURLWithPath: "/tmp/proxy-audit")

        let normal = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: directory
        )
        let audit = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: directory,
            startURLOverride: URL(string: "http://127.0.0.1:32123/"),
            purpose: .fingerprintAudit(httpLoopbackPort: 32_123)
        )

        #expect(normal.contains("--proxy-bypass-list=<-loopback>"))
        #expect(
            !normal.contains(
                "--proxy-bypass-list=<-loopback>;http://127.0.0.1:32123"
            )
        )
        #expect(
            audit.contains(
                "--proxy-bypass-list=<-loopback>;http://127.0.0.1:32123"
            )
        )
        #expect(!audit.contains("--proxy-bypass-list=<-loopback>"))
        #expect(
            audit.contains(
                "--webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
        )
    }

    @Test
    func additionalArgumentsCannotOverrideIsolationOrFingerprintContract() {
        let profile = BrowserProfile(
            name: "Protected",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8080,
                username: ""
            ),
            identity: BrowserIdentity(seed: 123)
        )
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/protected"),
            runtimeCapabilities: .fingerprintIdentity,
            additionalArguments: [
                "--remote-debugging-port=0",
                "--user-data-dir=/tmp/evil",
                "--proxy-server=direct://",
                "--no-proxy-server",
                "--proxy-auto-detect",
                "--proxy-pac-url=https://attacker.example/proxy.pac",
                "--proxy-bypass-list=*",
                "--host-resolver-rules=MAP * 127.0.0.1",
                "--webrtc-ip-handling-policy=default",
                "--force-webrtc-ip-handling-policy=default",
                "--fingerprint=999",
                "--fingerprint-timezone=UTC",
                "--fingerprint-locale=ru-RU",
                "--fingerprinting-client-rects-noise",
                "--fingerprinting-canvas-measuretext-noise",
                "--fingerprinting-canvas-image-data-noise",
                "--timezone=UTC",
                "--lang=ru-RU",
                "--accept-lang=ru-RU",
                "--disable-features=Nothing",
                "--fingerprint",
                "--proxy-server",
                " --remote-debugging-address=0.0.0.0"
            ]
        )

        #expect(arguments.contains("--remote-debugging-port=0"))
        #expect(arguments.contains("--user-data-dir=/tmp/protected"))
        #expect(arguments.contains("--proxy-server=http://proxy.example:8080"))
        #expect(!arguments.contains("--no-proxy-server"))
        #expect(!arguments.contains("--proxy-auto-detect"))
        #expect(!arguments.contains { $0.hasPrefix("--proxy-pac-url=") })
        #expect(
            arguments.contains(
                "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE proxy.example"
            )
        )
        #expect(
            arguments.contains(
                "--webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
        )
        #expect(!arguments.contains { $0.hasPrefix("--fingerprint=") })
        #expect(arguments.contains("--fingerprinting-client-rects-noise"))
        #expect(arguments.contains("--fingerprinting-canvas-measuretext-noise"))
        #expect(arguments.contains("--fingerprinting-canvas-image-data-noise"))
        #expect(
            arguments.contains(
                "--disable-features=AsyncDns,DnsOverHttpsUpgrade,WebGPUService"
            )
        )
        #expect(!arguments.contains("--user-data-dir=/tmp/evil"))
        #expect(!arguments.contains("--proxy-server=direct://"))
        #expect(!arguments.contains("--proxy-bypass-list=*"))
        #expect(!arguments.contains("--host-resolver-rules=MAP * 127.0.0.1"))
        #expect(!arguments.contains("--webrtc-ip-handling-policy=default"))
        #expect(
            !arguments.contains(
                "--force-webrtc-ip-handling-policy=default"
            )
        )
        #expect(!arguments.contains("--fingerprint=999"))
        #expect(!arguments.contains("--fingerprint-timezone=UTC"))
        #expect(!arguments.contains("--fingerprint-locale=ru-RU"))
        #expect(!arguments.contains("--timezone=UTC"))
        #expect(!arguments.contains("--lang=ru-RU"))
        #expect(!arguments.contains("--accept-lang=ru-RU"))
        #expect(!arguments.contains("--disable-features=Nothing"))
        #expect(!arguments.contains("--fingerprint"))
        #expect(!arguments.contains("--proxy-server"))
        #expect(!arguments.contains(" --remote-debugging-address=0.0.0.0"))
    }

    @Test
    func proxyProfileCombinesFailClosedNetworkFeatures() {
        let profile = BrowserProfile(
            name: "Proxy privacy",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: ""
            ),
            identity: BrowserIdentity(seed: 123)
        )

        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/proxy-privacy"),
            runtimeCapabilities: .fingerprintIdentity
        )

        #expect(
            arguments.contains(
                "--disable-features=AsyncDns,DnsOverHttpsUpgrade,WebGPUService"
            )
        )
        #expect(
            arguments.contains(
                "--webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
        )
        #expect(!arguments.contains("--no-proxy-server"))
        #expect(!arguments.contains("--proxy-auto-detect"))
        #expect(!arguments.contains { $0.hasPrefix("--proxy-pac-url=") })
        #expect(
            !arguments.contains(
                "--webrtc-ip-handling-policy=default_public_interface_only"
            )
        )
        #expect(
            arguments.filter { $0.hasPrefix("--disable-features=") }.count == 1
        )
    }

    @Test
    func rejectsScriptStartURL() {
        #expect(
            BrowserLaunchBuilder
                .normalizedStartURL("javascript:alert(1)")
                .absoluteString == "https://www.google.com"
        )
    }

    @Test
    func compatibleRuntimeReceivesStableProfileIdentity() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = BrowserProfile(
            name: "Private",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 443,
                username: ""
            ),
            identity: BrowserIdentity(
                seed: 123_456_789,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE",
                proxyContextEvidence: .ipAPI(observedAt: observedAt)
            )
        )

        let firstLaunch = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/private"),
            runtimeCapabilities: .fingerprintIdentity,
            now: observedAt
        )
        let secondLaunch = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/private"),
            runtimeCapabilities: .fingerprintIdentity,
            now: observedAt.addingTimeInterval(60)
        )
        let environment = BrowserLaunchBuilder.environment(
            profile: profile,
            runtimeCapabilities: .fingerprintIdentity,
            inherited: [
                "HOME": "/Users/test",
                "SAFE_PARENT": "1",
                "HTTP_PROXY":
                    "http://private-user:private-password@proxy.example",
                "SSLKEYLOGFILE": "/tmp/tls-secrets.log",
                "AWS_SECRET_ACCESS_KEY": "private-cloud-secret",
                "NEANTIK_PROFILE_SEED": "attacker",
                "NEANTIK_PROFILE_TIMEZONE": "attacker"
            ],
            now: observedAt
        )

        #expect(!firstLaunch.contains { $0.hasPrefix("--fingerprint=") })
        #expect(!firstLaunch.contains { $0.hasPrefix("--fingerprint-platform=") })
        #expect(firstLaunch.contains("--fingerprinting-client-rects-noise"))
        #expect(firstLaunch.contains("--fingerprinting-canvas-measuretext-noise"))
        #expect(firstLaunch.contains("--fingerprinting-canvas-image-data-noise"))
        #expect(
            firstLaunch.contains {
                $0.hasPrefix("--disable-features=") &&
                    $0.contains("WebGPUService")
            }
        )
        #expect(!firstLaunch.contains { $0.hasPrefix("--fingerprint-timezone=") })
        #expect(!firstLaunch.contains { $0.hasPrefix("--timezone=") })
        #expect(!firstLaunch.contains { $0.hasPrefix("--fingerprint-locale=") })
        #expect(firstLaunch.contains("--lang=de-DE"))
        #expect(firstLaunch.contains("--accept-lang=de-DE"))
        #expect(firstLaunch == secondLaunch)
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["SAFE_PARENT"] == nil)
        #expect(environment["HTTP_PROXY"] == nil)
        #expect(environment["SSLKEYLOGFILE"] == nil)
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(environment["NEANTIK_PROFILE_SEED"] == "123456789")
        #expect(environment["NEANTIK_PROFILE_TIMEZONE"] == "Europe/Berlin")
    }

    @Test
    func compatibleRuntimeNeverReceivesSeedOutsideSignedIntRange() throws {
        let persistedIdentity = try JSONDecoder().decode(
            BrowserIdentity.self,
            from: Data(#"{"seed":4294967295}"#.utf8)
        )
        let profile = BrowserProfile(
            name: "Legacy high seed",
            identity: persistedIdentity
        )
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/high-seed"),
            runtimeCapabilities: .fingerprintIdentity
        )
        let environment = BrowserLaunchBuilder.environment(
            profile: profile,
            runtimeCapabilities: .fingerprintIdentity,
            inherited: [:]
        )

        #expect(persistedIdentity.seed == UInt32.max)
        #expect(!arguments.contains { $0.hasPrefix("--fingerprint=") })
        #expect(
            environment["NEANTIK_PROFILE_SEED"] ==
                String(BrowserIdentity.maximumRuntimeSeed)
        )
    }

    @Test
    func newBrowserIdentitiesUseReviewedIssuancePolicy() {
        #expect(BrowserIdentityIssuancePolicy.isContractValid())
        for _ in 0..<256 {
            let identity = BrowserIdentity()
            #expect((1...BrowserIdentity.maximumRuntimeSeed).contains(identity.seed))
            #expect(identity.seed == identity.runtimeSeed)
            #expect(
                identity.issuanceVersion ==
                    BrowserIdentityIssuancePolicy.currentVersion
            )
            #expect(
                BrowserIdentityIssuancePolicy.isCurrentSeed(identity.seed)
            )
            #expect(
                identity.catalogVersion ==
                    BrowserIdentityCatalog.currentVersion
            )
            #expect(
                identity.deviceTupleID ==
                    BrowserIdentityCatalog.tupleID(
                        forRuntimeSeed: identity.runtimeSeed
                    )
            )
        }
    }

    @Test
    func legacyIdentityIsPinnedToCurrentImmutableCatalog() throws {
        let identity = try JSONDecoder().decode(
            BrowserIdentity.self,
            from: Data(#"{"seed":123}"#.utf8)
        )
        let encoded = try JSONEncoder().encode(identity)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )

        #expect(identity.catalogVersion == 1)
        #expect(
            identity.issuanceVersion ==
                BrowserIdentityIssuancePolicy.legacyVersion
        )
        #expect(
            identity.deviceTupleID ==
                BrowserIdentityCatalog.tupleID(forRuntimeSeed: 123)
        )
        #expect(object["catalogVersion"] as? Int == 1)
        #expect(
            object["issuanceVersion"] as? Int ==
                BrowserIdentityIssuancePolicy.legacyVersion
        )
        #expect(
            object["deviceTupleID"] as? String == identity.deviceTupleID
        )
    }

    @Test
    func currentIssuanceRoundTripPreservesSeedTupleAndVersion() throws {
        let original = BrowserIdentity()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            BrowserIdentity.self,
            from: encoded
        )

        #expect(decoded == original)
        #expect(
            decoded.issuanceVersion ==
                BrowserIdentityIssuancePolicy.currentVersion
        )
        #expect(
            BrowserIdentityIssuancePolicy.isCurrentSeed(decoded.seed)
        )
    }

    @Test
    func rejectsUnknownIdentityCatalogOrTupleDrift() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                BrowserIdentity.self,
                from: Data(
                    #"{"seed":123,"catalogVersion":2,"deviceTupleID":"macbook-air-m1"}"#.utf8
                )
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                BrowserIdentity.self,
                from: Data(
                    #"{"seed":123,"issuanceVersion":99}"#.utf8
                )
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                BrowserIdentity.self,
                from: Data(
                    #"{"seed":42,"issuanceVersion":2}"#.utf8
                )
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                BrowserIdentity.self,
                from: Data(
                    #"{"seed":123,"catalogVersion":1,"deviceTupleID":"wrong"}"#.utf8
                )
            )
        }
    }

    @Test
    func compatibleRuntimeDoesNotReceiveGuessedDeviceHints() {
        let profile = BrowserProfile(
            name: "Runtime-owned device tuple",
            identity: BrowserIdentity(seed: 123_456_789)
        )
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/runtime-owned"),
            runtimeCapabilities: BrowserRuntimeFlavor
                .fingerprintChromium
                .capabilities
        )

        #expect(
            !arguments.contains {
                $0.hasPrefix("--fingerprint-platform-version=")
            }
        )
        #expect(
            !arguments.contains {
                $0.hasPrefix("--fingerprint-hardware-concurrency=")
            }
        )
    }

    @Test
    func issuancePolicyUsesAtLeastTwentyNineBitsOfCandidates() {
        #expect(
            BrowserIdentityIssuancePolicy.candidateCount >=
                (UInt64(1) << 29)
        )
        for cohortIndex in
            BrowserIdentityIssuancePolicy.commonTupleResidues.indices {
            let first = BrowserIdentityIssuancePolicy.seed(
                cohortIndex: cohortIndex,
                ordinal: 0
            )
            let last = BrowserIdentityIssuancePolicy.seed(
                cohortIndex: cohortIndex,
                ordinal:
                    BrowserIdentityIssuancePolicy.membersPerCohort - 1
            )
            let overflow = BrowserIdentityIssuancePolicy.seed(
                cohortIndex: cohortIndex,
                ordinal:
                    BrowserIdentityIssuancePolicy.membersPerCohort
            )
            #expect(first != nil)
            #expect(last != nil)
            #expect(overflow == nil)
            #expect(
                first.map(BrowserIdentityIssuancePolicy.isCurrentSeed) ==
                    true
            )
            #expect(
                last.map(BrowserIdentityIssuancePolicy.isCurrentSeed) ==
                    true
            )
        }
    }

    @Test
    func staleOrUnprovenProxyContextIsNotAppliedAtLaunch() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let proxy = ProxyConfiguration(
            kind: .https,
            host: "proxy.example",
            port: 443,
            username: ""
        )
        let stale = BrowserProfile(
            name: "Stale",
            proxy: proxy,
            identity: BrowserIdentity(
                seed: 123,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE",
                proxyContextEvidence: .ipAPI(observedAt: observedAt)
            )
        )
        let legacy = BrowserProfile(
            name: "Legacy",
            proxy: proxy,
            identity: BrowserIdentity(
                seed: 124,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE"
            )
        )
        let direct = BrowserProfile(
            name: "Direct",
            identity: BrowserIdentity(
                seed: 125,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE",
                proxyContextEvidence: .ipAPI(observedAt: observedAt)
            )
        )

        for profile in [stale, legacy, direct] {
            let arguments = BrowserLaunchBuilder.arguments(
                profile: profile,
                browserDataDirectory: URL(fileURLWithPath: "/tmp/context"),
                runtimeCapabilities: .fingerprintIdentity,
                now: observedAt.addingTimeInterval(31 * 24 * 60 * 60)
            )
            #expect(
                !arguments.contains {
                    $0.hasPrefix("--fingerprint-timezone=") ||
                        $0.hasPrefix("--timezone=") ||
                        $0.hasPrefix("--fingerprint-locale=") ||
                        $0.hasPrefix("--lang=") ||
                        $0.hasPrefix("--accept-lang=")
                }
            )
            let environment = BrowserLaunchBuilder.environment(
                profile: profile,
                runtimeCapabilities: .fingerprintIdentity,
                inherited: [
                    "NEANTIK_PROFILE_SEED": "attacker",
                    "NEANTIK_PROFILE_TIMEZONE": "attacker"
                ],
                now: observedAt.addingTimeInterval(31 * 24 * 60 * 60)
            )
            #expect(environment["NEANTIK_PROFILE_SEED"] != "attacker")
            #expect(environment["NEANTIK_PROFILE_TIMEZONE"] == nil)
        }

        let afterExpiry = observedAt.addingTimeInterval(
            31 * 24 * 60 * 60
        )
        #expect(
            BrowserLaunchBuilder.requiresProxyContextRetest(
                profile: stale,
                now: afterExpiry
            )
        )
        #expect(
            BrowserLaunchBuilder.requiresProxyContextRetest(
                profile: legacy,
                now: afterExpiry
            )
        )
        #expect(
            !BrowserLaunchBuilder.requiresProxyContextRetest(
                profile: direct,
                now: afterExpiry
            )
        )
    }

    @Test
    func sanitizesPersistedBrowserIdentityHints() throws {
        let data = Data(
            """
            {
              "seed": 0,
              "timezoneIdentifier": "../../invalid",
              "localeIdentifier": "еn-US"
            }
            """.utf8
        )

        let identity = try JSONDecoder().decode(
            BrowserIdentity.self,
            from: data
        )

        #expect(identity.seed == 1)
        #expect(identity.timezoneIdentifier == nil)
        #expect(identity.localeIdentifier == nil)
    }

    @Test
    func currentIssuanceRejectsFoldedOrNullMetadata() {
        let foldedSeed = Data(
            """
            {
              "seed": 2147483650,
              "issuanceVersion": 2
            }
            """.utf8
        )
        let nullVersion = Data(
            """
            {
              "seed": 2,
              "issuanceVersion": null
            }
            """.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                BrowserIdentity.self,
                from: foldedSeed
            )
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                BrowserIdentity.self,
                from: nullVersion
            )
        }
    }

    @Test
    func proxyCredentialsNeverEnterBrowserArguments() {
        let profile = BrowserProfile(
            name: "Authenticated",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8_080,
                username: "private-user"
            )
        )
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/authenticated")
        )
        let commandLine = arguments.joined(separator: " ")

        #expect(!commandLine.contains("private-user"))
        #expect(!commandLine.contains("private-password"))
        #expect(commandLine.contains("--proxy-server=http://proxy.example:8080"))
    }

    @Test
    func rejectsProxyHostThatCouldAlterResolverRules() {
        let proxy = ProxyConfiguration(
            kind: .socks5,
            host: "proxy.example, EXCLUDE attacker.example",
            port: 1_080,
            username: ""
        )

        #expect(!proxy.isValid)
    }

    @Test
    func validatesDomainAndIPv6ProxyHosts() {
        let domain = ProxyConfiguration(
            kind: .http,
            host: "proxy.example",
            port: 8080,
            username: ""
        )
        let ipv6 = ProxyConfiguration(
            kind: .socks5,
            host: "::1",
            port: 1080,
            username: ""
        )
        let invalid = ProxyConfiguration(
            kind: .http,
            host: "proxy@example",
            port: 8080,
            username: ""
        )

        #expect(domain.isValid)
        #expect(ipv6.isValid)
        #expect(ipv6.chromiumServer == "socks5://[::1]:1080")
        #expect(!invalid.isValid)

        let authenticatedSOCKS = ProxyConfiguration(
            kind: .socks5,
            host: "proxy.example",
            port: 1_080,
            username: "unsupported"
        )
        #expect(!authenticatedSOCKS.isValid)

        let ambiguousHTTPUsername = ProxyConfiguration(
            kind: .http,
            host: "proxy.example",
            port: 8_080,
            username: "user:name"
        )
        let controlCharacterUsername = ProxyConfiguration(
            kind: .https,
            host: "proxy.example",
            port: 443,
            username: "user\tname"
        )
        #expect(!ambiguousHTTPUsername.isValid)
        #expect(!controlCharacterUsername.isValid)
    }

    @Test
    func rejectsIncompleteOrCredentialedStartURLs() {
        #expect(
            BrowserLaunchBuilder
                .normalizedStartURL("https://")
                .absoluteString == "https://www.google.com"
        )
        #expect(
            BrowserLaunchBuilder
                .normalizedStartURL("https://user:pass@example.com")
                .absoluteString == "https://www.google.com"
        )
        #expect(BrowserLaunchBuilder.validatedStartURL("https://") == nil)
        #expect(
            BrowserLaunchBuilder.validatedStartURL(
                "https://user:pass@example.com"
            ) == nil
        )
        #expect(
            BrowserLaunchBuilder
                .validatedStartURL("example.com")?
                .absoluteString == "https://example.com"
        )
    }

    @Test
    func locatesCustomExecutableFirst() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("Chromium")
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data([
                0xCF, 0xFA, 0xED, 0xFE,
                0x0C, 0x00, 0x00, 0x01
            ])
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let preference = BrowserRuntimePreference(
            path: executable.path,
            flavor: .standard,
            updatedAt: Date()
        )
        let runtime = testRuntimeLocator().preferredRuntime(
            preference: preference
        )

        #expect(runtime?.executableURL.standardizedFileURL == executable.standardizedFileURL)
        #expect(runtime?.source == "Выбран вручную")
        #expect(runtime?.supportsFingerprintIdentity == false)
    }

    @Test
    func directLocatorIgnoresPersistedExternalRuntime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("Chromium")
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data([
                0xCF, 0xFA, 0xED, 0xFE,
                0x0C, 0x00, 0x00, 0x01
            ])
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let preference = BrowserRuntimePreference(
            path: executable.path,
            flavor: .fingerprintChromium,
            updatedAt: Date()
        )
        let locator = BrowserRuntimeLocator { _ in
            BrowserRuntimeInspection(
                version: "150.0.7871.186",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        }

        #expect(locator.preferredRuntime(preference: preference) == nil)
    }

    @Test
    func directLocatorPrefersOnlyDeclaredEmbeddedRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent(
            "NeAntik Browser.app",
            isDirectory: true
        )
        let contents = app.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let macOS = contents.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        let executable = macOS.appendingPathComponent("NeAntik Browser")
        try Data([
            0xCF, 0xFA, 0xED, 0xFE,
            0x0C, 0x00, 0x00, 0x01
        ]).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "NeAntik Browser",
                "CFBundleIdentifier": "app.neantik.runtime",
                "CFBundleShortVersionString": "150.0.7871.186",
                "NeAntikRuntimeFlavor": "fingerprint-chromium"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(
            to: contents.appendingPathComponent("Info.plist")
        )

        let preference = BrowserRuntimePreference(
            path: "/Applications/Google Chrome.app",
            flavor: .standard,
            updatedAt: Date()
        )
        let locator = BrowserRuntimeLocator(
            runtimeInspector: { _ in
                BrowserRuntimeInspection(
                    version: "150.0.7871.186",
                    architectures: ["arm64"],
                    codeSignatureValid: true
                )
            },
            resourceURL: root
        )

        let runtime = locator.preferredRuntime(preference: preference)
        #expect(runtime?.executableURL == executable)
        #expect(runtime?.source == "Встроен")
        #expect(runtime?.supportsFingerprintIdentity == true)
    }

    @Test
    func preferredRuntimeStopsAfterFirstUsableCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("First Browser")
        let second = directory.appendingPathComponent("Second Browser")
        for executable in [first, second] {
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data([
                    0xCF, 0xFA, 0xED, 0xFE,
                    0x0C, 0x00, 0x00, 0x01
                ])
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let recorder = RuntimeInspectionRecorder()
        let locator = BrowserRuntimeLocator(
            runtimeInspector: { url in
                recorder.inspect(url)
            },
            candidates: [
                BrowserRuntimeLocator.Candidate(
                    name: "First",
                    url: first,
                    source: "Test",
                    flavor: .fingerprintChromium
                ),
                BrowserRuntimeLocator.Candidate(
                    name: "Second",
                    url: second,
                    source: "Test",
                    flavor: .standard
                )
            ]
        )

        let preferred = locator.preferredRuntime()

        #expect(preferred?.executableURL == first)
        #expect(recorder.paths == [first.standardizedFileURL.path])
    }

    @Test
    func explicitlyCompatibleCustomRuntimeEnablesIdentityProtocol() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("Patched Chromium")
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data([
                0xCF, 0xFA, 0xED, 0xFE,
                0x0C, 0x00, 0x00, 0x01
            ])
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let preference = BrowserRuntimePreference(
            path: executable.path,
            flavor: .fingerprintChromium,
            updatedAt: Date()
        )
        let runtime = testRuntimeLocator().preferredRuntime(
            preference: preference
        )

        #expect(runtime?.supportsFingerprintIdentity == true)
        #expect(runtime?.flavor == .fingerprintChromium)
    }

    @Test
    func recognizesBrandedNeAntikRuntimeWithoutManualFlavorToggle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(UUID().uuidString)/NeAntik Browser.app",
                isDirectory: true
            )
        let contents = root.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let macOS = contents.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }

        let executable = macOS.appendingPathComponent("NeAntik Browser")
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data([
                0xCF, 0xFA, 0xED, 0xFE,
                0x0C, 0x00, 0x00, 0x01
            ])
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "NeAntik Browser",
                "CFBundleIdentifier": "app.neantik.runtime",
                "CFBundleShortVersionString": "144.0.7559.132",
                "NeAntikRuntimeFlavor": "fingerprint-chromium"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(
            to: contents.appendingPathComponent("Info.plist")
        )

        let locator = testRuntimeLocator()
        #expect(
            locator.recommendedFlavor(for: root) ==
                .fingerprintChromium
        )

        let preference = BrowserRuntimePreference(
            path: root.path,
            flavor: .standard,
            updatedAt: Date()
        )
        let runtime = locator.preferredRuntime(preference: preference)
        #expect(runtime?.name == "NeAntik Browser")
        #expect(runtime?.flavor == .fingerprintChromium)
        #expect(runtime?.supportsFingerprintIdentity == true)
        #expect(runtime?.executableURL == executable)
    }

    @Test
    func unflavoredNeAntikBundleDoesNotImplyFingerprintIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(UUID().uuidString)/NeAntik Browser.app",
                isDirectory: true
            )
        let contents = root.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let macOS = contents.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }

        let executable = macOS.appendingPathComponent("NeAntik Browser")
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data([
                0xCF, 0xFA, 0xED, 0xFE,
                0x0C, 0x00, 0x00, 0x01
            ])
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "NeAntik Browser",
                "CFBundleIdentifier": "app.neantik.runtime",
                "CFBundleShortVersionString": "144.0.7559.132"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(
            to: contents.appendingPathComponent("Info.plist")
        )

        let locator = testRuntimeLocator()
        #expect(locator.recommendedFlavor(for: root) == .standard)

        let preference = BrowserRuntimePreference(
            path: root.path,
            flavor: .standard,
            updatedAt: Date()
        )
        let runtime = locator.preferredRuntime(preference: preference)
        #expect(runtime?.flavor == .standard)
        #expect(runtime?.supportsFingerprintIdentity == false)
        #expect(runtime?.executableURL == executable)
    }

    @Test
    func resolvesBundleExecutableWithoutAllowingPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(UUID().uuidString)/Custom Browser.app/Contents",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: root
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        }

        let app = root.deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("Info.plist")
        let valid = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "BrowserCore"],
            format: .xml,
            options: 0
        )
        try valid.write(to: plistURL)

        let locator = BrowserRuntimeLocator()
        #expect(
            locator.normalizedExecutable(app).path ==
                app.appendingPathComponent(
                    "Contents/MacOS/BrowserCore"
                ).path
        )

        let unsafe = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "../../evil"],
            format: .xml,
            options: 0
        )
        try unsafe.write(to: plistURL)
        #expect(
            locator.normalizedExecutable(app).path ==
                app.appendingPathComponent(
                    "Contents/MacOS/Custom Browser"
                ).path
        )
    }
}
