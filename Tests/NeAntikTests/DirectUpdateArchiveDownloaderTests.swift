import CryptoKit
import Foundation
import Testing
@testable import DirectUpdateCore

@Suite(.serialized)
struct DirectUpdateArchiveDownloaderTests {
    private func setup(bytes: Data, delivered: [Data]? = nil, mime: String = "application/zip", limit: Int64 = 4096) throws -> (DirectUpdateArchiveDownloader, ManifestDiscoveryFixture, RetrievedUpdateManifest) {
        let fixture = ManifestDiscoveryFixture()
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let envelope = try fixture.envelope(archiveSHA256: sha)
        let manifest = RetrievedUpdateManifest(bytes: envelope, verified: try UpdateManifestVerifier.verify(envelope,
            configuration: fixture.trust, installedVersion: "0.7.34", installedBuild: 97, now: ManifestDiscoveryFixture.date))
        ManifestURLProtocol.configure { instance in
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "1"])!
            instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in delivered ?? [bytes] { instance.client?.urlProtocol(instance, didLoad: chunk) }
            instance.client?.urlProtocolDidFinishLoading(instance)
        }
        let config = SignedUpdateManifestFetcher.sessionConfiguration(); config.protocolClasses = [ManifestURLProtocol.self]
        return (DirectUpdateArchiveDownloader(configuration: config), fixture, manifest)
    }
    private func load(_ setup: (DirectUpdateArchiveDownloader, ManifestDiscoveryFixture, RetrievedUpdateManifest), limit: Int64 = 4096) async throws -> DownloadedUpdateArchive {
        try await setup.0.download(manifest: setup.2, configuration: setup.1.trust, installedVersion: "0.7.34", installedBuild: 97,
            hostOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0), clock: { ManifestDiscoveryFixture.date }, byteLimit: limit)
    }
    @Test func splitStreamIsHashVerifiedAndOwnedUntilExplicitDisposal() async throws {
        let data = Data("own-synthetic-zip-bytes".utf8)
        let archive = try await load(setup(bytes: data, delivered: [data.prefix(7), data.dropFirst(7)]))
        let url = archive.url; try archive.validate()
        #expect(try Data(contentsOf: url) == data)
        #expect(ManifestURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        archive.dispose(); #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func actualLimitCannotBeBypassedByFalseContentLength() async throws {
        await #expect(throws: (any Error).self) { try await load(setup(bytes: Data(repeating: 1, count: 65)), limit: 64) }
    }
    @Test func truncationTamperAndHTMLCannotBecomeAnArchive() async throws {
        let bytes = Data("synthetic".utf8)
        for delivered in [[Data("tampered".utf8)], [bytes.prefix(3)]] {
            await #expect(throws: (any Error).self) { try await load(setup(bytes: bytes, delivered: delivered)) }
        }
        await #expect(throws: (any Error).self) { try await load(setup(bytes: bytes, mime: "text/html")) }
    }
    @Test func replacedFileIsPreservedAndCustodyRefused() throws {
        let archive = try DownloadedUpdateArchive(), url = archive.url
        try FileManager.default.removeItem(at: url)
        try Data("foreign".utf8).write(to: url)
        #expect(throws: (any Error).self) { try archive.validate() }
        archive.dispose(); #expect(try Data(contentsOf: url) == Data("foreign".utf8))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    @Test func redirectsAreExactHTTPSReleaseAssetRouteOnly() {
        for value in ["https://evil.test/github-production-release-asset/x", "http://release-assets.githubusercontent.com/github-production-release-asset/x", "https://user@release-assets.githubusercontent.com/github-production-release-asset/x", "https://release-assets.githubusercontent.com/other/x"] {
            #expect(!DirectUpdateArchiveDownloader.allowedRedirectURL(URL(string: value)!))
        }
        #expect(DirectUpdateArchiveDownloader.allowedRedirectURL(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?signature=synthetic")!))
        #expect(!DirectUpdateArchiveDownloader.allowedInitialURL(URL(string: "https://github.com/other/neantik/releases/download/v1/file.zip")!, name: "file.zip"))
    }
}
