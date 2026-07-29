import Foundation
import Testing
@testable import NeAntik

struct BrowserLaunchBuilderTests {
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
        #expect(arguments.contains("--proxy-server=socks5://127.0.0.1:1080"))
        #expect(
            arguments.contains(
                "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
        )
        #expect(arguments.contains("--disable-quic"))
        #expect(arguments.contains("--dns-prefetch-disable"))
        #expect(
            arguments.contains(
                "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"
            )
        )
        #expect(arguments.contains("--proxy-bypass-list=<-loopback>"))
        #expect(arguments.last == "https://example.com")
    }

    @Test
    func directProfileHasNoProxyArgument() {
        let profile = BrowserProfile(name: "Direct")
        let arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/direct")
        )

        #expect(!arguments.contains { $0.hasPrefix("--proxy-server=") })
        #expect(
            !arguments.contains {
                $0.hasPrefix("--force-webrtc-ip-handling-policy=")
            }
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
                "--proxy-bypass-list=*",
                "--host-resolver-rules=MAP * 127.0.0.1",
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
        #expect(
            arguments.contains(
                "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE proxy.example"
            )
        )
        #expect(
            arguments.contains(
                "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
        )
        #expect(arguments.contains("--fingerprint=123"))
        #expect(arguments.contains("--fingerprinting-client-rects-noise"))
        #expect(arguments.contains("--fingerprinting-canvas-measuretext-noise"))
        #expect(arguments.contains("--fingerprinting-canvas-image-data-noise"))
        #expect(arguments.contains("--disable-features=WebGPUService"))
        #expect(!arguments.contains("--user-data-dir=/tmp/evil"))
        #expect(!arguments.contains("--proxy-server=direct://"))
        #expect(!arguments.contains("--proxy-bypass-list=*"))
        #expect(!arguments.contains("--host-resolver-rules=MAP * 127.0.0.1"))
        #expect(!arguments.contains("--force-webrtc-ip-handling-policy=default"))
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
    func rejectsScriptStartURL() {
        #expect(
            BrowserLaunchBuilder
                .normalizedStartURL("javascript:alert(1)")
                .absoluteString == "https://www.google.com"
        )
    }

    @Test
    func compatibleRuntimeReceivesStableProfileIdentity() {
        let profile = BrowserProfile(
            name: "Private",
            identity: BrowserIdentity(
                seed: 123_456_789,
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE"
            )
        )

        let firstLaunch = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/private"),
            runtimeCapabilities: .fingerprintIdentity
        )
        let secondLaunch = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: URL(fileURLWithPath: "/tmp/private"),
            runtimeCapabilities: .fingerprintIdentity
        )

        #expect(firstLaunch.contains("--fingerprint=123456789"))
        #expect(firstLaunch.contains("--fingerprint-platform=macos"))
        #expect(firstLaunch.contains("--fingerprinting-client-rects-noise"))
        #expect(firstLaunch.contains("--fingerprinting-canvas-measuretext-noise"))
        #expect(firstLaunch.contains("--fingerprinting-canvas-image-data-noise"))
        #expect(firstLaunch.contains("--disable-features=WebGPUService"))
        #expect(
            firstLaunch.contains("--fingerprint-timezone=Europe/Berlin")
        )
        #expect(firstLaunch.contains("--timezone=Europe/Berlin"))
        #expect(firstLaunch.contains("--fingerprint-locale=de-DE"))
        #expect(firstLaunch.contains("--lang=de-DE"))
        #expect(firstLaunch.contains("--accept-lang=de-DE"))
        #expect(firstLaunch == secondLaunch)
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

        #expect(persistedIdentity.seed == UInt32.max)
        #expect(
            arguments.contains(
                "--fingerprint=\(BrowserIdentity.maximumRuntimeSeed)"
            )
        )
        #expect(!arguments.contains("--fingerprint=\(UInt32.max)"))
    }

    @Test
    func newBrowserIdentitiesUseRuntimeCompatibleSeeds() {
        for _ in 0..<256 {
            let identity = BrowserIdentity()
            #expect((1...BrowserIdentity.maximumRuntimeSeed).contains(identity.seed))
            #expect(identity.seed == identity.runtimeSeed)
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
    func profilesHaveDistinctBrowserIdentities() {
        let first = BrowserProfile(name: "First")
        let second = BrowserProfile(name: "Second")

        #expect(first.identity.seed != second.identity.seed)
    }

    @Test
    func sanitizesPersistedBrowserIdentityHints() throws {
        let data = Data(
            """
            {
              "seed": 0,
              "timezoneIdentifier": "../../invalid",
              "localeIdentifier": "en-US-extra"
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
        let runtime = BrowserRuntimeLocator().preferredRuntime(
            preference: preference
        )

        #expect(runtime?.executableURL.standardizedFileURL == executable.standardizedFileURL)
        #expect(runtime?.source == "Выбран вручную")
        #expect(runtime?.supportsFingerprintIdentity == false)
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
        let runtime = BrowserRuntimeLocator().preferredRuntime(
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

        let locator = BrowserRuntimeLocator()
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

        let locator = BrowserRuntimeLocator()
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
