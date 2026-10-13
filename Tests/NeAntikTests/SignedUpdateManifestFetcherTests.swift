import CryptoKit
import Foundation
import Testing
@testable import DirectUpdateCore
@testable import NeAntik

/// Keys exist only in memory, and URLProtocol intercepts the approved test URL.
struct ManifestDiscoveryFixture {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    let key = Curve25519.Signing.PrivateKey()
    var trust: UpdateChannelConfiguration {
        .init(isEnabled: true, manifestURL: URL(string: "https://browser.free/update.json"),
              publicKeyID: "qa-discovery", publicKey: key.publicKey.rawRepresentation)
    }
    func envelope(build: Int = 98, minimumOS: String = "14.0", expired: Bool = false,
                  expiresAfter: TimeInterval? = nil) throws -> Data {
        let payload = UpdateManifestPayload(schemaVersion: 1, product: "NeAntik", edition: "Direct",
            version: "0.7.35", build: build, issuedAt: Self.date.addingTimeInterval(-600),
            expiresAt: Self.date.addingTimeInterval(expiresAfter ?? (expired ? -301 : 600)),
            archiveName: "NeAntik-0.7.35-arm64-notarized.zip",
            downloadURL: "https://github.com/AffPapa/neantik/releases/download/v0.7.35/NeAntik-0.7.35-arm64-notarized.zip",
            sha256: String(repeating: "a", count: 64), minimumOS: minimumOS, architecture: "arm64",
            artifactKind: "public-notarized", publicReleaseState: "public-ready", chromiumVersion: "156.0.8078.12")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(payload)
        return try JSONEncoder().encode(SignedUpdateEnvelope(schemaVersion: 1, algorithm: "Ed25519",
            keyID: "qa-discovery", payload: bytes.base64EncodedString(),
            signature: key.signature(for: bytes).base64EncodedString()))
    }
    func retrieved() throws -> RetrievedUpdateManifest {
        let bytes = try envelope()
        return .init(bytes: bytes, verified: try UpdateManifestVerifier.verify(bytes, configuration: trust,
            installedVersion: "0.7.34", installedBuild: 97, now: Self.date))
    }
}

@Suite(.serialized)
struct SignedUpdateManifestFetcherTests {
    private func fetcher(status: Int = 200, mime: String = "application/json", chunks: [Data],
                         length: Int? = nil) -> SignedUpdateManifestFetcher {
        ManifestURLProtocol.configure { protocolInstance in
            var headers = ["Content-Type": mime]
            if let length { headers["Content-Length"] = String(length) }
            let response = HTTPURLResponse(url: protocolInstance.request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { protocolInstance.client?.urlProtocol(protocolInstance, didLoad: chunk) }
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let configuration = SignedUpdateManifestFetcher.sessionConfiguration()
        configuration.protocolClasses = [ManifestURLProtocol.self]
        return SignedUpdateManifestFetcher(configuration: configuration)
    }
    private func load(_ fetcher: SignedUpdateManifestFetcher, fixture: ManifestDiscoveryFixture,
                      installedBuild: Int = 97, installedVersion: String = "0.7.34") async throws -> RetrievedUpdateManifest {
        try await fetcher.fetch(configuration: fixture.trust, installedVersion: installedVersion,
            installedBuild: installedBuild, hostOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            now: { ManifestDiscoveryFixture.date })
    }
    @Test func configurationHasNoAmbientCredentialsCookiesOrCacheAndFiniteResourceDeadline() {
        let configuration = SignedUpdateManifestFetcher.sessionConfiguration()
        #expect(configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil && !configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForRequest == 15 && configuration.timeoutIntervalForResource == 20)
        #expect(!configuration.waitsForConnectivity)
    }
    @Test func splitResponseRetainsExactAuthenticEnvelopeWithoutInstallAuthority() async throws {
        let fixture = ManifestDiscoveryFixture(), bytes = try fixture.envelope()
        let service = fetcher(chunks: [bytes.prefix(71), bytes.dropFirst(71)])
        let result = try await load(service, fixture: fixture)
        #expect(result.bytes == bytes && result.verified.isNewerThanInstalled)
        #expect(ManifestURLProtocol.requests.count == 1)
        #expect(ManifestURLProtocol.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(ManifestURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }
    @Test(arguments: [204, 304, 401, 429, 500])
    func non200CannotBeAnUpdate(status: Int) async throws {
        let fixture = ManifestDiscoveryFixture()
        await #expect(throws: UpdateManifestFetchError.response) {
            try await load(fetcher(status: status, chunks: [try fixture.envelope()]), fixture: fixture)
        }
    }
    @Test func htmlCannotBeMistakenForManifest() async throws {
        let fixture = ManifestDiscoveryFixture()
        await #expect(throws: UpdateManifestFetchError.response) {
            try await load(fetcher(mime: "text/html", chunks: [try fixture.envelope()]), fixture: fixture)
        }
    }
    @Test func exactLimitAcceptedAndChunkOverflowRejectedWithoutContentLength() async throws {
        let fixture = ManifestDiscoveryFixture()
        var bytes = try fixture.envelope()
        bytes.append(Data(repeating: 32, count: SignedUpdateManifestFetcher.maximumBytes - bytes.count))
        #expect(try await load(fetcher(chunks: [bytes]), fixture: fixture).bytes.count == SignedUpdateManifestFetcher.maximumBytes)
        await #expect(throws: UpdateManifestFetchError.tooLarge) {
            try await load(fetcher(chunks: [bytes, Data([32])]), fixture: fixture)
        }
    }
    @Test func falseSmallLengthDoesNotBypassActualByteLimit() async throws {
        let fixture = ManifestDiscoveryFixture()
        await #expect(throws: UpdateManifestFetchError.tooLarge) {
            try await load(fetcher(chunks: [Data(count: SignedUpdateManifestFetcher.maximumBytes + 1)], length: 1), fixture: fixture)
        }
    }
    @Test func oversizedDeclaredLengthRefusedBeforePayloadVerification() async throws {
        let fixture = ManifestDiscoveryFixture()
        await #expect(throws: UpdateManifestFetchError.tooLarge) {
            try await load(fetcher(chunks: [], length: SignedUpdateManifestFetcher.maximumBytes + 1), fixture: fixture)
        }
    }
    @Test func authenticButExpiredOrIncompatibleManifestRefused() async throws {
        let fixture = ManifestDiscoveryFixture()
        await #expect(throws: UpdateManifestError.expired) {
            try await load(fetcher(chunks: [try fixture.envelope(expired: true)]), fixture: fixture)
        }
        await #expect(throws: DirectUpdateArchiveIntegrityError.incompatibleOS) {
            try await load(fetcher(chunks: [try fixture.envelope(minimumOS: "26.0")]), fixture: fixture)
        }
        await #expect(throws: DirectUpdateArchiveIntegrityError.notNewer) {
            try await load(fetcher(chunks: [try fixture.envelope(build: 96)]), fixture: fixture)
        }
    }
    @Test func wrongSigningKeyAndChangedPayloadAreRejected() async throws {
        let fixture = ManifestDiscoveryFixture(), other = ManifestDiscoveryFixture()
        await #expect(throws: UpdateManifestError.invalidSignature) {
            try await load(fetcher(chunks: [try other.envelope()]), fixture: fixture)
        }
        let envelope = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: fixture.envelope())
        var bytes = Data(base64Encoded: envelope.payload)!; bytes[0] ^= 1
        let tampered = try JSONEncoder().encode(SignedUpdateEnvelope(schemaVersion: 1, algorithm: "Ed25519",
            keyID: envelope.keyID, payload: bytes.base64EncodedString(), signature: envelope.signature))
        await #expect(throws: UpdateManifestError.invalidSignature) {
            try await load(fetcher(chunks: [tampered]), fixture: fixture)
        }
    }
    @Test func sameReleaseDoesNotClaimNewer() async throws {
        let fixture = ManifestDiscoveryFixture()
        let result = try await load(fetcher(chunks: [try fixture.envelope()]), fixture: fixture,
                                    installedBuild: 98, installedVersion: "0.7.35")
        #expect(!result.verified.isNewerThanInstalled)
    }
    @Test func clockSkewBoundaryIsAcceptedButOlderManifestIsRefused() async throws {
        let fixture = ManifestDiscoveryFixture()
        #expect(try await load(fetcher(chunks: [try fixture.envelope(expiresAfter: -300)]), fixture: fixture).verified.isNewerThanInstalled)
        await #expect(throws: UpdateManifestError.expired) {
            try await load(fetcher(chunks: [try fixture.envelope(expiresAfter: -301)]), fixture: fixture)
        }
    }
    @Test func disabledOrNonstandardPortMakesNoRequest() async throws {
        let fixture = ManifestDiscoveryFixture(), service = fetcher(chunks: [])
        for configuration in [UpdateChannelConfiguration(isEnabled: false, manifestURL: nil, publicKeyID: nil, publicKey: nil),
            UpdateChannelConfiguration(isEnabled: true, manifestURL: URL(string: "https://browser.free:8443/update.json"),
                publicKeyID: fixture.trust.publicKeyID, publicKey: fixture.trust.publicKey)] {
            await #expect(throws: UpdateManifestError.channelDisabled) {
                try await service.fetch(configuration: configuration, installedVersion: "0.7.34", installedBuild: 97)
            }
        }
        #expect(ManifestURLProtocol.requests.isEmpty)
    }
    @Test func cancellationStopsActiveTransferAndReturnsNoManifest() async throws {
        let fixture = ManifestDiscoveryFixture()
        ManifestURLProtocol.configure { _ in /* Hold transfer until cancellation. */ }
        let configuration = SignedUpdateManifestFetcher.sessionConfiguration()
        configuration.protocolClasses = [ManifestURLProtocol.self]
        let service = SignedUpdateManifestFetcher(configuration: configuration)
        let task = Task { try await load(service, fixture: fixture) }
        for _ in 0..<2_000 { if !ManifestURLProtocol.requests.isEmpty { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(ManifestURLProtocol.requests.count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ManifestURLProtocol.stopCount == 1)
    }
    @Test func resourceDeadlineTerminatesAStalledTransfer() async throws {
        let fixture = ManifestDiscoveryFixture()
        ManifestURLProtocol.configure { _ in }
        let configuration = SignedUpdateManifestFetcher.sessionConfiguration()
        // A short injected deadline exercises URLSession's resource timer.
        // The production deadline is separately asserted as 20 seconds.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 0.15
        configuration.protocolClasses = [ManifestURLProtocol.self]
        let service = SignedUpdateManifestFetcher(configuration: configuration)
        let task = Task { try await load(service, fixture: fixture) }
        let safety = Task { try await Task.sleep(for: .seconds(2)); task.cancel() }
        defer { safety.cancel() }
        do {
            _ = try await task.value
            Issue.record("Stalled response unexpectedly produced a verified manifest")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Resource timer did not terminate the held URLProtocol response: \(type(of: error))")
        }
        // A loaded executor can consume the deadline before URLProtocol starts.
        // No started transfer then means there is nothing to stop. If started,
        // wait for Foundation's separate stopLoading callback before reset.
        for _ in 0..<2_000 {
            if ManifestURLProtocol.stopCount == ManifestURLProtocol.requests.count { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(ManifestURLProtocol.requests.count <= 1)
        #expect(ManifestURLProtocol.stopCount == ManifestURLProtocol.requests.count)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_QA_LIVE_MANIFEST_REFUSAL"] == "1"))
    func liveHTTPSUnpublishedManifestCannotOfferUpdate() async throws {
        let fixture = ManifestDiscoveryFixture()
        let trust = UpdateChannelConfiguration(isEnabled: true,
            manifestURL: URL(string: "https://browser.free/.well-known/neantik-qa-unpublished-\(UUID().uuidString).json"),
            publicKeyID: fixture.trust.publicKeyID, publicKey: fixture.trust.publicKey)
        // Ordinary HTTPS with platform trust; no tokens, cookies, redirects or
        // TLS exceptions. This is a refusal probe, not a signed feed qualification.
        await #expect(throws: UpdateManifestFetchError.response) {
            try await SignedUpdateManifestFetcher().fetch(configuration: trust,
                installedVersion: "0.7.34", installedBuild: 97)
        }
    }
    @Test func redirectRefusedWithoutASecondRequest() async throws {
        let fixture = ManifestDiscoveryFixture()
        let service = fetcher(chunks: [])
        ManifestURLProtocol.configure { instance in
            let redirect = URL(string: "https://unapproved.example/update.json")!
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 302,
                httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            instance.client?.urlProtocol(instance, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            instance.client?.urlProtocolDidFinishLoading(instance)
        }
        await #expect(throws: UpdateManifestFetchError.response) { try await load(service, fixture: fixture) }
        #expect(ManifestURLProtocol.requests.count == 1)
    }
    @Test func authenticationChallengeIsCancelledWithoutCredentials() async throws {
        let fixture = ManifestDiscoveryFixture()
        let service = fetcher(chunks: [])
        let sender = ManifestChallengeSender()
        ManifestURLProtocol.configure { instance in
            sender.instance = instance
            let space = URLProtectionSpace(host: "browser.free", port: 443, protocol: "https",
                realm: "QA", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: sender)
            instance.client?.urlProtocol(instance, didReceive: challenge)
        }
        await #expect(throws: UpdateManifestFetchError.authentication) { try await load(service, fixture: fixture) }
        // URLSession completes cancellation internally without calling the
        // custom protocol's challenge sender. Assert task drain, typed delegate
        // refusal above, no supplied credential and no retry instead.
        #expect(ManifestURLProtocol.stopCount == 1 && !sender.usedCredential)
        #expect(ManifestURLProtocol.requests.count == 1)
    }
}

private final class ManifestChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    weak var instance: ManifestURLProtocol?
    private(set) var usedCredential = false
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        usedCredential = true; fail()
    }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { fail() }
    func cancel(_ challenge: URLAuthenticationChallenge) { fail() }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { fail() }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { fail() }
    private func fail() {
        if let instance { instance.client?.urlProtocol(instance, didFailWithError: URLError(.userAuthenticationRequired)) }
    }
}

private final class ManifestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((ManifestURLProtocol) -> Void)?
    private static var recorded = [URLRequest](), stops = 0
    private static var run: UInt64 = 0
    private var startedRun: UInt64?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    static func configure(_ value: @escaping (ManifestURLProtocol) -> Void) {
        lock.lock(); defer { lock.unlock() }; run &+= 1; handler = value; recorded = []; stops = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); startedRun = Self.run; Self.recorded.append(request); let handler = Self.handler; Self.lock.unlock()
        handler?(self)
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        // A late callback from another fixture must never create a false PASS.
        if startedRun == Self.run { Self.stops += 1 }
    }
}
